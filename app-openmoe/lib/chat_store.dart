import 'dart:convert';
import 'dart:io';

import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import 'app_paths.dart';

/// One previously saved chat: native KV restart point + its metadata.
final class SavedChat {
  /// State-file key = model basename without `.gguf`.
  final String key;
  final String modelPath;
  final String? mmprojPath;
  final String title;
  final DateTime savedAt;
  final int messageCount;

  const SavedChat({
    required this.key,
    required this.modelPath,
    required this.mmprojPath,
    required this.title,
    required this.savedAt,
    required this.messageCount,
  });

  String get statePath => '${AppPaths.chatsDir}\\$key.sstate';
}

/// Every chat saved so far, newest first.
List<SavedChat> listSavedChats() {
  final dir = Directory(AppPaths.chatsDir);
  if (!dir.existsSync()) return const <SavedChat>[];
  final out = <SavedChat>[];
  for (final f in dir.listSync().whereType<File>().where(
    (f) => f.path.endsWith('.meta.json'),
  )) {
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      out.add(
        SavedChat(
          key: j['key']! as String,
          modelPath: j['modelPath']! as String,
          mmprojPath: j['mmprojPath'] as String?,
          title: j['title']! as String,
          savedAt: DateTime.tryParse(j['savedAt'] as String) ?? DateTime.now(),
          messageCount: j['messageCount'] as int? ?? 0,
        ),
      );
    } catch (_) {
      // Corrupt metadata — skip it, the state file alone is useless.
    }
  }
  out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
  return out;
}

/// Persist the chat right now: native state (KV + tokens + history) plus a
/// metadata sidecar so the launcher can restore it with the right model.
Future<void> saveChatSession(
  EngineChat chat, {
  required String key,
  required String modelPath,
  String? mmprojPath,
  required String title,
}) async {
  final dir = Directory(AppPaths.chatsDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);

  final statePath = '${AppPaths.chatsDir}\\$key.sstate';
  await chat.saveState(statePath);

  File('${AppPaths.chatsDir}\\$key.meta.json').writeAsStringSync(
    const JsonEncoder.withIndent(' ').convert(<String, Object?>{
      'key': key,
      'modelPath': modelPath,
      'mmprojPath': mmprojPath,
      'title': title,
      'savedAt': DateTime.now().toIso8601String(),
      'messageCount': chat.messageCount,
    }),
  );
}

/// Remove both files of a saved chat. Returns true if anything was deleted.
bool deleteSavedChat(String key) {
  var deleted = false;
  for (final suffix in ['.sstate', '.meta.json']) {
    final f = File('${AppPaths.chatsDir}\\$key$suffix');
    if (f.existsSync()) deleted = true;
    f.deleteSync();
  }
  return deleted;
}
