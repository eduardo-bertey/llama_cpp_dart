import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_paths.dart';
import 'chat_store.dart';
import 'system_info.dart';

/// Ajustes: ruta de llama.dll (información + override manual), carpeta de
/// modelos y chats guardados. Panel del sistema accesible desde aquí.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _dllPath;
  List<SavedChat> _savedChats = const <SavedChat>[];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _dllPath = AppPaths.detectLibraryPath();
      _savedChats = listSavedChats();
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickDll() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'llama.dll', extensions: ['dll']),
      ],
    );
    if (file == null) return;
    AppPaths.dllPathOverride = file.path;
    _refresh();
    _toast('llama.dll actualizada (solo esta sesión).');
  }

  Future<void> _pickModelsDir() async {
    final picked = await getDirectoryPath(
      initialDirectory: Directory(AppPaths.resolveModelsDir).existsSync()
          ? AppPaths.resolveModelsDir
          : null,
    );
    if (picked == null || picked.isEmpty) return;
    AppPaths.modelsDirOverride = picked;
    _refresh();
    _toast('Carpeta de modelos actualizada (solo esta sesión).');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _dllCard(),
          const SizedBox(height: 12),
          _modelsDirCard(),
          const SizedBox(height: 12),
          _savedChatsCard(),
          const SizedBox(height: 12),
          _systemCard(),
          const SizedBox(height: 12),
          const _AboutCard(),
        ],
      ),
    );
  }

  Widget _dllCard() {
    final theme = Theme.of(context);
    final found = _dllPath != null;
    return Card.filled(
      color: found ? null : theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Librería llama.cpp', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              found
                  ? 'Cargando la DLL de esta ruta (información):'
                  : 'No se encontró llama.dll junto al exe (zip portable).',
            ),
            Text(
              _dllPath ?? '(ninguna)',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _pickDll,
                  icon: const Icon(Icons.file_open, size: 16),
                  label: const Text('Elegir otra llama.dll…'),
                ),
                if (AppPaths.dllPathOverride != null)
                  TextButton(
                    onPressed: () {
                      AppPaths.dllPathOverride = null;
                      _refresh();
                    },
                    child: const Text('Volver a la de siempre'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelsDirCard() {
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Carpeta de modelos',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text('Carpeta actual de descargas y de la lista principal:'),
            Text(
              AppPaths.resolveModelsDir,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _pickModelsDir,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Elegir otra carpeta…'),
                ),
                if (AppPaths.modelsDirOverride != null)
                  TextButton(
                    onPressed: () {
                      AppPaths.modelsDirOverride = null;
                      _refresh();
                    },
                    child: const Text('La de siempre'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _savedChatsCard() {
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Chats guardados',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_savedChats.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(0, 8, 0, 0),
                child: Text(
                  'Sin chats guardados. Todos se guardan al cerrar y se '
                  'sirven desde el menú principal.',
                ),
              )
            else
              for (final chat in _savedChats)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.chat_bubble_outline, size: 22),
                  title: Text(chat.title, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${chat.messageCount} mensajes'),
                  trailing: IconButton(
                    tooltip: 'Borrar chat',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      deleteSavedChat(chat.key);
                      _refresh();
                    },
                  ),
                  onTap: () async {
                    await launchChat(
                      context,
                      modelPath: chat.modelPath,
                      mmprojPath: chat.mmprojPath,
                      title: chat.title,
                      saveKey: chat.key,
                      restoreStatePath: chat.statePath,
                    );
                    _refresh();
                  },
                ),
          ],
        ),
      ),
    );
  }

  Widget _systemCard() {
    return Card.filled(
      child: ListTile(
        leading: const Icon(Icons.monitor_heart),
        title: const Text('Rendimiento del equipo'),
        subtitle: const Text(
          'CPU, RAM y GPU (se refresca cada 4 s), sin PowerShell ni registro',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showSystemPanelSheet(context),
      ),
    );
  }
}

final class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    return const Card.filled(
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Acerca de OpenMoe'),
            SizedBox(height: 4),
            Text(
              'Ejemplo de llama_cpp_dart: chat local con modelos GGUF '
              '(llama.cpp b12050). Los chats se guardan con el estado '
              'nativo del KV cache, así que continúan exactamente donde '
              'quedaron.',
            ),
          ],
        ),
      ),
    );
  }
}
