import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

import 'chat_page.dart';
import 'hf_download.dart';
import 'hf_models.dart';
import 'system_info.dart';

/// Launcher screen: library path, model catalog with download + confirmation,
/// then into the chat once the engine is live.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  late final TextEditingController _libController;
  late final HfDownloader _downloader;
  HfModelEntry? _selected;
  HfDownloadProgress? _progress;
  bool _downloading = false;
  bool _booting = false;
  String? _localModelPath;
  String? _localMmprojPath;

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['USERPROFILE'] ?? r'C:\';
    _libController = TextEditingController(
      text: '$home\\Desktop\\llama\\llama.dll',
    );
    _downloader = HfDownloader();
    // Preselect the first catalog model whose files are already on disk;
    // otherwise the recommended (smallest) entry.
    _selected = hfCatalog.firstWhere(
      _filesPresent,
      orElse: () => hfCatalog.firstWhere(
        (e) => e.recommended,
        orElse: () => hfCatalog.first,
      ),
    );
  }

  @override
  void dispose() {
    _libController.dispose();
    super.dispose();
  }

  bool _filesPresent(HfModelEntry entry) {
    for (final name in [
      for (final f in entry.modelFiles) f.name,
      if (entry.mmprojFile != null) entry.mmprojFile!.name,
    ]) {
      if (!File('${_downloader.destDirectory}\\$name').existsSync()) {
        return false;
      }
    }
    return true;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _browse({
    required String title,
    required List<String> extensions,
  }) async {
    final group = XTypeGroup(label: title, extensions: extensions);
    final file = await openFile(acceptedTypeGroups: [group]);
    return file?.path;
  }

  @override
  Widget build(BuildContext context) {
    final dll = _libController.text.trim();
    final libOk = dll.isNotEmpty && File(dll).existsSync();

    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenMoe — chat multimodal'),
        actions: [
          IconButton(
            tooltip: 'CPU, RAM y GPU de este equipo',
            icon: const Icon(Icons.monitor_heart),
            onPressed: () => showSystemPanelSheet(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _libraryCard(libOk),
          const SizedBox(height: 12),
          _modelsCard(),
          const SizedBox(height: 12),
          _localCard(),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _downloading || _booting ? null : _openChat,
            icon: _booting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chat_bubble_outline),
            label: Text(_booting ? 'Cargando el modelo…' : 'Empezar a chatear'),
          ),
        ],
      ),
    );
  }

  Widget _libraryCard(bool libOk) {
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  libOk ? Icons.check_circle : Icons.error_outline,
                  size: 20,
                  color: libOk ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Librería llama.cpp '
                    '(llama.dll + ggml*.dll + mtmd.dll en la misma carpeta)',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'La app registra automáticamente la carpeta de la DLL en el '
              'search path de Windows (SetDllDirectory). El zip de releases '
              '"llama-b*-bin-win-cpu-x64.zip" descomprimido funciona tal cual.',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _libController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    final path = await _browse(
                      title: 'llama.dll',
                      extensions: const ['dll'],
                    );
                    if (path != null) {
                      _libController.text = path;
                      setState(() {});
                    }
                  },
                  child: const Text('Explorar…'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelsCard() {
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Modelos de HuggingFace',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text('Carpeta de descarga: ${_downloader.destDirectory}'),
            const SizedBox(height: 8),
            RadioGroup<HfModelEntry>(
              groupValue: _selected,
              onChanged: (value) => setState(() => _selected = value),
              child: Column(
                children: [
                  for (final entry in hfCatalog)
                    RadioListTile<HfModelEntry>(
                      contentPadding: EdgeInsets.zero,
                      value: entry,
                      secondary: _downloading
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.download),
                              tooltip: 'Descargar / completar',
                              onPressed: () => _downloadEntry(entry),
                            ),
                      controlAffinity: ListTileControlAffinity.trailing,
                      title: Text(entry.label),
                      subtitle: Text(
                        _filesPresent(entry)
                            ? 'descargado y listo — Repo: ${entry.repo}'
                            : 'Aprox. ${humanSize(entry.approxBytes)} · Repo: ${entry.repo}',
                      ),
                    ),
                ],
              ),
            ),
            if (_downloading && _progress != null) ...[
              const Divider(height: 16),
              Text(
                'Descargando ${_progress!.file.name} '
                '(${_progress!.filesCompleted + 1}/${_progress!.filesTotal}): '
                '${humanSize(_progress!.receivedBytes)}'
                '${_progress!.totalBytes > 0 ? ' / ${humanSize(_progress!.totalBytes)}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: _progress!.totalBytes > 0 ? _progress!.fraction : null,
              ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: _downloader.cancel,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Cancelar'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _localCard() {
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'O usa GGUFs desde tu PC',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(width: 64, child: Text('Modelo:')),
                Expanded(
                  child: Text(
                    _localModelPath ?? '(ninguno)',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final path = await _browse(
                      title: 'GGUF',
                      extensions: const ['gguf'],
                    );
                    if (path != null) setState(() => _localModelPath = path);
                  },
                  child: const Text('Explorar…'),
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 64, child: Text('mmproj:')),
                Expanded(
                  child: Text(
                    _localMmprojPath ?? '(opcional, proyectador de imágenes)',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    final path = await _browse(
                      title: 'mmproj GGUF',
                      extensions: const ['gguf'],
                    );
                    if (path != null) setState(() => _localMmprojPath = path);
                  },
                  child: const Text('Explorar…'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadEntry(HfModelEntry entry) async {
    setState(() => _selected = entry);
    final filesText = StringBuffer();
    for (final f in entry.modelFiles) {
      filesText.writeln('• ${f.name}');
    }
    if (entry.mmprojFile != null) {
      filesText.writeln('• ${entry.mmprojFile!.name}\n');
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('¿Descargar este modelo?'),
        content: Text(
          'Se descargará desde HuggingFace:\n\n'
          '${entry.repo}\n'
          '$filesText\n'
          'Tamaño aproximado: ${humanSize(entry.approxBytes)}\n'
          'Destino: ${_downloader.destDirectory}\n\n'
          'La descarga admite pausa/reanudación (continúa desde donde quedó '
          'si cancelas o se corta la conexión).',
          softWrap: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Descargar'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    _downloader.resetCancelled();
    setState(() => _downloading = true);
    try {
      await _downloader.downloadEntry(
        entry,
        onProgress: (progress) => setState(() => _progress = progress),
      );
      _toast('Modelo descargado.');
    } on HfDownloadCanceled {
      _toast('Descarga cancelada (puedes reanudar después).');
    } catch (e) {
      _toast('Error de descarga: $e');
    } finally {
      if (mounted) {
        setState(() {
          _downloading = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _openChat() async {
    String modelPath;
    String? mmprojPath;
    String title;

    if ((_localModelPath ?? '').isNotEmpty) {
      modelPath = _localModelPath!;
      if (!File(modelPath).existsSync()) {
        _toast('El GGUF local no existe: $modelPath');
        return;
      }
      mmprojPath =
          (_localMmprojPath != null && File(_localMmprojPath!).existsSync())
          ? _localMmprojPath
          : null;
      title = 'GGUF local';
    } else {
      final entry = _selected;
      if (entry == null) {
        _toast('Selecciona o descarga un modelo primero.');
        return;
      }
      if (!_filesPresent(entry)) {
        await _downloadEntry(entry);
        if (!mounted || !_filesPresent(entry)) return;
      }
      modelPath =
          '${_downloader.destDirectory}\\${entry.modelFiles.first.name}';
      mmprojPath = entry.mmprojFile == null
          ? null
          : '${_downloader.destDirectory}\\${entry.mmprojFile!.name}';
      title = entry.label;
    }

    final dll = _libController.text.trim();
    if (dll.isEmpty || !File(dll).existsSync()) {
      _toast('La ruta de llama.dll no es válida: "$dll"');
      return;
    }

    setState(() => _booting = true);
    try {
      final engine = await LlamaEngine.spawn(
        libraryPath: dll,
        modelParams: ModelParams(
          path: modelPath,
          gpuLayers: 0, // el release cpu-x64 corre 100% en CPU
        ),
        contextParams: const ContextParams(
          nCtx: 4096,
          nBatch: 512,
          nUbatch: 512,
        ),
        multimodalParams: mmprojPath != null
            ? MultimodalParams(mmprojPath: mmprojPath)
            : null,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatPage(engine: engine, title: title),
        ),
      );
    } catch (e) {
      setState(() => _booting = false);
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('No se pudo iniciar el modelo'),
            content: SingleChildScrollView(child: Text('$e')),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cerrar'),
              ),
            ],
          ),
        );
      }
    }
  }
}
