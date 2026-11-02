/// HuggingFace downloader with per-file progress, resume support, and
/// cancellation.
///
/// Downloads `https://huggingface.co/<repo>/resolve/main/<file>` into the
/// models directory. A `.part` sidecar keeps partial data and allows a
/// `Range:` resume on the next attempt.
library;

import 'dart:io';

import 'app_paths.dart';
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

/// Result of parsing a pasted HuggingFace GGUF link.
final class HfUrlParse {
  final String repo;

  /// `.gguf` file name inside [repo].
  final String fileName;

  const HfUrlParse({required this.repo, required this.fileName});

  bool get isOk => repo.isNotEmpty && fileName.isNotEmpty;

  static const bad = HfUrlParse(repo: '', fileName: '');
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

  static String _defaultModelsDir() => AppPaths.resolveModelsDir;

  /// Parse `https://huggingface.co/<owner>/<repo>/blob|resolve/<branch>/<file>.gguf`
  /// (scheme optional, query like `?download=true` ignored). Returns a
  /// parse whose [HfUrlParse.isOk] is false when the link isn't recognized.
  static HfUrlParse parseHfUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return HfUrlParse.bad;
    text = text.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    text = text.replaceFirst(RegExp(r'^www\.', caseSensitive: false), '');
    // Drop query/fragment.
    final cut = RegExp('[?#]').firstMatch(text);
    if (cut != null) text = text.substring(0, cut.start);

    final hostPat = 'huggingface\\.co/';
    if (!text.startsWith(hostPat)) return HfUrlParse.bad;
    final rest = text.substring(hostPat.length);

    // <owner>/<repo>/<blob|resolve>/<branch>/<name>.gguf
    final match = RegExp(
      r'^([^/]+)/([^/]+)/(?:blob|resolve)/[^/]+/(.+\.gguf)$',
      caseSensitive: false,
    ).firstMatch(rest);
    if (match == null) return HfUrlParse.bad;
    final file = match.group(3)!;
    if (!file.toLowerCase().endsWith('.gguf')) return HfUrlParse.bad;
    return HfUrlParse(
      repo: '${match.group(1)}/${match.group(2)}',
      fileName: file,
    );
  }

  /// Download the GGUF a pasted [rawUrl] points at, into [destDirectory].
  /// Size is unknown until the server answers, so the progress bar uses
  /// content-length when available.
  Future<String> downloadUrl(
    String rawUrl, {
    required void Function(HfDownloadProgress) onProgress,
  }) async {
    final parsed = parseHfUrl(rawUrl);
    if (!parsed.isOk) {
      throw const FormatException('Link de HuggingFace no válido');
    }
    final file = HfFile(parsed.fileName);
    final dir = destDir;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _downloadOne(
      repo: parsed.repo,
      file: file,
      withProgress: (received, total) => onProgress(
        HfDownloadProgress(
          file: file,
          filesCompleted: 0,
          filesTotal: 1,
          receivedBytes: received,
          totalBytes: total,
        ),
      ),
    );
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
