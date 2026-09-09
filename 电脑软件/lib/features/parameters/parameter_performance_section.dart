// 参数打印表现展示组件。
//
// 任务书 Phase D 要求：
// - 参数详情新增"打印表现"区域，不嵌套多层卡片，包含指标、样本分布和最近记录。
// - 公开社区参数卡片只显示紧凑摘要，例如"12 次社区实打 · 91% 可用"；
//   少于门槛的非作者社区样本时显示"样本不足"。
// - 本地参数和用户自己的拓竹云端预设按本机 preset_print_results 展示本地样本，
//   不套用"非作者社区样本"门槛，也不能把本地样本伪装成社区可信度。
// - 不显示虚构曲线。没有数据时使用明确空状态。
// - UI 必须分别展示"设备完成"和"用户评分"。
// - 每项指标都返回 sampleCount，UI 不得隐藏样本数。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/services/parameter_performance_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/glass_card.dart';

/// 参数打印表现区域。
///
/// 在参数详情中展示本地样本汇总（[scope] = local）或
/// 社区汇总（[scope] = community）。
class ParameterPerformanceSection extends ConsumerWidget {
  /// 关联 ID：local 传 snapshotId，community 传 publicationId。
  final String keyId;

  /// 汇总作用域。
  final PerformanceScope scope;

  const ParameterPerformanceSection({
    super.key,
    required this.keyId,
    required this.scope,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncSnapshot = ref.watch(
      parameterPerformanceBySnapshotProvider(keyId),
    );
    final asyncPublication = ref.watch(
      parameterPerformanceByPublicationProvider(keyId),
    );

    final asyncValue =
        scope == PerformanceScope.local ? asyncSnapshot : asyncPublication;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return asyncValue.when(
      loading: () => _LoadingCard(isDark: isDark),
      error: (e, st) => _ErrorCard(
        isDark: isDark,
        message: '加载失败：$e',
      ),
      data: (summary) => _PerformanceCard(
        summary: summary,
        isDark: isDark,
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  final bool isDark;
  const _LoadingCard({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            '加载打印表现…',
            style: TextStyle(
              fontSize: 13,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final bool isDark;
  final String message;
  const _ErrorCard({required this.isDark, required this.message});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.danger),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, color: AppColors.danger),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _PerformanceCard extends StatelessWidget {
  final ParameterPerformanceSummary summary;
  final bool isDark;
  const _PerformanceCard({required this.summary, required this.isDark});

  @override
  Widget build(BuildContext context) {
    // 空状态
    if (summary.sampleCount == 0) {
      return GlassCard(
        level: GlassLevel.l2,
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: EmptyState(
          icon: Icons.bar_chart_outlined,
          title: summary.scope == PerformanceScope.community
              ? '暂无社区打印记录'
              : '暂无本地打印记录',
          subtitle: '使用此参数打印后将自动汇总',
        ),
      );
    }

    // 样本不足（仅社区）
    if (!summary.meetsThreshold) {
      return GlassCard(
        level: GlassLevel.l2,
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: AppColors.warning,
                ),
                SizedBox(width: AppSpacing.sm),
                Text(
                  '样本不足',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.warning,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              summary.thresholdReason ?? '社区样本不足',
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '当前样本数：${summary.sampleCount}',
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
          ],
        ),
      );
    }

    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 + 总样本
          Row(
            children: [
              Icon(
                Icons.insights_rounded,
                size: 18,
                color:
                    isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '打印表现',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              _ScopeChip(scope: summary.scope),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '样本 ${summary.sampleCount}',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // 设备完成率 + 用户可用率（两列）
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _MetricBlock(
                  label: '设备完成率',
                  value: summary.deviceCompletionRate == null
                      ? '—'
                      : '${(summary.deviceCompletionRate! * 100).toStringAsFixed(0)}%',
                  sub: _completionSub(summary),
                  color: AppColors.info,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _MetricBlock(
                  label: '参数可用率',
                  value: summary.userUsableRate == null
                      ? '—'
                      : '${(summary.userUsableRate! * 100).toStringAsFixed(0)}%',
                  sub: _usableSub(summary),
                  color: AppColors.success,
                  isDark: isDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // 平均评分 + 耗时偏差 + 克数偏差（三列）
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _MetricBlock(
                  label: '平均评分',
                  value: summary.averageRating == null
                      ? '—'
                      : summary.averageRating!.toStringAsFixed(1),
                  sub: '${summary.ratingCount} 人评分',
                  color: AppColors.warning,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _MetricBlock(
                  label: '平均耗时偏差',
                  value: summary.averageTimeDeviationRatio == null
                      ? '—'
                      : '${summary.averageTimeDeviationRatio! >= 0 ? '+' : ''}'
                          '${(summary.averageTimeDeviationRatio! * 100).toStringAsFixed(0)}%',
                  sub: '相对预计',
                  color: AppColors.info,
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _MetricBlock(
                  label: '平均克数偏差',
                  value: summary.averageGramDeviationRatio == null
                      ? '—'
                      : '${summary.averageGramDeviationRatio! >= 0 ? '+' : ''}'
                          '${(summary.averageGramDeviationRatio! * 100).toStringAsFixed(0)}%',
                  sub: '相对预计',
                  color: AppColors.info,
                  isDark: isDark,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // 设备状态分布
          _DistributionRow(
            label: '设备状态分布',
            items: [
              _DistributionItem(
                label: '完成',
                count: summary.deviceFinishedCount,
                color: AppColors.success,
              ),
              _DistributionItem(
                label: '失败',
                count: summary.deviceFailedCount,
                color: AppColors.danger,
              ),
              _DistributionItem(
                label: '取消',
                count: summary.deviceCancelledCount,
                color: AppColors.warning,
              ),
            ],
            isDark: isDark,
          ),
          const SizedBox(height: AppSpacing.md),

          // 用户评价分布
          if (summary.userConfirmedCount > 0) ...[
            _DistributionRow(
              label: '用户评价分布',
              items: [
                _DistributionItem(
                  label: '成功',
                  count: summary.userSuccessCount,
                  color: AppColors.success,
                ),
                _DistributionItem(
                  label: '可用',
                  count: summary.userUsableCount,
                  color: AppColors.warning,
                ),
                _DistributionItem(
                  label: '失败',
                  count: summary.userQualityFailedCount,
                  color: AppColors.danger,
                ),
              ],
              isDark: isDark,
            ),
            const SizedBox(height: AppSpacing.md),
          ],

          // 常见打印机 + 材料
          if (summary.topPrinterModels.isNotEmpty ||
              summary.topMaterialProfiles.isNotEmpty) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (summary.topPrinterModels.isNotEmpty)
                  Expanded(
                    child: _TopList(
                      label: '常见打印机',
                      items: summary.topPrinterModels
                          .map((e) => (text: e.model, count: e.count))
                          .toList(),
                      isDark: isDark,
                    ),
                  ),
                if (summary.topPrinterModels.isNotEmpty &&
                    summary.topMaterialProfiles.isNotEmpty)
                  const SizedBox(width: AppSpacing.md),
                if (summary.topMaterialProfiles.isNotEmpty)
                  Expanded(
                    child: _TopList(
                      label: '常见材料',
                      items: summary.topMaterialProfiles
                          .map((e) => (text: e.material, count: e.count))
                          .toList(),
                      isDark: isDark,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
          ],

          // 最近记录时间
          if (summary.lastRecordedAt != null)
            Row(
              children: [
                Icon(
                  Icons.schedule,
                  size: 12,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
                const SizedBox(width: 4),
                Text(
                  '最近记录：${DateFormat('yyyy-MM-dd HH:mm').format(summary.lastRecordedAt!)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _completionSub(ParameterPerformanceSummary s) {
    return '${s.deviceFinishedCount} 完成 / ${s.deviceFailedCount} 失败'
        '${s.deviceCancelledCount > 0 ? ' / ${s.deviceCancelledCount} 取消' : ''}';
  }

  String _usableSub(ParameterPerformanceSummary s) {
    if (s.userConfirmedCount == 0) return '暂无用户评价';
    return '${s.userSuccessCount} 成功 / ${s.userUsableCount} 可用 / ${s.userQualityFailedCount} 失败';
  }
}

class _ScopeChip extends StatelessWidget {
  final PerformanceScope scope;
  const _ScopeChip({required this.scope});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (scope) {
      PerformanceScope.local => ('本地', AppColors.info),
      PerformanceScope.community => ('社区', AppColors.success),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _MetricBlock extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final Color color;
  final bool isDark;

  const _MetricBlock({
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          sub,
          style: TextStyle(
            fontSize: 10,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _DistributionItem {
  final String label;
  final int count;
  final Color color;
  const _DistributionItem({
    required this.label,
    required this.count,
    required this.color,
  });
}

class _DistributionRow extends StatelessWidget {
  final String label;
  final List<_DistributionItem> items;
  final bool isDark;
  const _DistributionRow({
    required this.label,
    required this.items,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: 4,
          children: items
              .map(
                (item) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: item.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${item.label} ${item.count}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _TopList extends StatelessWidget {
  final String label;
  final List<({String text, int count})> items;
  final bool isDark;
  const _TopList({
    required this.label,
    required this.items,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ),
        const SizedBox(height: 4),
        ...items.map(
          (item) => Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    item.text,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '×${item.count}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
