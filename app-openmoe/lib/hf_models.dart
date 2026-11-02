/// Model catalog for OpenMoe, sourced from HuggingFace.
///
/// Every entry is vision-capable (GGUF + mmproj pair) so the image-testing
/// flow works out of the box.
library;

final class HfModelEntry {
  final String id;
  final String label;
  final String repo;

  /// Sharded model files, downloaded in order into the models directory.
  final List<HfFile> modelFiles;

  final HfFile? mmprojFile;

  /// Rough total size of model + mmproj, used for the confirmation dialog.
  final int approxBytes;

  final bool recommended;

  const HfModelEntry({
    required this.id,
    required this.label,
    required this.repo,
    required this.modelFiles,
    required this.mmprojFile,
    required this.approxBytes,
    this.recommended = false,
  });
}

final class HfFile {
  final String name;

  /// Exact byte size when known from the HF repo listing, null = unknown.
  final int? sizeBytes;

  const HfFile(this.name, {this.sizeBytes});
}

const _gb = 1024 * 1024 * 1024;
const _mb = 1024 * 1024;

const hfCatalog = <HfModelEntry>[
  // Qwen 0.8B, OFFICIAL conversion from ggml-org (the GGUF of
  // Qwen/Qwen3.5-0.8B). Its convert.log shows text tensors only — the GGUF
  // has no vision encoder and no official mmproj exists for this arch yet,
  // so these entries are text-only.
  HfModelEntry(
    id: 'qwen35-08b-official-q4',
    label: 'Qwen 0.8B (Q4_0 oficial, ~0.5 GB, texto)',
    repo: 'ggml-org/Qwen3.5-0.8B-GGUF',
    modelFiles: [HfFile('Qwen3.5-0.8B-Q4_0.gguf', sizeBytes: 563036064)],
    mmprojFile: null,
    approxBytes: 563036064,
    recommended: true,
  ),
  HfModelEntry(
    id: 'qwen35-08b-official-q8',
    label: 'Qwen 0.8B (Q8_0 oficial, ~0.8 GB, texto)',
    repo: 'ggml-org/Qwen3.5-0.8B-GGUF',
    modelFiles: [HfFile('Qwen3.5-0.8B-Q8_0.gguf', sizeBytes: 833592096)],
    mmprojFile: null,
    approxBytes: 833592096,
  ),
  // Same Qwen 0.8B base, unsloth build WITH an mmproj projector — the only
  // way to run vision at this size today. Model + mmproj come from the same
  // repo so the pair is guaranteed to match.
  HfModelEntry(
    id: 'qwen35-08b-vision',
    label: 'Qwen 0.8B (Q4_K_M + mmproj, ~0.7 GB, visión)',
    repo: 'unsloth/Qwen3.5-0.8B-GGUF',
    modelFiles: [HfFile('Qwen3.5-0.8B-Q4_K_M.gguf', sizeBytes: 532517120)],
    mmprojFile: HfFile('mmproj-F16.gguf', sizeBytes: 204987232),
    approxBytes: 532517120 + 204987232,
  ),
  // The big multimodal flagship. Two shards plus the mmproj projector.
  // Only pick this when the machine has ~80 GB of free RAM + disk.
  HfModelEntry(
    id: 'qwen38-flash-q2k',
    label: 'Qwen3.8-Flash-Next (Q2_K, ~77 GB)',
    repo: 'ggml-org/Qwen3.8-Flash-Next-GGUF',
    modelFiles: [
      HfFile(
        'Qwen3.8-Flash-Next-Q2_K-00001-of-00002.gguf',
        sizeBytes: 10945760,
      ),
      HfFile(
        'Qwen3.8-Flash-Next-Q2_K-00002-of-00002.gguf',
        sizeBytes: 83117832704,
      ),
    ],
    mmprojFile: HfFile(
      'mmproj-Qwen3.8-Flash-Next-Q8_0.gguf',
      sizeBytes: 616703104,
    ),
    approxBytes: 78 * _gb,
  ),
  HfModelEntry(
    id: 'qwen38-flash-iq4nl',
    label: 'Qwen3.8-Flash-Next (IQ4_NL, ~95 GB)',
    repo: 'ggml-org/Qwen3.8-Flash-Next-GGUF',
    modelFiles: [
      HfFile(
        'Qwen3.8-Flash-Next-IQ4_NL-00001-of-00002.gguf',
        sizeBytes: 10945504,
      ),
      HfFile(
        'Qwen3.8-Flash-Next-IQ4_NL-00002-of-00002.gguf',
        sizeBytes: 102037973504,
      ),
    ],
    mmprojFile: HfFile(
      'mmproj-Qwen3.8-Flash-Next-Q8_0.gguf',
      sizeBytes: 616703104,
    ),
    approxBytes: 95 * _gb,
  ),
];

String humanSize(int bytes) {
  if (bytes >= _gb) return '${(bytes / _gb).toStringAsFixed(1)} GB';
  if (bytes >= _mb) return '${(bytes / _mb).toStringAsFixed(0)} MB';
  return '$bytes B';
}
