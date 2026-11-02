import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_paths.dart';
import 'hf_download.dart';
import 'hf_models.dart';

/// The "Modelos" page: HuggingFace catalog + arbitrary-repo download by
/// link + GGUF from a local folder, then straight into a chat.
class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  late final HfDownloader _downloader;
  HfModelEntry? _selected;
  HfDownloadProgress? _progress;
  bool _downloading = false;

  String? _localModelPath;
  String? _localMmprojPath;

  /// Download-progress for the "by link" flow.
  HfDownloadProgress? _urlProgress;
  bool _downloadingUrl = false;

  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _downloader = HfDownloader();
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
    _urlController.dispose();
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
    return Scaffold(
      appBar: AppBar(title: const Text('Modelos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _catalogCard(),
          const SizedBox(height: 12),
          _urlCard(),
          const SizedBox(height: 12),
          _localCard(),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _localModelPath == null
                ? null
                : () {
                    unawaited(
                      launchChat(
                        context,
                        modelPath: _localModelPath!,
                        mmprojPath: _localMmprojPath,
                        title: File(_localModelPath!).uri.pathSegments.last,
                        saveKey: AppPaths.keyForModel(_localModelPath!),
                      ),
                    );
                  },
            icon: const Icon(Icons.chat_bubble_outline),
            label: const Text('Chatear con el GGUF local seleccionado'),
          ),
        ],
      ),
    );
  }

  Widget _catalogCard() {
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Catálogo de HuggingFace',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Carpeta: ${_downloader.destDirectory} (cámbiala en Ajustes)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
                              onPressed: () => unawaited(_downloadEntry(entry)),
                            ),
                      controlAffinity: ListTileControlAffinity.trailing,
                      title: Text(entry.label),
                      subtitle: Text(
                        _filesPresent(entry)
                            ? 'descargado y listo — repo: ${entry.repo}'
                            : 'aprox. ${humanSize(entry.approxBytes)} · '
                                  'repo: ${entry.repo}',
                      ),
                    ),
                ],
              ),
            ),
            _cardProgress(_downloading, _progress),
          ],
        ),
      ),
    );
  }

  Widget _cardProgress(bool active, HfDownloadProgress? progress) {
    if (!active || progress == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 16),
        Text(
          'Descargando ${progress.file.name}: '
          '${humanSize(progress.receivedBytes)}'
          '${progress.totalBytes > 0 ? ' / ${humanSize(progress.totalBytes)}' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: progress.totalBytes > 0 ? progress.fraction : null,
        ),
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: _downloader.cancel,
          icon: const Icon(Icons.close, size: 16),
          label: const Text('Cancelar'),
        ),
      ],
    );
  }

  /// Card: paste any HuggingFace GGUF link and download it.
  Widget _urlCard() {
    final parsed = HfDownloader.parseHfUrl(_urlController.text);
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Descargar por link de HuggingFace',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              onChanged: (value) => setState(() {}),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'URL del GGUF',
                hintText:
                    'https://huggingface.co/<repo>/resolve/main/<arch>.gguf',
              ),
              enabled: !_downloadingUrl,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (_downloading || !parsed.isOk)
                        ? null
                        : () => unawaited(_downloadUrl()),
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('Descargar este GGUF'),
                  ),
                ),
              ],
            ),
            if (parsed.isOk)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Repositorio: ${parsed.repo} · archivo: ${parsed.fileName}',
                ),
              ),
            if (!parsed.isOk && _urlController.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Link no reconocido: debe terminar en .gguf y apuntar a '
                  'un repo de huggingface.co /blob/ o /resolve/.',
                ),
              ),
            _cardProgress(_downloadingUrl, _urlProgress),
          ],
        ),
      ),
    );
  }

  /// Card: open a GGUF straight from disk, plus an optional mmproj.
  Widget _localCard() {
    return Card.filled(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cargar GGUF desde tu PC',
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
      filesText.writeln('· ${f.name}');
    }
    if (entry.mmprojFile != null) {
      filesText.writeln('· ${entry.mmprojFile!.name}');
    }
    var dest = _downloader.destDirectory;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('¿Descargar este modelo?'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Se descargará desde HuggingFace:\n\n'
                  '${entry.repo}\n'
                  '$filesText\n'
                  'Tamaño aproximado: ${humanSize(entry.approxBytes)}',
                  softWrap: true,
                ),
                const SizedBox(height: 12),
                const Text('Carpeta de destino:'),
                Text(
                  dest,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final picked = await getDirectoryPath(
                      initialDirectory: Directory(dest).existsSync()
                          ? dest
                          : null,
                    );
                    if (picked != null && picked.isNotEmpty) {
                      setDialogState(() => dest = picked);
                    }
                  },
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Elegir otra carpeta…'),
                ),
                const Text(
                  'La descarga admite pausa/reanudación (continúa desde '
                  'donde quedó si cancelas o se corta la conexión).',
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Descargar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    _downloader.destDirectory = dest;

    setState(() {
      _downloading = true;
      _progress = null;
    });
    _downloader.resetCancelled();
    try {
      await _downloader.downloadEntry(
        entry,
        onProgress: (p) => setState(() => _progress = p),
      );
      _toast('Descarga completa: ${entry.modelFiles.first.name}');
    } on HfDownloadCanceled {
      _toast('Descarga cancelada (podrás reanudar desde donde quedó)');
    } catch (e) {
      _toast('Error en la descarga: $e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// Download arbitrary-repo flow run by [_urlCard].
  Future<void> _downloadUrl() async {
    final parsed = HfDownloader.parseHfUrl(_urlController.text);
    if (!parsed.isOk) return;

    var dest = _downloader.destDirectory;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('¿Descargar por link?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('repo: ${parsed.repo}\narchivo: ${parsed.fileName}'),
                const Text('(el tamaño se sabrá al iniciar la descarga)'),
                const SizedBox(height: 12),
                const Text('Carpeta de destino:'),
                Text(
                  dest,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final picked = await getDirectoryPath(
                      initialDirectory: Directory(dest).existsSync()
                          ? dest
                          : null,
                    );
                    if (picked != null && picked.isNotEmpty) {
                      setDialogState(() => dest = picked);
                    }
                  },
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Elegir otra carpeta…'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Descargar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    _downloader.destDirectory = dest;

    setState(() {
      _downloadingUrl = true;
      _urlProgress = null;
    });
    _downloader.resetCancelled();
    try {
      await _downloader.downloadUrl(
        _urlController.text.trim(),
        onProgress: (p) => setState(() => _urlProgress = p),
      );
      _toast('Descarga completa: ${parsed.fileName}');
    } on HfDownloadCanceled {
      _toast('Descarga cancelada (podrás reanudar desde donde quedó)');
    } catch (e) {
      _toast('Error en la descarga: $e');
    } finally {
      if (mounted) setState(() => _downloadingUrl = false);
    }
  }
}
