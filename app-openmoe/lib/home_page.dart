import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_paths.dart';
import 'chat_store.dart';
import 'hf_models.dart';
import 'models_page.dart';
import 'settings_page.dart';
import 'system_info.dart';

/// App entry screen: downloaded-models list + "recuperar chat" + entry
/// points to the models (download) and settings pages.
class HomePage extends StatefulWidget {
  final String? lastSessionCrash;

  const HomePage({super.key, this.lastSessionCrash});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _dll;
  List<File> _downloadedModels = <File>[];
  List<SavedChat> _savedChats = const <SavedChat>[];

  @override
  void initState() {
    super.initState();
    _refresh();
    if (widget.lastSessionCrash != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Error desde la última sesión'),
            content: SingleChildScrollView(
              child: SelectableText(widget.lastSessionCrash!),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cerrar'),
              ),
            ],
          ),
        );
      });
    }
  }

  void _refresh() {
    _dll = AppPaths.detectLibraryPath();

    final dir = Directory(AppPaths.resolveModelsDir);
    final models = <File>[];
    if (dir.existsSync()) {
      for (final entity in dir.listSync().whereType<File>()) {
        final name = entity.uri.pathSegments.last.toLowerCase();
        if (name.endsWith('.gguf') && !name.startsWith('mmproj')) {
          models.add(entity);
        }
      }
      models.sort(
        (a, b) =>
            File(a.path).lengthSync().compareTo(File(b.path).lengthSync()),
      );
    }
    _downloadedModels = models;

    _savedChats = listSavedChats();
  }

  Future<void> _openChat({
    required String modelPath,
    String? mmprojPath,
    String? restoreStatePath,
  }) async {
    final key = AppPaths.keyForModel(modelPath);
    await launchChat(
      context,
      modelPath: modelPath,
      mmprojPath: mmprojPath,
      title: File(modelPath).uri.pathSegments.last,
      saveKey: key,
      restoreStatePath: restoreStatePath,
    );
    if (mounted) setState(_refresh);
  }

  Future<void> _openLocalGguf() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'GGUF', extensions: ['gguf']),
      ],
    );
    if (file == null) return;
    if (!mounted) return;
    await _openChat(modelPath: file.path);
  }

  @override
  Widget build(BuildContext context) {
    final libOk = _dll != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenMoe'),
        actions: [
          IconButton(
            tooltip: 'CPU, RAM y GPU de este equipo',
            icon: const Icon(Icons.monitor_heart),
            onPressed: () => showSystemPanelSheet(context),
          ),
          IconButton(
            tooltip: 'Ajustes',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              );
              if (mounted) setState(_refresh);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _libraryBanner(libOk),
          const SizedBox(height: 12),
          if (_downloadedModels.isEmpty) ...[
            const _EmptyModelsCard(),
            const SizedBox(height: 12),
          ] else ...[
            Text(
              'Modelos descargados',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final model in _downloadedModels)
              Card.filled(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    model.uri.pathSegments.last,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(humanSize(model.lengthSync())),
                  trailing: TextButton(
                    onPressed: () => unawaited(
                      _openChat(
                        modelPath: model.path,
                        mmprojPath: _pairMmproj(model.path),
                      ),
                    ),
                    child: const Text('Iniciar chat'),
                  ),
                  onTap: () => unawaited(
                    _openChat(
                      modelPath: model.path,
                      mmprojPath: _pairMmproj(model.path),
                    ),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          _chatsCard(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ModelsPage(),
                      ),
                    );
                    if (mounted) setState(_refresh);
                  },
                  icon: const Icon(Icons.download),
                  label: const Text('Descargar modelo'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openLocalGguf,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Cargar desde carpeta'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// If a mmproj projector shares the models folder, pair it automatically.
  String? _pairMmproj(String modelPath) {
    final dir = Directory(AppPaths.resolveModelsDir);
    if (!dir.existsSync()) return null;
    for (final f in dir.listSync().whereType<File>()) {
      if (f.path.toLowerCase().endsWith('.gguf') &&
          f.uri.pathSegments.last.toLowerCase().startsWith('mmproj')) {
        return f.path;
      }
    }
    return null;
  }

  Widget _libraryBanner(bool libOk) {
    return Card.filled(
      color: libOk ? null : Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: Icon(
          libOk ? Icons.check_circle : Icons.error_outline,
          color: libOk ? Colors.green : null,
        ),
        title: const Text('Librería llama.cpp'),
        subtitle: Text(
          libOk
              ? 'lista ($_dll)'
              : 'llama.dll no encontrada junto al exe (zip portable) — '
                    'ábrelo desde el release o elige la DLL en Ajustes',
        ),
        isThreeLine: !libOk,
      ),
    );
  }

  Widget _chatsCard() {
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.history, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Recuperar chat',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (_savedChats.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(0, 8, 0, 0),
                child: Text(
                  'Sin chats guardados. Cuando cierres un chat, se guarda '
                  'el estado y aparece aquí para continuar donde quedó.',
                ),
              )
            else
              for (final chat in _savedChats)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(chat.title, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${chat.messageCount} mensajes · '
                    '${chat.savedAt.toLocal().toString().split('.').first}',
                  ),
                  trailing: IconButton(
                    tooltip: 'Borrar',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      deleteSavedChat(chat.key);
                      setState(_refresh);
                    },
                  ),
                  onTap: () => unawaited(
                    _openChat(
                      modelPath: chat.modelPath,
                      mmprojPath: chat.mmprojPath,
                      restoreStatePath: chat.statePath,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

final class _EmptyModelsCard extends StatelessWidget {
  const _EmptyModelsCard();

  @override
  Widget build(BuildContext context) {
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'No hay modelos descargados',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Icon(Icons.download_for_offline_outlined),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Descarga un modelo del catálogo (por ejemplo SmolLM2 360M, '
              'Qwen 2.5 0.5B o Qwen 0.8B) o carga un GGUF desde una '
              'carpeta de tu PC.',
            ),
          ],
        ),
      ),
    );
  }
}
