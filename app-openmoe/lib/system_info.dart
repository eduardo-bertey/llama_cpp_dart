/// System dashboard: CPU, RAM and GPU telemetry for the launcher screen.
///
/// Read straight from the Windows API with dart:ffi — no child processes,
/// no PowerShell, no registry access:
///   * `GlobalMemoryStatusEx` (kernel32) → RAM totals + memory load;
///   * `GetNativeSystemInfo` (kernel32) → logical-core count;
///   * `GetLogicalProcessorInformationEx` (kernel32) → physical cores;
///   * `GetProcessMemoryInfo` (psapi) → RSS of this app;
///   * `GetSystemTimes` (kernel32) → CPU load %;
///   * `CreateDXGIFactory1` (dxgi) → GPU name + dedicated VRAM;
///   * llama.cpp (`systemInfo()`) for the inference-side feature flags once
///     the library is loaded.
///
/// Every collector is independent and wrapped in its own try/catch: one bad
/// piece never blanks the whole panel.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

final class SystemSnapshot {
  final String cpuName;
  final int physicalCores;
  final int logicalCores;
  final double? cpuLoadPercent;
  final double ramTotalGb;
  final double ramFreeGb;
  final double processRssMb;
  final String gpuName;
  final double? gpuVramTotalMb;
  final String detail;

  const SystemSnapshot({
    required this.cpuName,
    required this.physicalCores,
    required this.logicalCores,
    required this.cpuLoadPercent,
    required this.ramTotalGb,
    required this.ramFreeGb,
    required this.processRssMb,
    required this.gpuName,
    required this.gpuVramTotalMb,
    required this.detail,
  });

  static const empty = SystemSnapshot(
    cpuName: 'Procesador',
    physicalCores: 0,
    logicalCores: 0,
    cpuLoadPercent: null,
    ramTotalGb: 0,
    ramFreeGb: 0,
    processRssMb: 0,
    gpuName: '(GPU no detectada)',
    gpuVramTotalMb: null,
    detail: '',
  );

  double get ramUsedGb {
    final used = ramTotalGb - ramFreeGb;
    if (used < 0) return 0;
    if (used > ramTotalGb) return ramTotalGb;
    return used;
  }
}

/// Polls the OS every [interval] while the panel is open.
final class SystemFeed {
  final Duration interval;
  Timer? _timer;
  final StreamController<SystemSnapshot> _controller =
      StreamController.broadcast();

  SystemFeed({this.interval = const Duration(seconds: 4)});

  Stream<SystemSnapshot> get stream => _controller.stream;

  void start() {
    _timer?.cancel();
    _sample();
    _timer = Timer.periodic(interval, (_) => _sample());
  }

  void stop() => _timer?.cancel();

  void dispose() {
    stop();
    _controller.close();
  }

  void _sample() {
    try {
      if (!_controller.isClosed) _controller.add(collect());
    } catch (_) {
      // Keep the last values; the panel tolerates flaky queries.
    }
  }
}

// ── CPU-load delta state (GetSystemTimes is cumulative) ──────────────────────

_FileTimeBox? _prevTimes;

typedef _FileTimeBox = ({int idle, int kernel, int user});

/// Collect a fresh snapshot. Never throws for missing pieces; whatever the
/// OS answers is what the panel shows.
SystemSnapshot collect() {
  var physicalCores = 0;
  var logicalCores = 0;
  var ramTotalGb = 0.0;
  var ramFreeGb = 0.0;
  var processRssMb = 0.0;
  double? cpuLoadPercent;
  final gpuParts = <String>[];
  double? gpuVramTotalMb;

  if (Platform.isWindows) {
    try {
      final mem = _globalMemoryStatus();
      ramTotalGb = mem.$1 / (1024 * 1024 * 1024);
      ramFreeGb = mem.$2 / (1024 * 1024 * 1024);
    } catch (_) {}

    try {
      final counts = _processorCounts();
      physicalCores = counts.$1;
      logicalCores = counts.$2;
    } catch (_) {}

    try {
      final rss = _currentProcessRss();
      if (rss != null) processRssMb = rss / (1024 * 1024);
    } catch (_) {}

    try {
      final load = _cpuLoadPercent();
      if (load != null) cpuLoadPercent = load;
    } catch (_) {}

    try {
      final gpus = _dxgiAdapters();
      if (gpus.isNotEmpty) {
        gpuParts.addAll(gpus.map((g) => g.$1));
        gpuVramTotalMb = gpus.first.$2 / (1024 * 1024);
      }
    } catch (_) {}
  }

  String llamaInfo = '';
  try {
    llamaInfo = LlamaLibrary.isLoaded ? LlamaLibrary.systemInfo().trim() : '';
  } catch (_) {}

  return SystemSnapshot(
    cpuName: 'Procesador',
    physicalCores: physicalCores,
    logicalCores: logicalCores,
    cpuLoadPercent: cpuLoadPercent,
    ramTotalGb: ramTotalGb,
    ramFreeGb: ramFreeGb,
    processRssMb: processRssMb,
    gpuName: gpuParts.isEmpty ? '(GPU no detectada)' : gpuParts.join(' / '),
    gpuVramTotalMb: gpuVramTotalMb,
    detail: llamaInfo,
  );
}

// ─── kernel32 ────────────────────────────────────────────────────────────────

final DynamicLibrary? _kernel32 = Platform.isWindows
    ? DynamicLibrary.open('kernel32.dll')
    : null;

final class _MemoryStatusEx extends Struct {
  @Uint32()
  external int dwLength;

  @Uint32()
  external int dwMemoryLoad;

  @Uint64()
  external int ullTotalPhys;

  @Uint64()
  external int ullAvailPhys;

  @Uint64()
  external int ullTotalPageFile;

  @Uint64()
  external int ullAvailPageFile;

  @Uint64()
  external int ullTotalVirtual;

  @Uint64()
  external int ullAvailVirtual;

  @Uint64()
  external int ullAvailExtendedVirtual;
}

final class _SystemInfoStruct extends Struct {
  @Uint16()
  external int wProcessorArchitecture;

  @Uint16()
  external int wReserved;

  @Uint32()
  external int dwPageSize;

  external Pointer<Void> lpMinimumApplicationAddress;

  external Pointer<Void> lpMaximumApplicationAddress;

  @UintPtr()
  external int dwActiveProcessorMask;

  @Uint32()
  external int dwNumberOfProcessors;

  @Uint32()
  external int dwProcessorType;

  @Uint32()
  external int dwAllocationGranularity;

  @Uint16()
  external int wProcessorLevel;

  @Uint16()
  external int wProcessorRevision;
}

/// (totalBytes, availableBytes) via GlobalMemoryStatusEx.
(int, int) _globalMemoryStatus() {
  final k32 = _kernel32!;
  final gms = k32
      .lookupFunction<
        Int32 Function(Pointer<_MemoryStatusEx>),
        int Function(Pointer<_MemoryStatusEx>)
      >('GlobalMemoryStatusEx');
  final ms = calloc<_MemoryStatusEx>();
  ms.ref.dwLength = sizeOf<_MemoryStatusEx>();
  final result = gms(ms);
  final total = ms.ref.ullTotalPhys;
  final avail = ms.ref.ullAvailPhys;
  calloc.free(ms);
  if (result == 0) {
    throw StateError('GlobalMemoryStatusEx failed');
  }
  return (total, avail);
}

/// (physicalCores, logicalCores). Logical count from GetNativeSystemInfo
/// (cheap); physical from GetLogicalProcessorInformationEx — best effort.
(int, int) _processorCounts() {
  final k32 = _kernel32!;
  final gsi = k32
      .lookupFunction<
        Void Function(Pointer<_SystemInfoStruct>),
        void Function(Pointer<_SystemInfoStruct>)
      >('GetNativeSystemInfo');
  final si = calloc<_SystemInfoStruct>();
  gsi(si);
  final logical = si.ref.dwNumberOfProcessors;
  calloc.free(si);

  var physical = 0;
  try {
    final glpie = k32
        .lookupFunction<
          Int32 Function(Int32, Pointer<Void>, Pointer<Uint32>),
          int Function(int, Pointer<Void>, Pointer<Uint32>)
        >('GetLogicalProcessorInformationEx');
    final needed = calloc<Uint32>();
    // RelationAll = 0xFFFF; first call just asks for the buffer size
    // (returns 0 with ERROR_INSUFFICIENT_BUFFER = 122).
    glpie(0xFFFF, nullptr, needed);
    final buf = calloc<Uint8>(needed.value);
    final ok = glpie(0xFFFF, buf.cast<Void>(), needed) != 0;
    if (ok) {
      // SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX entries start with
      // { DWORD Relationship; DWORD Size; <payload> }.
      var offset = 0;
      final size = needed.value;
      while (offset + 8 <= size) {
        final rel = (buf + offset).cast<Uint32>();
        final len = (buf + offset + 4).cast<Uint32>();
        if (len.value < 8) break;
        // RelationProcessorCore = 0.
        if (rel.value == 0) physical++;
        offset += len.value;
      }
    }
    calloc.free(buf);
    calloc.free(needed);
  } catch (_) {
    physical = 0;
  }

  return (physical, logical);
}

/// RSS of this process in bytes, via psapi GetProcessMemoryInfo.
int? _currentProcessRss() {
  if (!Platform.isWindows) return null;
  final psapi = DynamicLibrary.open('psapi.dll');
  final gpmi = psapi
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint8>, Uint32),
        int Function(int, Pointer<Uint8>, int)
      >('GetProcessMemoryInfo');
  // GetCurrentProcess() pseudo-handle is (HANDLE)-1 for the Win64 ABI.
  final buf = calloc<Uint8>(256);
  final ok = gpmi(-1, buf, 256) != 0;
  if (!ok) {
    calloc.free(buf);
    return null;
  }
  // PROCESS_MEMORY_COUNTERS x64: cb(0), PageFaultCount(4),
  // PeakWorkingSetSize(8), WorkingSetSize(16) …
  final rss = (buf + 16).cast<UintPtr>().value;
  calloc.free(buf);
  return rss;
}

/// CPU load percent from GetSystemTimes deltas.
///
/// NOTE: on Windows the kernel counter *includes* idle time, so
/// load = ((kernel+user) − idle) / (kernel+user). First call has no previous
/// sample and returns null; the panel handles that.
double? _cpuLoadPercent() {
  final k32 = _kernel32!;
  final gst = k32
      .lookupFunction<
        Int32 Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
        int Function(Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)
      >('GetSystemTimes');
  final idle = calloc<Uint64>();
  final kernel = calloc<Uint64>();
  final user = calloc<Uint64>();
  final ok = gst(idle, kernel, user) != 0;
  final i = idle.value;
  final k = kernel.value;
  final u = user.value;
  calloc.free(idle);
  calloc.free(kernel);
  calloc.free(user);
  if (!ok) return null;

  final prev = _prevTimes;
  _prevTimes = (idle: i, kernel: k, user: u);
  if (prev == null) return null;

  final idleDelta = (i - prev.idle).abs();
  final totalDelta = (k - prev.kernel).abs() + (u - prev.user).abs();
  if (totalDelta == 0) return null;
  final percent = (totalDelta - idleDelta) / totalDelta * 100.0;
  if (percent < 0) return 0;
  if (percent > 100) return 100;
  return double.parse(percent.toStringAsFixed(1));
}

// ─── dxgi (COM — GPU name + dedicated VRAM) ─────────────────────────────────

typedef _EnumAdapters1Native = Int32 Function(
  Pointer<Void> self,
  Uint32 index,
  Pointer<Pointer<Void>> adapterOut,
);
typedef _EnumAdapters1Dart = int Function(
  Pointer<Void> self,
  int index,
  Pointer<Pointer<Void>> adapterOut,
);

typedef _GetDesc1Native = Int32 Function(
  Pointer<Void> self,
  Pointer<Uint8> desc,
);
typedef _GetDesc1Dart = int Function(Pointer<Void> self, Pointer<Uint8> desc);

typedef _CreateDxgiFactory1Native = Int32 Function(
  Pointer<Uint8> riid,
  Pointer<Pointer<Void>> factoryOut,
);
typedef _CreateDxgiFactory1Dart = int Function(
  Pointer<Uint8> riid,
  Pointer<Pointer<Void>> factoryOut,
);

/// IID_IDXGIFactory1 {770AAE78-F26F-4DBA-A829-253C83D1B387}, little-endian.
const List<int> _iidFactory1 = [
  0x78, 0xae, 0x0a, 0x77, 0x6f, 0xf2, 0xba, 0x4d, //
  0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87,
];

/// Enumerate GPUs through DXGI. Returns (name, dedicatedVramBytes).
List<(String, int)> _dxgiAdapters() {
  final DynamicLibrary dxgi;
  try {
    dxgi = DynamicLibrary.open('dxgi.dll');
  } catch (_) {
    return const [];
  }

  final createFactory = dxgi
      .lookupFunction<_CreateDxgiFactory1Native, _CreateDxgiFactory1Dart>(
        'CreateDXGIFactory1',
      );
  final factoryOut = calloc<Pointer<Void>>();
  final riid = calloc<Uint8>(16);
  for (var i = 0; i < 16; i++) {
    riid[i] = _iidFactory1[i];
  }
  final hr = createFactory(riid, factoryOut);
  calloc.free(riid);
  if (hr != 0 || factoryOut.value == nullptr) {
    calloc.free(factoryOut);
    return const [];
  }
  final factory = factoryOut.value;
  calloc.free(factoryOut);

  final results = <(String, int)>[];
  try {
    // COM vtable: IUnknown(0..2) · IDXGIObject(3..6) · IDXGIFactory(7..10)
    // · idxgifactory1::EnumAdapters1 = 11.
    final factoryVtable = factory
        .cast<Pointer<Pointer<NativeFunction<_EnumAdapters1Native>>>>()
        .value;
    final enumAdapters1 = factoryVtable[11].asFunction<_EnumAdapters1Dart>();
    for (var index = 0; index < 8; index++) {
      final adapterOut = calloc<Pointer<Void>>();
      final r = enumAdapters1(factory, index, adapterOut);
      final adapter = adapterOut.value;
      calloc.free(adapterOut);
      if (r != 0 || adapter == nullptr) break;
      try {
        // idxgiadapter::EnumOutputs(7) GetDesc(8) CheckInterfaceSupport(9)
        // · idxgiadapter1::GetDesc1 = 10.
        final adapterVtable = adapter
            .cast<Pointer<Pointer<NativeFunction<_GetDesc1Native>>>>()
            .value;
        final getDesc1 = adapterVtable[10].asFunction<_GetDesc1Dart>();
        final desc = calloc<Uint8>(312);
        final ok = getDesc1(adapter, desc) == 0;
        if (ok) {
          final chars = desc.cast<Uint16>().asTypedList(128);
          var len = 0;
          while (len < 128 && chars[len] != 0) {
            len++;
          }
          final name = String.fromCharCodes(chars.sublist(0, len));
          final vram = (desc + 272).cast<UintPtr>().value;
          if (name.isNotEmpty) results.add((name, vram));
        }
        calloc.free(desc);
      } finally {
        _comRelease(adapter);
      }
    }
  } finally {
    _comRelease(factory);
  }
  return results;
}

void _comRelease(Pointer<Void> comObject) {
  if (comObject == nullptr) return;
  try {
    final vtable = comObject
        .cast<Pointer<Pointer<NativeFunction<Int32 Function(Pointer<Void>)>>>>()
        .value;
    // IUnknown::Release is always slot 2.
    final release = vtable[2].asFunction<int Function(Pointer<Void>)>();
    release(comObject);
  } catch (_) {
    // Leak instead of crash.
  }
}

// ─── UI ──────────────────────────────────────────────────────────────────────

/// The visual panel, driven by a [SystemFeed].
final class SystemPanel extends StatefulWidget {
  const SystemPanel({super.key});

  @override
  State<SystemPanel> createState() => _SystemPanelState();
}

class _SystemPanelState extends State<SystemPanel> {
  SystemFeed? _feed;
  SystemSnapshot _snapshot = SystemSnapshot.empty;

  @override
  void initState() {
    super.initState();
    _feed = SystemFeed()
      ..stream.listen((snapshot) {
        if (mounted) setState(() => _snapshot = snapshot);
      })
      ..start();
  }

  @override
  void dispose() {
    _feed?.dispose();
    super.dispose();
  }

  double _fraction(double used, double total) {
    if (total <= 0) return 0;
    final value = used / total;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }

  Widget _meterRow(
    String label,
    String detail,
    double? fraction, {
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        SizedBox(width: 52, child: Text(label)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              if (fraction == null)
                Text(
                  'midiendo en el próximo tick…',
                  style: theme.textTheme.labelSmall,
                )
              else
                LinearProgressIndicator(value: fraction),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _snapshot;
    final loadText = s.cpuLoadPercent == null
        ? ''
        : ' · ${s.cpuLoadPercent!.toStringAsFixed(0)}%';
    final vramText = s.gpuVramTotalMb == null
        ? ''
        : '  ·  VRAM ${_fmtMb(s.gpuVramTotalMb!)}';

    return SizedBox(
      width: 480,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.monitor_heart),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sistema',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  'actualiza cada 4 s',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _meterRow(
              'CPU',
              '${s.physicalCores == 0 ? '' : '${s.physicalCores} núcleos · '}'
                  '${s.logicalCores} hilos$loadText',
              s.cpuLoadPercent == null ? null : s.cpuLoadPercent! / 100,
              icon: Icons.memory,
            ),
            const SizedBox(height: 10),
            _meterRow(
              'RAM',
              '${s.ramUsedGb.toStringAsFixed(1)} / '
                  '${s.ramTotalGb.toStringAsFixed(1)} GB'
                  '  ·  proceso: ${s.processRssMb.toStringAsFixed(0)} MB',
              s.ramTotalGb <= 0 ? null : _fraction(s.ramUsedGb, s.ramTotalGb),
              icon: Icons.storage,
            ),
            const SizedBox(height: 10),
            _meterRow(
              'GPU',
              '${s.gpuName}$vramText',
              null, // DXGI no expone VRAM usada sin COM extra; solo datos.
              icon: Icons.developer_board,
            ),
            if (s.detail.isNotEmpty) ...[
              const Divider(height: 20),
              SelectableText(
                'llama.cpp: ${s.detail}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtMb(double mb) {
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }
}

/// Opens the system dashboard as a modal bottom sheet.
void showSystemPanelSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const SystemPanel(),
  );
}
