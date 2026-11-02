import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import 'chat_page.dart';
import 'crash_log.dart';

/// Shared paths and the llama.dll location heuristics for OpenMoe.
final class AppPaths {
  /// `C:\Users\<user>` or a harmless fallback.
  static String get userHome =>
      Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;

  /// Where downloaded GGUFs live by default.
  static String get modelsDir => '$userHome\\OpenMoe\\models';

  /// Where finished chats (KV state + history) are saved.
  static String get chatsDir => '$userHome\\OpenMoe\\chats';

  /// Where crash logs land.
  static String get logsDir => '$userHome\\OpenMoe\\logs';

  /// Session-only override for the models folder (Settings picks it).
  static String? modelsDirOverride;

  /// Session-only override for llama.dll chosen in Settings.
  static String? dllPathOverride;

  /// Resolved models folder (override wins).
  static String get resolveModelsDir =>
      modelsDirOverride != null && modelsDirOverride!.isNotEmpty
      ? modelsDirOverride!
      : modelsDir;

  /// llama.dll detection: the portable zip ships the DLLs beside the exe;
  /// anything else was chosen by hand in Settings.
  static String? detectLibraryPath() {
    final override = dllPathOverride;
    if (override != null && File(override).existsSync()) return override;
    final exeDir = Directory(File(Platform.resolvedExecutable).parent.path);
    final besideExe = '${exeDir.path}\\llama.dll';
    if (File(besideExe).existsSync()) return besideExe;
    if (override != null) return override;
    return null;
  }

  /// Safe state-file key from a model path (basename without extension).
  static String keyForModel(String modelPath) =>
      File(modelPath).uri.pathSegments.last.replaceAll('.gguf', '');
}

/// Loads a model, opens a chat (optionally restoring a previous session
/// from [restoreStatePath]) and pushes the chat page.
///
/// Returns true when a chat page was pushed — callers should refresh their
/// model lists afterwards (saved chats may have changed).
Future<bool> launchChat(
  BuildContext context, {
  required String modelPath,
  String? mmprojPath,
  required String title,
  required String saveKey,
  String? restoreStatePath,
}) async {
  final dll = AppPaths.detectLibraryPath();
  if (dll == null) {
    _snack(context, 'llama.dll no encontrada — revisa Ajustes.');
    return false;
  }
  if (!File(modelPath).existsSync()) {
    _snack(context, 'El GGUF no existe: $modelPath');
    return false;
  }
  if (mmprojPath != null && !File(mmprojPath).existsSync()) {
    mmprojPath = null;
  }

  // Breadcrumbs: if the native side faults, this is the last trace.
  unawaited(
    appendCrashLog(
      'engine-spawn: dll=$dll\n'
      '             model=$modelPath\n'
      '             mmproj=$mmprojPath\n'
      '             restore=$restoreStatePath',
    ),
  );

  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    ),
  );

  LlamaEngine? engine;
  try {
    engine = await LlamaEngine.spawn(
      libraryPath: dll,
      modelParams: ModelParams(path: modelPath, gpuLayers: 0),
      contextParams: const ContextParams(nCtx: 4096, nBatch: 512, nUbatch: 512),
      multimodalParams: mmprojPath != null
          ? MultimodalParams(mmprojPath: mmprojPath)
          : null,
    );
    final chat = await engine.createChat();
    if (restoreStatePath != null && File(restoreStatePath).existsSync()) {
      await chat.loadState(restoreStatePath);
    }
    unawaited(appendCrashLog('engine-spawn: OK, entrando al chat'));
    if (!context.mounted) {
      await engine.dispose();
      return false;
    }
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(
          engine: engine!,
          title: title,
          modelPath: modelPath,
          mmprojPath: mmprojPath,
          saveKey: saveKey,
          restoreStatePath: restoreStatePath,
        ),
      ),
    );
    return true;
  } catch (e, st) {
    unawaited(appendCrashLog('engine-spawn FAILED: $e\n$st'));
    if (context.mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    await engine?.dispose();
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('No se pudo iniciar el modelo'),
          content: SingleChildScrollView(child: Text('$e')),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
    }
    return false;
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}
