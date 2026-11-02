/// HuggingFace downloader with per-file progress, resume support, and
/// cancellation.
///
/// Downloads `https://huggingface.co/<repo>/resolve/main/<file>` into the
/// models directory. A `.part` sidecar keeps partial data and allows a
/// `Range:` resume on the next attempt.
library;

import 'dart:io';

import 'hf_models.dart';

final class HfDownloadProgress {
  final HfFile file;
  final int filesCompleted;
  final int filesTotal;
  final int receivedBytes;
  final int totalBytes;

  const HfDownloadProgress({
    required this.file,
    required this.filesCompleted,
    required this.filesTotal,
    required this.receivedBytes,
    required this.totalBytes,
  });

  double get fraction {
    if (totalBytes <= 0) return 0;
    final value = receivedBytes / totalBytes;
    if (value <= 0) return 0;
    if (value >= 1) return 1;
    return value;
  }
}

final class HfDownloadCanceled implements Exception {
  const HfDownloadCanceled();
}

final class HfDownloader {
  /// Target folder for downloads. Mutable: the setup page lets the user
  /// pick a destination before confirming a download.
  String destDirectory;
  final HttpClient _client;
  final List<bool> _canceled = <bool>[false];

  HfDownloader({String? destDirectory})
    : destDirectory = destDirectory ?? _defaultModelsDir(),
      _client = HttpClient() {
    _client.userAgent = 'OpenMoe/0.1 (llama_cpp_dart example)';
    _client.autoUncompress = false;
    _client.connectionTimeout = const Duration(minutes: 2);
  }

  static String _defaultModelsDir() {
    final userHome =
        Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    return '$userHome\\OpenMoe\\models';
  }

  Directory get destDir => Directory(destDirectory);

  /// True when every file in [fileNames] is present on disk.
  Future<bool> hasFiles(List<String> fileNames) async {
    for (final name in fileNames) {
      if (!File('$destDirectory\\$name').existsSync()) return false;
    }
    return true;
  }

  /// Total on-disk bytes already present for [fileNames].
  int bytesOnDisk(List<String> fileNames) {
    var sum = 0;
    for (final name in fileNames) {
      final f = File('$destDirectory\\$name');
      if (f.existsSync()) sum += f.lengthSync();
    }
    return sum;
  }

  void cancel() => _canceled[0] = true;

  /// Clear the cancel flag before starting a fresh download.
  void resetCancelled() => _canceled[0] = false;

  bool get cancelled => _canceled[0];

  /// Download every file of [entry] (model shards, then mmproj).
  ///
  /// Returns the resolved paths as `(modelPath, mmprojPath?)`.
  /// Throws [HfDownloadCanceled] when [cancel] was called.
  Future<(String, String?)> downloadEntry(
    HfModelEntry entry, {
    required void Function(HfDownloadProgress) onProgress,
  }) async {
    final files = <HfFile>[...entry.modelFiles, ?entry.mmprojFile];
    final dir = destDir;
    if (!dir.existsSync()) dir.createSync(recursive: true);

    String? modelPath;
    String? mmprojPath;

    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final path = await _downloadOne(
        repo: entry.repo,
        file: file,
        withProgress: (received, total) => onProgress(
          HfDownloadProgress(
            file: file,
            filesCompleted: i,
            filesTotal: files.length,
            receivedBytes: received,
            totalBytes: total,
          ),
        ),
      );
      if (!file.name.startsWith('mmproj')) modelPath ??= path;
      if (file.name.startsWith('mmproj')) mmprojPath = path;
    }

    final model =
        modelPath ?? (throw StateError('no se recibió ningún modelo'));
    return (model, mmprojPath);
  }

  Future<String> _downloadOne({
    required String repo,
    required HfFile file,
    required void Function(int received, int total) withProgress,
  }) async {
    final fileName = file.name;
    final target = File('$destDirectory\\$fileName');
    final part = File('${target.path}.part');

    // A complete local copy (size known from the catalog) needs no network.
    if (target.existsSync() && file.sizeBytes != null) {
      if (target.lengthSync() == file.sizeBytes) return target.path;
    }

    var resumeFrom = 0;
    if (part.existsSync()) resumeFrom = part.lengthSync();

    final request = await _client.getUrl(
      Uri.parse('https://huggingface.co/$repo/resolve/main/$fileName'),
    );
    if (resumeFrom > 0) {
      request.headers.set('range', 'bytes=$resumeFrom-');
    }
    final response = await request.close();
    final status = response.statusCode;
    if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
      throw HttpException('HTTP $status descargando $fileName');
    }
    if (status == HttpStatus.ok && resumeFrom > 0) {
      // The server ignored our Range header — restart from scratch.
      resumeFrom = 0;
    }

    // HF sends no content-length on redirects to some CDNs; when missing we
    // fall back to the catalog size (shards) for the total.
    final total = (response.contentLength > 0 && resumeFrom == 0)
        ? response.contentLength
        : (response.contentLength > 0 && resumeFrom > 0
              ? response.contentLength + resumeFrom
              : file.sizeBytes);

    var received = resumeFrom;
    final sink = part.openWrite(
      mode: status == HttpStatus.partialContent
          ? FileMode.append
          : FileMode.write,
    );
    try {
      await for (final chunk in response) {
        if (_canceled[0]) {
          await sink.flush();
          await sink.close();
          // Keep the .part file so the next attempt resumes where we got to.
          throw const HfDownloadCanceled();
        }
        sink.add(chunk);
        received += chunk.length;
        withProgress(received, total ?? 0);
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      rethrow;
    }

    if (total != null && received != total) {
      throw HttpException(
        'descarga incompleta de $fileName: $received/$total bytes',
      );
    }
    if (target.existsSync()) target.deleteSync();
    part.renameSync(target.path);
    return target.path;
  }
}
