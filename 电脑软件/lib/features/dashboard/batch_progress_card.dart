// Dashboard 批次进度卡。
//
// 当活跃打印机正在打某个批次任务时，显示"4 台中 3 台完成，1 台 70%"。
// 数据来源 [activeBatchProgressProvider]，无批次时返回 [SizedBox.shrink]。
//
// 卡片内容：
//   - 头部：批次图标 + 任务名 + 批次号
//   - 进度条：平均进度
//   - 统计：N 台完成 / M 台进行中 / K 台失败
//   - 异常提示（可选）：有失败时显示警告条

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/batch_recognition_provider.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_progress.dart';
import '../../widgets/glass_card.dart';

/// 批次进度卡。
class BatchProgressCard extends ConsumerWidget {
  const BatchProgressCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(activeBatchProgressProvider);

    return async.when(
      // Keep the last rendered batch while a progress change reloads the
      // aggregate query. Replacing it with SizedBox for one frame caused the
      // entire card to blink on every update.
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (data) {
        if (data == null) return const SizedBox.shrink();
        return _Card(data: data);
      },
    );
  }
}

class _Card extends StatelessWidget {
  final Map<String, dynamic> data;

  const _Card({required this.data});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final batchId = data['batch_id'] as String? ?? '';
    final count = (data['count'] as num?)?.toInt() ?? 0;
    final taskName = data['task_name'] as String? ?? '';
    final successCount = (data['success_count'] as num?)?.toInt() ?? 0;
    final failCount = (data['fail_count'] as num?)?.toInt() ?? 0;
    final printingCount = (data['printing_count'] as num?)?.toInt() ?? 0;
    final avgMc = (data['avg_mc_percent'] as num?)?.toInt() ?? 0;

    final hasAnomaly = failCount > 0 && successCount > 0;
    // 多色任务标签
    final isMultiColor = data['is_multi_color'] as bool? ?? false;
    final colorCount = (data['color_count'] as num?)?.toInt() ?? 1;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: GlassCard(
        // Same visual fill as L2, without a live blur layer that flashes when
        // Windows recomposites this frequently-updated card.
        level: GlassLevel.l1,
        color: isDark ? AppColors.glassFillL2Dark : AppColors.glassFillL2,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.primaryContainer,
                    borderRadius: BorderRadius.circular(AppColors.radiusMd),
                  ),
                  child: Icon(
                    Icons.layers_rounded,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '批次打印',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? AppColors.textTertiaryDark
                              : AppColors.textTertiary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        taskName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AppChip(
                  variant: AppChipVariant.default_,
                  label:
                      '#${batchId.length > 6 ? batchId.substring(batchId.length - 6) : batchId}',
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 进度条
            Row(
              children: [
                Expanded(
                  child: AppProgress(
                    value: avgMc / 100.0,
                    thickness: 8,
                    showGlow: true,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$avgMc%',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: isDark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimary,
                    letterSpacing: -0.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 统计行
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _StatusChip(
                  label: '$count 台',
                  color: AppColors.primary,
                  icon: Icons.layers_rounded,
                ),
                _StatusChip(
                  label: '$successCount 完成',
                  color: AppColors.success,
                  icon: Icons.check_circle_rounded,
                ),
                if (printingCount > 0)
                  _StatusChip(
                    label: '$printingCount 进行中',
                    color: AppColors.primary,
                    icon: Icons.autorenew_rounded,
                  ),
                if (failCount > 0)
                  _StatusChip(
                    label: '$failCount 失败',
                    color: AppColors.danger,
                    icon: Icons.error_rounded,
                  ),
                if (isMultiColor) ...[
                  _StatusChip(
                    label: '$colorCount 色',
                    color: AppColors.info,
                    icon: Icons.palette_rounded,
                  ),
                ],
              ],
            ),
            // 异常对比提示
            if (hasAnomaly) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.warningContainer,
                  borderRadius: BorderRadius.circular(AppColors.radiusSm),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 14,
                      color: AppColors.warning,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '本批次 $failCount 台失败但 $successCount 台同任务成功，'
                        '失败原因大概率是机器问题，建议检查耗材和喷嘴',
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: AppColors.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 状态小徽章。
class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _StatusChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
