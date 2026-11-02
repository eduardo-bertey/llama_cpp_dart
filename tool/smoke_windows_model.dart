// End-to-end Windows smoke test: official release DLLs + a real GGUF.
//
// Validates what the loader probe cannot: that the pinned FFI bindings are
// ABI-compatible with the llama.cpp release being shipped (a struct-layout
// mismatch segfaults the process at llama_model_load time — this script
// makes that failure loud instead of a silent app exit).
//
//   dart run tool/smoke_windows_model.dart <dir-with-llama.dll> <model.gguf>
//       [mmproj.gguf]
//
// Exits 0 after generating a few tokens; non-zero on any failure or native
// crash (the crashed process code becomes the exit code downstream).
library;

import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: smoke_windows_model.dart <dir-with-llama.dll> <model.gguf> '
      '[mmproj.gguf]',
    );
    exit(2);
  }
  final libDir = Directory(args[0]).absolute.path;
  final modelPath = File(args[1]).absolute.path;
  final mmprojPath = args.length > 2 ? File(args[2]).absolute.path : null;

  if (!File('$libDir\\llama.dll').existsSync()) {
    stderr.writeln('smoke: $libDir\\llama.dll not found');
    exit(2);
  }
  if (!File(modelPath).existsSync()) {
    stderr.writeln('smoke: model $modelPath not found');
    exit(2);
  }

  stdout.writeln(
    'smoke: spawning engine (lib=$libDir, '
    'model=$modelPath, mmproj=$mmprojPath) ...',
  );
  final engine = await LlamaEngine.spawn(
    libraryPath: '$libDir\\llama.dll',
    modelParams: ModelParams(path: modelPath, gpuLayers: 0),
    contextParams: const ContextParams(nCtx: 2048, nBatch: 256, nUbatch: 256),
    multimodalParams: mmprojPath != null
        ? MultimodalParams(mmprojPath: mmprojPath)
        : null,
  );
  stdout.writeln('smoke: engine up (vision=${engine.supportsVision})');

  final chat = await engine.createChat();
  chat.addSystem('Responde en una sola palabra.');
  chat.addUser('Di: ok');
  final buffer = StringBuffer();
  await for (final event in chat.generate(maxTokens: 16)) {
    switch (event) {
      case TokenEvent():
        buffer.write(event.text);
        stdout.write(event.text);
      case DoneEvent():
        buffer.write(event.trailingText);
        stdout.writeln();
      case ShiftEvent():
        break;
    }
  }
  stdout.writeln(
    'smoke: generated ${buffer.length} chars — model load OK, decode OK',
  );
  await engine.dispose();
  stdout.writeln('smoke: PASS');
}
