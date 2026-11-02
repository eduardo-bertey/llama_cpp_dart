import 'dart:ffi';
import 'dart:io' show Directory, File, FileSystemException, Platform;

import 'package:ffi/ffi.dart';

import '../types/exceptions.dart';
import 'bindings.dart';
import 'log.dart';

/// Process-wide owner of the loaded llama.cpp dynamic library.
///
/// Call [load] exactly once before using any other API. The path must point
/// at the platform-specific shared library produced by `tool/build_native.sh`
/// or downloaded from a release bundle.
final class LlamaLibrary {
  LlamaLibrary._();

  static LlamaBindings? _bindings;
  static String? _libraryPath;
  static String? _libraryDir;
  static DynamicLibrary? _llamaLib;
  static DynamicLibrary? _mtmdLib;
  static final List<DynamicLibrary> _ggmlFallbackLibs = <DynamicLibrary>[];

  /// Windows helper handles. `kernel32` is always present in a process; this
  /// handle exists so [SetDllDirectoryW] can be reached via FFI without a
  /// dedicated depedency declaration in [dispose].
  static DynamicLibrary? _kernel32;

  /// Lazily-resolved bindings. Throws if [load] has not been called.
  static LlamaBindings get bindings {
    final b = _bindings;
    if (b == null) {
      throw const LlamaLibraryException(
        'LlamaLibrary.load() must be called before using the binding.',
      );
    }
    return b;
  }

  static bool get isLoaded => _bindings != null;
  static String? get libraryPath => _libraryPath;
  static String? get libraryDirectory => _libraryDir;

  /// True if the runtime was built with mmap-based model loading support.
  /// When false, [ModelParams.useMmap] is silently ignored.
  static bool get supportsMmap => bindings.llama_supports_mmap();

  /// True if the runtime can lock model memory pages in RAM (mlock).
  static bool get supportsMlock => bindings.llama_supports_mlock();

  /// True if the runtime was compiled with the RPC backend.
  static bool get supportsRpc => bindings.llama_supports_rpc();

  /// Maximum number of sequences a context can host concurrently in a
  /// single batch. Hard upper bound on [ContextParams.nSeqMax].
  static int get maxParallelSequences =>
      bindings.llama_max_parallel_sequences();

  /// Maximum number of `TensorBuftOverride` entries accepted by
  /// `llama_model_load_from_file` per call.
  static int get maxTensorBuftOverrides =>
      bindings.llama_max_tensor_buft_overrides();

  /// High-resolution wall clock the runtime uses internally, in microseconds.
  /// Convenient for matching log timestamps against your own measurements.
  static int get timeUs => bindings.llama_time_us();

  /// One-line summary of the build (CPU features, BLAS, GPU backends).
  /// Useful for crash reports and CI logs. Empty when the runtime returns
  /// null.
  static String systemInfo() {
    final ptr = bindings.llama_print_system_info();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  /// Configure NUMA awareness. Call **before** the first model load if you
  /// need a non-default strategy; calling later has no effect. Defaults to
  /// disabled and only matters on multi-socket Linux servers.
  static void initNuma(NumaStrategy strategy) {
    bindings.llama_numa_init(ggml_numa_strategy.fromValue(strategy.value));
  }

  /// Load the native library and initialize llama / ggml backends.
  ///
  /// [path] is the path to `libllama.dylib` / `libllama.so`. Anything that
  /// looks like a file path (contains a separator) is canonicalized to its
  /// absolute form — required on Windows, where relative paths pair badly
  /// with the loader flags Dart uses. A bare library name (no separator)
  /// stays untouched and is resolved by the OS (Android jniLibs, PATH, …).
  /// [backendDirectory] points at the directory holding the ggml backend
  /// dylibs (`libggml-metal.dylib`, `libggml-cpu.dylib`, ...). Defaults to
  /// the directory containing [path].
  ///
  /// Idempotent: subsequent calls with the same path are no-ops.
  /// Calling with a different path while a library is already loaded
  /// throws [LlamaLibraryException].
  static void load({required String path, String? backendDirectory}) {
    // Windows note: Dart opens libraries through LoadLibraryExW with the
    // LOAD_WITH_ALTERED_SEARCH_PATH flag, whose behavior is *undefined* for
    // relative paths — dependencies of the DLL (ggml-base.dll & co.) may not
    // resolve at all, yielding "The specified module could not be found"
    // (error 126). Canonicalize anything that looks like a file path to its
    // absolute form; a bare library name keeps flowing to the OS search
    // machinery untouched.
    final openPath = (path.contains('/') || path.contains('\\'))
        ? File(path).absolute.path
        : path;

    if (_bindings != null) {
      if (_libraryPath == openPath) return;
      throw LlamaLibraryException(
        'A different llama library is already loaded: $_libraryPath',
      );
    }

    final DynamicLibrary llama;
    try {
      // Windows: the loader resolves sibling dependencies of llama.dll
      // (ggml-base.dll, ggml.dll, ggml-cpu-*.dll) through the classic DLL
      // search order, which starts at the process .exe directory — NOT at
      // the directory of the DLL being opened. "The specified module could
      // not be found" (error 126) is what a missing directory produces.
      // Point the fallback search slot at the llama.dll folder first, e.g.
      // the unpacked `llama-b*-bin-win-cpu-x64` release.
      final searchDir = _dirOf(openPath);
      if (Platform.isWindows && searchDir != null) {
        _setWindowsSearchDirectory(searchDir);
      }
      llama = DynamicLibrary.open(openPath);
    } on ArgumentError catch (e) {
      throw LlamaLibraryException('failed to open $openPath: $e');
    }
    _llamaLib = llama;

    // Try to open libmtmd alongside libllama. mtmd is optional — engines
    // without multimodal can run without it. Symbols starting with
    // `mtmd_` are routed to this handle when the lookup runs.
    //
    // Resolution rules:
    //   1. If [openPath] is a basename (no slash), assume the OS will resolve
    //      libraries by name from the app's lib path (Android jniLibs,
    //      Linux LD_LIBRARY_PATH). Open libmtmd by basename too.
    //   2. Otherwise look in the same directory as libllama (or the
    //      explicit [backendDirectory] override) and open by full path.
    DynamicLibrary? mtmd;
    final dir = backendDirectory ?? _dirOf(openPath);
    final mtmdName = _mtmdFileName();
    if (mtmdName != null) {
      if (dir == null) {
        // Basename mode (typical Android usage).
        try {
          mtmd = DynamicLibrary.open(mtmdName);
        } on ArgumentError {
          // mtmd not present in this build; multimodal calls will throw.
        }
      } else {
        final mtmdPath = '$dir${Platform.pathSeparator}$mtmdName';
        if (File(mtmdPath).existsSync()) {
          try {
            mtmd = DynamicLibrary.open(mtmdPath);
          } on ArgumentError {
            // Skip silently; mtmd is best-effort.
          }
        }
      }
    }
    _mtmdLib = mtmd;

    // Official llama.cpp Windows builds split ggml across several DLLs:
    //
    //   llama.dll        — llama_* public C API only
    //   ggml-base.dll    — the core ggml_* C API
    //   ggml.dll         — backend registry + loader (ggml_backend_load_all…)
    //   ggml-cpu-*.dll   — CPU implementations (feature-dispatched variants)
    //
    // The FFI bindings, however, resolve *all* non-mtmd symbols through the
    // llama handle: when ggml is linked into libllama (macOS dylib builds,
    // the Android AAR) the symbols land there. With the official DLLs they
    // can't, so install a lookup fallback chain across those DLLs.
    //
    // Only Windows populates it; other platforms keep symbol resolution
    // unchanged.
    final llamaDir = _dirOf(openPath);
    if (Platform.isWindows &&
        llamaDir != null &&
        !_canLookup<NativeFunction<Void Function()>>(
          llama,
          'ggml_backend_load_all_from_path',
        )) {
      _openWindowsGgmlFallbacks(llamaDir);
    }

    final bindings = LlamaBindings.fromLookup(_routedLookup);
    bindings.llama_backend_init();

    // On Android, set ADSP_LIBRARY_PATH so the Hexagon/FastRPC layer can
    // locate `libggml-htp-v*.so` skeleton libs. Must happen before
    // ggml_backend_load_all triggers ggml-hexagon's backend init. The dir
    // is the directory holding the loaded `libllama.so` — discovered from
    // `/proc/self/maps` when [path] was a basename.
    if (Platform.isAndroid) {
      final adspDir = dir ?? _resolveAndroidLibraryDir(openPath);
      if (adspDir != null) {
        _setAdspLibraryPath(adspDir);
      }
    }

    if (dir != null) {
      final dirPtr = dir.toNativeUtf8(allocator: calloc);
      try {
        bindings.ggml_backend_load_all_from_path(dirPtr.cast());
      } finally {
        calloc.free(dirPtr);
      }
    } else {
      bindings.ggml_backend_load_all();
    }

    _bindings = bindings;
    _libraryPath = openPath;
    _libraryDir =
        dir ??
        (Platform.isAndroid ? _resolveAndroidLibraryDir(openPath) : null);
  }

  /// True when the optional libmtmd dylib was successfully opened
  /// alongside libllama. False means multimodal calls will fail at lookup.
  static bool get isMultimodalAvailable => _mtmdLib != null;

  static Pointer<T> _routedLookup<T extends NativeType>(String name) {
    if (name.startsWith('mtmd_')) {
      final m = _mtmdLib;
      if (m == null) {
        throw LlamaLibraryException(
          'mtmd symbol "$name" requested but libmtmd is not loaded. '
          'Build with --with-mtmd and ensure libmtmd is shipped beside libllama.',
        );
      }
      return m.lookup<T>(name);
    }
    final llama = _llamaLib!;
    try {
      return llama.lookup<T>(name);
    } on ArgumentError {
      // Fall through the Windows ggml DLL family before giving up. Kept
      // empty on every other platform (see load() for when it is filled).
      for (final lib in _ggmlFallbackLibs) {
        try {
          return lib.lookup<T>(name);
        } on ArgumentError {
          continue;
        }
      }
      rethrow;
    }
  }

  /// True when [lib] exports [name]. Existence check only — the signature is
  /// not validated here.
  static bool _canLookup<T extends NativeType>(
    DynamicLibrary lib,
    String name,
  ) {
    try {
      lib.lookup<T>(name);
      return true;
    } on ArgumentError {
      return false;
    }
  }

  /// Register [dir] in the Windows DLL search path so LoadLibrary calls made
  /// afterwards — including dependency resolution of the libraries we open —
  /// consult it. Implemented on top of `SetDllDirectoryW`, best effort: a
  /// failure here is not fatal because the subsequent open reports a clear
  /// error if dependency resolution ends up broken anyway.
  static void _setWindowsSearchDirectory(String dir) {
    try {
      final kernel32 = _kernel32 ??= DynamicLibrary.open('kernel32.dll');
      final setDir = kernel32
          .lookupFunction<
            Int32 Function(Pointer<Utf16>),
            int Function(Pointer<Utf16>)
          >('SetDllDirectoryW');
      final nativeDir = dir.toNativeUtf16();
      setDir(nativeDir);
      malloc.free(nativeDir);
    } catch (_) {
      // Best effort, as documented.
    }
  }

  /// Populate [_ggmlFallbackLibs] from the DLLs sitting beside llama.dll.
  ///
  /// Order matters: `ggml-base.dll` exports the bulk of the `ggml_*` C API,
  /// `ggml-cpu-*.dll` variants export the CPU helpers (`ggml_cpu_has_*`,
  /// `ggml_threadpool_*`, …), and `ggml.dll` (the router) exports the
  /// backend loader/registry calls (`ggml_backend_load_all`, …).
  static void _openWindowsGgmlFallbacks(String dir) {
    final d = Directory(dir);
    if (!d.existsSync()) return;

    int rankOf(String name) {
      if (name == 'ggml-base.dll') return 0;
      if (name == 'ggml.dll') return 2;
      return 1;
    }

    final candidates =
        d
            .listSync()
            .whereType<File>()
            .map((f) => f.path.split(Platform.pathSeparator).last)
            .where(
              (name) =>
                  name == 'ggml-base.dll' ||
                  name == 'ggml.dll' ||
                  (name.startsWith('ggml-cpu') && name.endsWith('.dll')),
            )
            .toList()
          ..sort((a, b) {
            final byRole = rankOf(a).compareTo(rankOf(b));
            if (byRole != 0) return byRole;
            return a.compareTo(b);
          });

    for (final name in candidates) {
      final path = '${d.path}${Platform.pathSeparator}$name';
      try {
        _ggmlFallbackLibs.add(DynamicLibrary.open(path));
      } on ArgumentError {
        // Skip silently; the routed lookup surfaces a real error later if
        // a symbol we need is genuinely missing.
      }
    }
  }

  static String? _mtmdFileName() {
    if (Platform.isMacOS) return 'libmtmd.dylib';
    if (Platform.isLinux || Platform.isAndroid) return 'libmtmd.so';
    if (Platform.isWindows) return 'mtmd.dll';
    return null;
  }

  /// Resolve symbols from the running process instead of opening a
  /// separate dylib.
  ///
  /// Use this when the llama.cpp static archive (e.g. an iOS xcframework
  /// slice or a macOS app that links `llama.framework` directly) was
  /// linked into the app binary by Xcode. There's no `.dylib` to dlopen —
  /// the symbols are already part of the process. Equivalent to
  /// `LlamaLibrary.load(path: '...')` but without a path.
  ///
  /// Idempotent. Mixing this with [load] in the same isolate throws.
  static void loadFromProcess() {
    if (_bindings != null) {
      if (_libraryPath == r'<process>') return;
      throw LlamaLibraryException(
        'A different llama library is already loaded: $_libraryPath',
      );
    }

    final lib = DynamicLibrary.process();
    _llamaLib = lib;
    _mtmdLib = lib; // same process namespace; mtmd is statically linked too

    final bindings = LlamaBindings.fromLookup(_routedLookup);
    bindings.llama_backend_init();
    bindings.ggml_backend_load_all();

    _bindings = bindings;
    _libraryPath = r'<process>';
    _libraryDir = null;
  }

  /// Drop the cached bindings reference for this isolate.
  ///
  /// Does NOT call `llama_backend_free` — backend init is process-global
  /// and freeing it from one isolate while another still holds models
  /// crashes the second isolate's `llama_free`. Process exit reclaims the
  /// backend state.
  ///
  /// Does clear any installed log callback first. A callback set by
  /// [LlamaLog.silence] is a `Pointer.fromFunction` bound to the isolate
  /// that registered it, but the slot it occupies lives in process-global
  /// llama.cpp/ggml state and outlives this isolate. Leaving it installed
  /// means the next isolate to emit a log line invokes a callback owned by
  /// a dead isolate, which aborts the VM with "Cannot invoke native
  /// callback from a different isolate".
  static void dispose() {
    if (_bindings == null) return;
    // Must run while _bindings is still non-null — useDefault() needs it.
    LlamaLog.useDefault();
    _bindings = null;
    _libraryPath = null;
    _libraryDir = null;
    _llamaLib = null;
    _mtmdLib = null;
    _ggmlFallbackLibs.clear();
  }

  /// Default file name for the llama library on the current platform.
  /// Useful when writing test helpers; not used by [load].
  static String defaultFileName() {
    if (Platform.isMacOS) return 'libllama.dylib';
    if (Platform.isIOS) return 'llama.framework/llama';
    if (Platform.isAndroid || Platform.isLinux) return 'libllama.so';
    if (Platform.isWindows) return 'llama.dll';
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  static String? _dirOf(String path) {
    final i = path.lastIndexOf(Platform.pathSeparator);
    if (i < 0) return null;
    return path.substring(0, i);
  }

  /// Find where Android's linker resolved `libllama.so` from by reading
  /// `/proc/self/maps`. Returns the dirname of the matching mapping, or
  /// `null` if the library can't be found in the maps (e.g. process
  /// failed to load it). [requestedPath] is the path passed to [load] —
  /// either a basename (`libllama.so`) or an absolute path.
  static String? _resolveAndroidLibraryDir(String requestedPath) {
    final basename = requestedPath.contains('/')
        ? requestedPath.substring(requestedPath.lastIndexOf('/') + 1)
        : requestedPath;
    try {
      final maps = File('/proc/self/maps').readAsLinesSync();
      for (final line in maps) {
        // Format: "addr-addr perms offset dev inode  /path/to/lib.so"
        final slash = line.indexOf('/');
        if (slash < 0) continue;
        final libPath = line.substring(slash).trim();
        if (libPath.endsWith('/$basename')) {
          final i = libPath.lastIndexOf('/');
          return libPath.substring(0, i);
        }
      }
    } on FileSystemException {
      // /proc not readable — bail.
    }
    return null;
  }

  /// `setenv("ADSP_LIBRARY_PATH", dir, 1)` via libc on Android. Used so
  /// FastRPC can find `libggml-htp-v*.so` skeleton libs at HTP backend
  /// init time. Failures are swallowed: this is a hint, not a contract,
  /// and the rest of the binding still works without it.
  static void _setAdspLibraryPath(String dir) {
    try {
      final libc = DynamicLibrary.open('libc.so');
      final setenv = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('setenv');
      final keyPtr = 'ADSP_LIBRARY_PATH'.toNativeUtf8();
      final valPtr = dir.toNativeUtf8();
      try {
        setenv(keyPtr, valPtr, 1);
      } finally {
        malloc.free(keyPtr);
        malloc.free(valPtr);
      }
    } on ArgumentError {
      // libc lookup failed — older NDK or non-Android-Linux. Skip.
    }
  }
}

/// NUMA strategy passed to [LlamaLibrary.initNuma]. Only meaningful on
/// multi-socket Linux servers; ignored elsewhere.
enum NumaStrategy {
  /// NUMA awareness disabled (default).
  disabled(0),

  /// Spread threads across NUMA nodes.
  distribute(1),

  /// Pin threads to a single NUMA node.
  isolate(2),

  /// Honor an external `numactl --cpunodebind` placement.
  numactl(3),

  /// Mirror model weights on every NUMA node (uses more RAM, lower
  /// cross-socket traffic).
  mirror(4);

  final int value;
  const NumaStrategy(this.value);
}
