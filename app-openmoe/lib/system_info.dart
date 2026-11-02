/// System dashboard: CPU, RAM and GPU telemetry for the launcher screen.
///
/// Data comes from three sources:
///  * PowerShell CIM instances (Win32_Processor / Win32_OperatingSystem)
///    for CPU model, cores, load and RAM totals;
///  * `nvidia-smi` when present, falling back to a bare GPU name;
///  * llama.cpp itself (`llama_print_system_info`) once the library is
///    loaded, so CPU feature flags show what inference really uses.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

final class SystemSnapshot {
  final String cpuName;
  final int physicalCores;
  final int logicalCores;
  final double? cpuLoadPercent;
  final double ramTotalGb;
  final double ramFreeGb;
  final double processRssMb;
  final String gpuName;
  final double? gpuVramTotalMb;
  final double? gpuVramUsedMb;
  final String llamaSystemInfo;

  const SystemSnapshot({
    required this.cpuName,
    required this.physicalCores,
    required this.logicalCores,
    required this.cpuLoadPercent,
    required this.ramTotalGb,
    required this.ramFreeGb,
    required this.processRssMb,
    required this.gpuName,
    required this.gpuVramTotalMb,
    required this.gpuVramUsedMb,
    required this.llamaSystemInfo,
  });

  static const empty = SystemSnapshot(
    cpuName: '(sin datos)',
    physicalCores: 0,
    logicalCores: 0,
    cpuLoadPercent: null,
    ramTotalGb: 0,
    ramFreeGb: 0,
    processRssMb: 0,
    gpuName: '(sin GPU detectada)',
    gpuVramTotalMb: null,
    gpuVramUsedMb: null,
    llamaSystemInfo: '',
  );

  double get ramUsedGb {
    final used = ramTotalGb - ramFreeGb;
    if (used < 0) return 0;
    if (used > ramTotalGb) return ramTotalGb;
    return used;
  }
}

/// Polls the OS every [interval] while the panel is open.
final class SystemFeed {
  final Duration interval;
  Timer? _timer;
  final StreamController<SystemSnapshot> _controller =
      StreamController.broadcast();

  SystemFeed({this.interval = const Duration(seconds: 2)});

  Stream<SystemSnapshot> get stream => _controller.stream;

  void start() {
    _sample();
    _timer = Timer.periodic(interval, (_) => _sample());
  }

  void stop() => _timer?.cancel();

  void dispose() {
    stop();
    _controller.close();
  }

  Future<void> _sample() async {
    try {
      final snapshot = await collect();
      if (!_controller.isClosed) _controller.add(snapshot);
    } on ProcessException {
      // Keep the last values; the panel tolerates missing tools.
    }
  }
}

Future<SystemSnapshot> collect() async {
  final cpuRamLines = (await _queryCpuRam())?.split('|') ?? const <String>[];
  final gpuInfo = await _queryGpu();
  final llamaInfo = LlamaLibrary.isLoaded
      ? LlamaLibrary.systemInfo().trim()
      : '';

  String pick(int index, String fallback) =>
      index < cpuRamLines.length ? cpuRamLines[index] : fallback;

  return SystemSnapshot(
    cpuName: pick(0, '(sin datos)'),
    physicalCores: int.tryParse(pick(1, '0')) ?? 0,
    logicalCores: int.tryParse(pick(2, '0')) ?? 0,
    cpuLoadPercent: double.tryParse(pick(3, '')),
    ramTotalGb: _numOrZero(pick(4, '0')),
    ramFreeGb: _numOrZero(pick(5, '0')),
    processRssMb: _numOrZero(pick(6, '0')),
    gpuName: (gpuInfo['name'] as String?) ?? '(sin GPU detectada)',
    gpuVramTotalMb: gpuInfo['totalMb'] as double?,
    gpuVramUsedMb: gpuInfo['usedMb'] as double?,
    llamaSystemInfo: llamaInfo,
  );
}

double _numOrZero(String raw) => double.tryParse(raw) ?? 0;

/// Output is pipe-separated:
/// name|physicalCores|logicalCores|load%|ramTotalGb|ramFreeGb|rssMb
Future<String?> _queryCpuRam() async {
  final script = _cpuRamScript(pid);
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
  ]);
  final out = (result.stdout as String?)?.trim() ?? '';
  if (out.isEmpty) {
    throw StateError(result.stderr as String? ?? 'PowerShell sin salida');
  }
  // The CPU name could theoretically include pipes; the formatted result is
  // the only non-empty line, so always pick the first non-empty line.
  for (final line in out.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

String _cpuRamScript(int dartPid) {
  return r'''
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$os = Get-CimInstance Win32_OperatingSystem
$proc = Get-Process -Id @DARTPID@
Write-Output ('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f @(
  $cpu.Name.Trim(),
  $cpu.NumberOfCores,
  $cpu.NumberOfLogicalProcessors,
  $cpu.LoadPercentage,
  [math]::Round($os.TotalVisibleMemorySize / 1MB, 1),
  [math]::Round($os.FreePhysicalMemory / 1MB, 1),
  [math]::Round($proc.WorkingSet64 / 1MB, 1)
))
'''
      .replaceFirst('@DARTPID@', '$dartPid');
}

/// nvidia-smi (precise VRAM for NVIDIA GPUs) else nothing but the name.
Future<Map<String, Object?>> _queryGpu() async {
  final smi = await Process.run('nvidia-smi', const [
    '--query-gpu=name,memory.total,memory.used',
    '--format=csv,noheader,nounits',
  ]);
  if (smi.exitCode == 0) {
    final line = (smi.stdout as String?)
        ?.split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (line != null && line.isNotEmpty) {
      final parts = line.split(',');
      if (parts.length >= 3) {
        return <String, Object?>{
          'name': parts[0].trim(),
          'totalMb': double.tryParse(parts[1].trim()),
          'usedMb': double.tryParse(parts[2].trim()),
        };
      }
    }
  }
  // No NVIDIA tooling: at least name the adapter(s).
  final vc = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '(Get-CimInstance Win32_VideoController).Name -join \', \'',
  ]).catchError((_) => ProcessResult(0, 1, '', ''));
  final name = (vc.stdout as String?)?.trim();
  return <String, Object?>{
    'name': (name?.isEmpty ?? true) ? null : name,
    'totalMb': null,
    'usedMb': null,
  };
}

/// The visual panel, driven by a [SystemFeed].
final class SystemPanel extends StatefulWidget {
  const SystemPanel({super.key});

  @override
  State<SystemPanel> createState() => _SystemPanelState();
}

class _SystemPanelState extends State<SystemPanel> {
  final SystemFeed _feed = SystemFeed();
  SystemSnapshot _snapshot = SystemSnapshot.empty;

  @override
  void initState() {
    super.initState();
    _feed.stream.listen((snapshot) {
      if (mounted) setState(() => _snapshot = snapshot);
    });
    _feed.start();
  }

  @override
  void dispose() {
    _feed.dispose();
    super.dispose();
  }

  double _fraction(double used, double total) {
    if (total <= 0) return 0;
    final value = used / total;
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }

  Widget _meterRow(
    String label,
    String detail,
    double? fraction, {
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        SizedBox(width: 52, child: Text(label)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail, style: theme.textTheme.bodySmall),
              const SizedBox(height: 4),
              LinearProgressIndicator(value: fraction),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _snapshot;
    final vramText = s.gpuVramTotalMb == null
        ? null
        : '${_fmtMiB(s.gpuVramUsedMb ?? 0)} / ${_fmtMiB(s.gpuVramTotalMb!)}';
    final loadText = s.cpuLoadPercent == null
        ? ''
        : ' · ${s.cpuLoadPercent!.toStringAsFixed(0)}%';

    return SizedBox(
      width: 480,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.monitor_heart),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sistema',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(
                  'actualiza cada 2 s',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _meterRow(
              'CPU',
              '${s.cpuName}'
                  ' · ${s.physicalCores} núcleos / ${s.logicalCores} hilos'
                  '$loadText',
              s.cpuLoadPercent == null ? null : s.cpuLoadPercent! / 100,
              icon: Icons.memory,
            ),
            const SizedBox(height: 10),
            _meterRow(
              'RAM',
              '${s.ramUsedGb.toStringAsFixed(1)} / '
                  '${s.ramTotalGb.toStringAsFixed(1)} GB'
                  '  ·  proceso: ${s.processRssMb.toStringAsFixed(0)} MB',
              _fraction(s.ramUsedGb, s.ramTotalGb),
              icon: Icons.sd_storage_outlined,
            ),
            const SizedBox(height: 10),
            _meterRow(
              'GPU',
              '${s.gpuName}'
                  '${vramText == null ? '' : '  ·  VRAM $vramText'}',
              s.gpuVramTotalMb == null
                  ? null
                  : _fraction(s.gpuVramUsedMb ?? 0, s.gpuVramTotalMb!),
              icon: Icons.developer_board,
            ),
            if (s.llamaSystemInfo.isNotEmpty) ...[
              const Divider(height: 20),
              SelectableText(
                'llama.cpp: ${s.llamaSystemInfo}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtMiB(double mib) {
    if (mib >= 1024) return '${(mib / 1024).toStringAsFixed(1)} GB';
    return '${mib.toStringAsFixed(0)} MB';
  }
}

/// Opens the system dashboard as a modal bottom sheet.
void showSystemPanelSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (_) => const SystemPanel(),
  );
}
