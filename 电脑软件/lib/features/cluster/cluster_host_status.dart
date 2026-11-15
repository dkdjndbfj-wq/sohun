import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/mifu_client.dart';
import '../../providers/local_host_monitor_provider.dart';
import '../../ui/aurora_design.dart';

/// Host resources are local OS readings; GPU readings come from Mifu /health.
/// An unavailable model does not make local CPU or memory disappear.
class ClusterHostStatus extends ConsumerWidget {
  const ClusterHostStatus({
    super.key,
    required this.health,
    required this.onOpenDetails,
  });

  final MifuHealth health;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(localHostSnapshotProvider);
    final sample = state.valueOrNull;
    final scheme = Theme.of(context).colorScheme;
    final gpuLoad = _percent(health.utilizationPercent);
    final gpuMemory = _gpuMemory(health);
    final temperature = health.temperatureC;
    final hasTemperature =
        temperature != null && temperature.isFinite && temperature >= 0;
    final hasGpu = gpuLoad != null || gpuMemory != null || hasTemperature;
    final modelLabel = switch (health.trainingState) {
      'ready' => 'Mifu 就绪',
      'loading' => 'Mifu 加载中',
      'unconfigured' => 'Mifu 待配置',
      'error' => 'Mifu 加载失败',
      _ => 'Mifu 未连接',
    };
    return FrostPanel(
      key: const ValueKey('cluster-host-status'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 14,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Tooltip(
            message: '当前电脑的系统资源，每3秒更新',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.computer_outlined,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                const Text('本机', style: TextStyle(fontSize: 11)),
              ],
            ),
          ),
          if (sample?.hasMetrics == true) ...[
            if (sample!.cpuPercent != null)
              _Metric('CPU', '${sample.cpuPercent!.round()}%')
            else if (sample.cpuSampling)
              const _Metric('CPU', '采样中'),
            if (sample.hasMemory)
              _Metric(
                '内存',
                '${_gigabytes(sample.memoryUsedBytes!)} / ${_gigabytes(sample.memoryTotalBytes!)} GB',
              ),
          ] else
            Text(
              state.isLoading
                  ? '正在读取资源'
                  : sample?.unavailableReason ?? '本机资源暂不可用',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          if (hasGpu)
            Tooltip(
              message: '${health.gpuName ?? 'GPU'} · 本机 Mifu 服务采样',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (gpuLoad != null) _Metric('GPU', gpuLoad),
                  if (gpuMemory != null) ...[
                    if (gpuLoad != null) const SizedBox(width: 14),
                    _Metric('显存', gpuMemory),
                  ],
                  if (hasTemperature) ...[
                    if (gpuLoad != null || gpuMemory != null)
                      const SizedBox(width: 14),
                    _Metric('温度', '${temperature.round()}°C'),
                  ],
                ],
              ),
            ),
          Tooltip(
            message: health.trainingState == 'disconnected'
                ? '本机 Mifu 服务尚未连接，点击查看连接信息'
                : hasGpu
                ? '查看模型与计算节点'
                : '查看模型信息；当前服务未提供 GPU 监测数据',
            child: TextButton(
              key: const ValueKey('cluster-host-model-status'),
              onPressed: onOpenDetails,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                minimumSize: const Size(0, 32),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: health.ready
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(modelLabel, style: const TextStyle(fontSize: 11)),
                  const SizedBox(width: 3),
                  const Icon(Icons.chevron_right_rounded, size: 15),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _gigabytes(int bytes) =>
      (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

  static String? _percent(double? value) =>
      value != null && value.isFinite && value >= 0 && value <= 100
      ? '${value.round()}%'
      : null;

  static String? _gpuMemory(MifuHealth health) {
    final used = health.memoryUsedMb;
    final total = health.memoryTotalMb;
    if (used == null ||
        total == null ||
        !used.isFinite ||
        !total.isFinite ||
        used < 0 ||
        total <= 0 ||
        used > total)
      return null;
    return '${(used / 1024).toStringAsFixed(1)} / ${(total / 1024).toStringAsFixed(1)} GB';
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(width: 5),
      Text(
        value,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
    ],
  );
}
