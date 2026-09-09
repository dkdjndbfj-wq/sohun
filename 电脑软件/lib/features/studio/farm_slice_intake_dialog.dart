import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/external/slicer/production_package_inspector.dart';
import 'farm_ui/farm_theme.dart';

enum FarmSlicePromptAction { use, later, ignore }

Future<FarmSlicePromptAction?> showFarmSlicePrompt(
  BuildContext context,
  ProductionPackageInspection inspection,
) {
  return showDialog<FarmSlicePromptAction>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: FarmVisual.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.content_cut_rounded,
                      color: FarmVisual.primary,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '检测到新的拓竹切片',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    DateFormat('HH:mm').format(inspection.detectedAt),
                    style: TextStyle(
                      fontSize: 11,
                      color:
                          Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _ArtifactSummary(inspection: inspection),
              const SizedBox(height: 14),
              Text(
                '这会把切片包按“盘 → 成品项”建立订单，不会立即开始打印。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
              if (inspection.warning != null) ...[
                const SizedBox(height: 8),
                Text(
                  inspection.warning!,
                  style: const TextStyle(
                    color: FarmVisual.warning,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.pop(
                      dialogContext,
                      FarmSlicePromptAction.ignore,
                    ),
                    icon: const Icon(Icons.close_rounded, size: 17),
                    label: const Text('忽略这次'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(
                      dialogContext,
                      FarmSlicePromptAction.later,
                    ),
                    icon: const Icon(Icons.schedule_rounded, size: 17),
                    label: const Text('稍后处理'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(
                      dialogContext,
                      FarmSlicePromptAction.use,
                    ),
                    icon: const Icon(Icons.assignment_outlined, size: 17),
                    label: const Text('用于农场订单'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ArtifactSummary extends StatelessWidget {
  const _ArtifactSummary({required this.inspection});

  final ProductionPackageInspection inspection;

  @override
  Widget build(BuildContext context) {
    final preview = inspection.plates
        .map((plate) => plate.thumbnailBytes)
        .whereType<Uint8List>()
        .firstOrNull;
    final seconds = inspection.plates.fold<int>(
      0,
      (sum, plate) => sum + plate.estimatedSeconds,
    );
    final grams = inspection.plates.fold<double>(
      0,
      (sum, plate) => sum + plate.estimatedGrams,
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            height: 72,
            child: preview == null
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: FarmVisual.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.view_in_ar_outlined,
                      color: FarmVisual.primary,
                      size: 28,
                    ),
                  )
                : ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(preview, fit: BoxFit.cover),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  inspection.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  children: [
                    _Metric(
                      icon: Icons.layers_outlined,
                      label: '${inspection.plates.length} 盘',
                    ),
                    _Metric(
                      icon: Icons.view_module_outlined,
                      label:
                          '${inspection.plates.fold<int>(0, (sum, p) => sum + p.parts.length)} 个模型',
                    ),
                    _Metric(
                      icon: Icons.schedule_outlined,
                      label: _duration(seconds),
                    ),
                    _Metric(
                      icon: Icons.scale_outlined,
                      label: '${grams.toStringAsFixed(1)} g',
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  inspection.slicerVersion == null
                      ? (inspection.slicerName ?? 'Bambu Studio')
                      : '${inspection.slicerName ?? 'Bambu Studio'} ${inspection.slicerVersion}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: FarmVisual.primary),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      );
}

String _duration(int seconds) {
  if (seconds <= 0) return '时间待确认';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return hours == 0 ? '$minutes 分钟' : '$hours 小时 $minutes 分钟';
}
