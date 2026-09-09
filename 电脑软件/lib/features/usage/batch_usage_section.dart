// 批次消耗合并显示区段。
//
// 嵌入 UsageLogScreen 顶部，展示最近批次的合并成本信息：
//   批次#B123 · 4 台 · 手机支架.gcode
//   总消耗 12.8g × 4 = 51.2g    总成本 ¥3.2 × 4 = ¥12.8
//   3 台成功 · 1 台失败
//
// 点击批次卡片展开详情，显示每台打印机的消耗明细和异常对比提示。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/friendly_error.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/batch_recognition_provider.dart';
import '../../providers/database_provider.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/glass_card.dart';

/// 批次消耗合并显示区段。
///
/// 显示最近 50 个批次的合并成本信息。
/// 数据来源 [recentBatchesProvider]，无批次时返回 [SizedBox.shrink]。
class BatchUsageSection extends ConsumerWidget {
  const BatchUsageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncBatches = ref.watch(recentBatchesProvider);

    return asyncBatches.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (batches) {
        if (batches.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: GlassCard(
            level: GlassLevel.l2,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.layers_rounded,
                      size: 18,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '批次消耗合并',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                    ),
                    const Spacer(),
                    AppChip(
                      variant: AppChipVariant.default_,
                      label: '${batches.length} 个批次',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                for (int i = 0; i < batches.length; i++) ...[
                  _BatchCard(data: batches[i]),
                  if (i != batches.length - 1) const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 单个批次卡片。
class _BatchCard extends ConsumerStatefulWidget {
  final Map<String, dynamic> data;

  const _BatchCard({required this.data});

  @override
  ConsumerState<_BatchCard> createState() => _BatchCardState();
}

class _BatchCardState extends ConsumerState<_BatchCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final d = widget.data;
    final batchId = d['batch_id'] as String? ?? '';
    final count = (d['count'] as num?)?.toInt() ?? 0;
    final taskName = d['task_name'] as String? ?? '未知文件';
    final successCount = (d['success_count'] as num?)?.toInt() ?? 0;
    final failCount = (d['fail_count'] as num?)?.toInt() ?? 0;
    final totalGrams = (d['total_grams'] as num?)?.toDouble() ?? 0;
    final totalCost = (d['total_cost'] as num?)?.toDouble() ?? 0;
    final firstStarted = (d['first_started'] as num?)?.toInt();
    final finishedCount = successCount + failCount;
    // 多色任务标签
    final isMultiColor = d['is_multi_color'] as bool? ?? false;
    final colorCount = (d['color_count'] as num?)?.toInt() ?? 1;

    // 单件平均值（按已完成台数算）
    final perUnitGrams = finishedCount > 0 ? totalGrams / finishedCount : 0.0;
    final perUnitCost = finishedCount > 0 ? totalCost / finishedCount : 0.0;

    // 异常提示：1 台失败 + 其他成功
    final hasAnomaly = failCount > 0 && successCount > 0;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: hasAnomaly
            ? Border.all(
                color: AppColors.warning.withValues(alpha: 0.4),
                width: 1,
              )
            : null,
      ),
      child: Column(
        children: [
          // 头部行（点击展开/收起）
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: AppColors.primaryContainer,
                      borderRadius: BorderRadius.circular(AppColors.radiusSm),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '#${batchId.length > 6 ? batchId.substring(batchId.length - 6) : batchId}',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          taskName,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppColors.textPrimaryDark
                                : AppColors.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              '$count 台 · ${_formatTime(firstStarted)}',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? AppColors.textTertiaryDark
                                    : AppColors.textTertiary,
                              ),
                            ),
                            if (isMultiColor) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: AppColors.info.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.palette_rounded,
                                      size: 9,
                                      color: AppColors.info,
                                    ),
                                    const SizedBox(width: 2),
                                    Text(
                                      '$colorCount 色',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.info,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '¥${totalCost.toStringAsFixed(2)}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        '${totalGrams.toStringAsFixed(1)}g',
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? AppColors.textTertiaryDark
                              : AppColors.textTertiary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 6),
                  BambuIcon(
                    name: _expanded ? 'expand_btn' : 'collapse_btn',
                    size: 18,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                    applyColorFilter: true,
                  ),
                ],
              ),
            ),
          ),
          // 展开详情
          if (_expanded) ...[
            Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(
                    height: 1,
                    color: isDark ? AppColors.dividerDark : AppColors.divider,
                  ),
                  const SizedBox(height: 10),
                  // 单件平均
                  Row(
                    children: [
                      Expanded(
                        child: _StatBox(
                          label: '单件平均',
                          value:
                              '${perUnitGrams.toStringAsFixed(1)}g / ¥${perUnitCost.toStringAsFixed(2)}',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatBox(
                          label: '完成情况',
                          value: '$successCount 成功 / $failCount 失败'
                              '${finishedCount < count ? ' / ${count - finishedCount} 进行中' : ''}',
                          valueColor: failCount > 0
                              ? AppColors.warning
                              : AppColors.success,
                        ),
                      ),
                    ],
                  ),
                  // 异常对比提示
                  if (hasAnomaly) ...[
                    const SizedBox(height: 10),
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
                              '$failCount 台失败但 $successCount 台同任务成功，'
                              '失败原因大概率是机器问题（堵头/翘边/耗材受潮），'
                              '建议检查失败那台的耗材和喷嘴',
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
                  // 每台明细
                  const SizedBox(height: 10),
                  Text(
                    '每台明细',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  _BatchDetailList(batchId: batchId),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatTime(int? ms) {
    if (ms == null) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// 单个统计小框。
class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatBox({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surface,
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color:
                  isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: valueColor ??
                  (isDark ? AppColors.textPrimaryDark : AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 批次详情列表（每台打印机的消耗明细）。
class _BatchDetailList extends ConsumerWidget {
  final String batchId;

  const _BatchDetailList({required this.batchId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(batchConsumptionProvider(batchId));
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(8),
        child: SizedBox(
          height: 14,
          width: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => Text(
        '加载失败: ${friendlyError(e)}',
        style: const TextStyle(fontSize: 11, color: AppColors.danger),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return Text(
            '无明细',
            style: TextStyle(
              fontSize: 11,
              color:
                  isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in rows) ...[
              _DetailRow(data: r),
              const SizedBox(height: 4),
            ],
          ],
        );
      },
    );
  }
}

/// 单条详情行。
class _DetailRow extends ConsumerWidget {
  final Map<String, dynamic> data;

  const _DetailRow({required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final status = data['status'] as String? ?? '';
    final grams = (data['total_consumed_grams'] as num?)?.toDouble() ?? 0;
    final cost = (data['total_cost'] as num?)?.toDouble() ?? 0;
    final printerId = (data['printer_id'] as num?)?.toInt();

    // 状态颜色
    final Color statusColor;
    final String statusLabel;
    switch (status) {
      case 'finished':
        statusColor = AppColors.success;
        statusLabel = '成功';
        break;
      case 'failed':
        statusColor = AppColors.danger;
        statusLabel = '失败';
        break;
      case 'cancelled':
        statusColor = AppColors.warning;
        statusLabel = '取消';
        break;
      case 'printing':
        statusColor = AppColors.primary;
        statusLabel = '进行中';
        break;
      default:
        statusColor =
            isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;
        statusLabel = status;
    }

    // 查打印机名
    final printerName = printerId == null
        ? '未知打印机'
        : ref.watch(_printerNameProvider(printerId)).maybeWhen(
              data: (name) => name ?? '未知打印机',
              orElse: () => '加载中…',
            );

    return Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: statusColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            printerName,
            style: TextStyle(
              fontSize: 11,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Text(
          '${grams.toStringAsFixed(1)}g · ¥${cost.toStringAsFixed(2)}',
          style: TextStyle(
            fontSize: 11,
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          statusLabel,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: statusColor,
          ),
        ),
      ],
    );
  }
}

/// 按 id 查打印机名（轻量查询，缓存）。
final _printerNameProvider =
    FutureProvider.autoDispose.family<String?, int>((ref, id) async {
  final p = await ref.read(printerDaoProvider).getById(id);
  return p?.name;
});
