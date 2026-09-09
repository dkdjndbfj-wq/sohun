import 'package:flutter/material.dart';

import '../../data/database/models/studio_models.dart';

/// Compact per-plate material summary. It deliberately renders nothing for a
/// single active tool, so ordinary one-color orders keep the simple layout.
class StudioPlateFilamentSummary extends StatelessWidget {
  const StudioPlateFilamentSummary({
    super.key,
    required this.filaments,
    required this.toolChangeCount,
    this.requiredRuns = 1,
    this.compact = false,
  });

  final List<StudioPlateFilamentUsage> filaments;
  final int toolChangeCount;
  final int requiredRuns;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final active = StudioPlateFilamentUsage.activeByTool(filaments);
    if (active.length < 2) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    final runs = requiredRuns < 1 ? 1 : requiredRuns;
    final mappingIncomplete = active.any((item) => item.trayId == null);
    return Container(
      key: const Key('studio-multicolor-summary'),
      margin: const EdgeInsets.only(top: 7),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.primaryContainer.withValues(alpha: 0.28),
        border: Border.all(color: colors.primary.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (compact) ...[
            Row(
              children: [
                Icon(Icons.palette_outlined, size: 15, color: colors.primary),
                const SizedBox(width: 5),
                Text(
                  '多色打印',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: colors.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${active.length} 个有效通道 · $toolChangeCount 次换料',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9,
                color: colors.onSurfaceVariant,
              ),
            ),
          ] else
            Row(
              children: [
                Icon(Icons.palette_outlined, size: 15, color: colors.primary),
                const SizedBox(width: 5),
                Text(
                  '多色打印',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: colors.primary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${active.length} 个有效通道 · $toolChangeCount 次换料',
                  style: TextStyle(
                    fontSize: 9,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final item in active)
                if (compact)
                  SizedBox(
                    width: double.infinity,
                    child: _FilamentUsageChip(
                      item: item,
                      requiredRuns: runs,
                      expanded: true,
                    ),
                  )
                else
                  _FilamentUsageChip(item: item, requiredRuns: runs),
            ],
          ),
          if (mappingIncomplete) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 13,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '切片已识别多色，打印前请确认 AMS/料槽映射。',
                    style: TextStyle(
                      fontSize: 9,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _FilamentUsageChip extends StatelessWidget {
  const _FilamentUsageChip({
    required this.item,
    required this.requiredRuns,
    this.expanded = false,
  });

  final StudioPlateFilamentUsage item;
  final int requiredRuns;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final total = item.grams * requiredRuns;
    final details = <String>[
      '通道 ${item.toolIndex + 1}',
      if (item.materialType?.trim().isNotEmpty == true)
        item.materialType!.trim(),
      '${item.grams.toStringAsFixed(2)} g/盘',
      if (requiredRuns > 1) '共 ${total.toStringAsFixed(2)} g',
      if (item.trayId != null) '料槽 ${item.trayId! + 1}',
      if (item.usedForObject == true && item.usedForSupport == true)
        '模型+支撑'
      else if (item.usedForSupport == true)
        '支撑料',
      if (item.sku?.trim().isNotEmpty == true) item.sku!.trim(),
    ];
    return Container(
      key: ValueKey('studio-filament-tool-${item.toolIndex}'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: _filamentColor(item.colorHex, colors.surfaceContainer),
              shape: BoxShape.circle,
              border: Border.all(color: colors.outline.withValues(alpha: 0.5)),
            ),
          ),
          const SizedBox(width: 5),
          if (expanded)
            Expanded(
              child: Text(
                details.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9),
              ),
            )
          else
            Text(details.join(' · '), style: const TextStyle(fontSize: 9)),
        ],
      ),
    );
  }
}

Color _filamentColor(String? value, Color fallback) {
  final raw = value?.trim().replaceFirst('#', '') ?? '';
  final normalized = raw.length == 6 ? 'FF$raw' : raw;
  final parsed = int.tryParse(normalized, radix: 16);
  return parsed == null ? fallback : Color(parsed);
}
