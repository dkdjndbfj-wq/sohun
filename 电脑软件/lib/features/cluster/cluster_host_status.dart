import 'package:flutter/material.dart';

import '../../core/services/mifu_client.dart';
import '../../ui/aurora_design.dart';

/// Displays the supplied node snapshot. Presentation captures inject their
/// own health data; this widget never substitutes missing operational values.
class ClusterHostStatus extends StatelessWidget {
  const ClusterHostStatus({
    super.key,
    required this.health,
    required this.onOpenDetails,
  });

  final MifuHealth health;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final load = _validNumber(health.utilizationPercent, maximum: 100);
    final temperature = _validNumber(health.temperatureC);
    final name = health.gpuName?.trim();
    final statusColor = health.ready
        ? scheme.primary
        : health.trainingState == 'error'
        ? scheme.error
        : scheme.onSurfaceVariant;
    return FrostPanel(
      key: const ValueKey('cluster-host-status'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Wrap(
        spacing: 18,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: .07),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  Icons.memory_outlined,
                  size: 19,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: _Metric(
                  '计算节点',
                  name == null || name.isEmpty ? 'GPU 未识别' : name,
                ),
              ),
            ],
          ),
          _Metric('GPU 负载', load == null ? '—' : '${load.round()}%'),
          _Metric('显存', _gpuMemory(health) ?? '—'),
          _Metric('温度', temperature == null ? '—' : '${temperature.round()}°C'),
          Tooltip(
            message: '查看模型与训练节点',
            child: TextButton(
              key: const ValueKey('cluster-host-model-status'),
              onPressed: onOpenDetails,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                minimumSize: const Size(0, 34),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: statusColor,
                    ),
                  ),
                  const SizedBox(width: 7),
                  _Metric('Mifu', health.label),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 15,
                    color: statusColor,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static double? _validNumber(double? value, {double? maximum}) =>
      value != null &&
          value.isFinite &&
          value >= 0 &&
          (maximum == null || value <= maximum)
      ? value
      : null;

  static String? _gpuMemory(MifuHealth health) {
    final used = _validNumber(health.memoryUsedMb);
    final total = _validNumber(health.memoryTotalMb);
    if (used == null || total == null || total <= 0 || used > total) {
      return null;
    }
    return '${(used / 1024).toStringAsFixed(1)} / ${(total / 1024).toStringAsFixed(1)} GB';
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    ],
  );
}
