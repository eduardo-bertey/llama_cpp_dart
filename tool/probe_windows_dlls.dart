// Windows loader validation for the official llama.cpp release DLLs.
//
// Verifies that `LlamaLibrary.load()` — which now installs a SetDllDirectory
// search path and a ggml lookup fallback chain — works against an unpacked
// `llama-b*-bin-win-*-x64.zip` release, and that multimodal (mtmd) resolves.
//
//   dart run tool/probe_windows_dlls.dart <dir-with-llama.dll>
//
// Exits non-zero on any failure. Runs as a no-op (exit 0) on other platforms
// so it can live inside shared CI pipelines.
library;

import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

void main(List<String> args) {
  if (!Platform.isWindows) {
    stdout.writeln('probe_windows_dlls: not Windows, nothing to do.');
    return;
  }
  final dir = args.isNotEmpty
      ? args[0]
      : throw ArgumentError(
          'usage: probe_windows_dlls.dart <dir-containing-llama.dll>',
        );

  final llama = File('$dir\\llama.dll');
  final mtmd = File('$dir\\mtmd.dll');
  if (!llama.existsSync()) {
    stderr.writeln('probe_windows_dlls: ${llama.path} not found.');
    exit(2);
  }

  stdout.writeln('probe: opening ${llama.path} via LlamaLibrary.load() ...');
  LlamaLibrary.load(path: llama.path);
  stdout.writeln('probe: load OK');

  final info = LlamaLibrary.systemInfo();
  stdout.writeln(
    'probe: system info: ${info.isEmpty ? '(empty)' : info.trim()}',
  );
  stdout.writeln(
    'probe: mmap=${LlamaLibrary.supportsMmap} '
    'mlock=${LlamaLibrary.supportsMlock} '
    'rpc=${LlamaLibrary.supportsRpc} '
    'maxParallelSequences=${LlamaLibrary.maxParallelSequences}',
  );

  if (!mtmd.existsSync()) {
    stderr.writeln(
      'probe: WARNING ${mtmd.path} not found; multimodal will not work.',
    );
    exit(3);
  }
  if (!LlamaLibrary.isMultimodalAvailable) {
    stderr.writeln('probe: mtmd file exists but did not load.');
    exit(3);
  }
  stdout.writeln('probe: mtmd.dll loaded — multimodal available');

  stdout.writeln('probe: PASS');
}
