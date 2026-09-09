import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/friendly_error.dart';
import '../../data/database/database.dart';
import '../../data/database/models/printer_feed_models.dart';
import '../../data/seed/printer_seed.dart';
import '../../providers/database_provider.dart';
import '../../providers/usage_provider.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/icon_action_button.dart';
import 'batch_usage_section.dart';

/// 按 id 查耗材。autoDispose.family 避免列表项销毁后仍缓存，防止内存泄漏。
final consumableByIdProvider =
    FutureProvider.autoDispose.family<Consumable?, int>((ref, id) {
  return ref.read(consumableDaoProvider).getById(id);
});

/// 按 id 查打印机。用轻量 getById 而非 getByIdWithChannels，避免无谓的通道联查。
final printerByIdProvider =
    FutureProvider.autoDispose.family<Printer?, int>((ref, id) {
  return ref.read(printerDaoProvider).getById(id);
});

/// 数据统计页。CRMEB 风格：浅色背景 + 白色实心卡片 + Indigo 强调 + 大量留白。
/// 按日期分组展示消耗记录。UsageLog 的 printerId/consumableId 在外键 setNull 后可能为 null，
/// 这里统一兜底处理，避免 NPE。
class UsageLogScreen extends ConsumerStatefulWidget {
  const UsageLogScreen({super.key});

  @override
  ConsumerState<UsageLogScreen> createState() => _UsageLogScreenState();
}

class _UsageLogScreenState extends ConsumerState<UsageLogScreen> {
  /// 把日志按「今天/昨天/更早」三段分组，保持原倒序。
  Map<String, List<UsageLog>> _groupByDay(List<UsageLog> logs) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final groups = <String, List<UsageLog>>{
      '今天': <UsageLog>[],
      '昨天': <UsageLog>[],
      '更早': <UsageLog>[],
    };
    for (final log in logs) {
      final day =
          DateTime(log.loggedAt.year, log.loggedAt.month, log.loggedAt.day);
      if (day == today) {
        groups['今天']!.add(log);
      } else if (day == yesterday) {
        groups['昨天']!.add(log);
      } else {
        groups['更早']!.add(log);
      }
    }
    // 去掉空分组，避免渲染空标题
    groups.removeWhere((_, v) => v.isEmpty);
    return groups;
  }

  /// 二次确认后删除单条记录。
  Future<void> _confirmDelete(BuildContext context, UsageLog log) async {
    final ok = await AppDialog.confirm(
      context,
      '删除消耗记录',
      '确认删除这条 ${(log.consumedGrams / 1000).toStringAsFixed(1)} 卷的消耗记录？此操作不可撤销。',
      confirmText: '删除',
      destructive: true,
    );
    if (ok) {
      await ref.read(usageLogDaoProvider).deleteLog(log.id);
      if (context.mounted) {
        showSnack(context, '已删除消耗记录');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(usageLogsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: async.when(
        loading: () => const LoadingState(label: '加载使用记录…'),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '加载失败：${friendlyError(err)}',
              textAlign: TextAlign.center,
              style: TextStyle(
                color:
                    isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
              ),
            ),
          ),
        ),
        data: (logs) {
          if (logs.isEmpty) {
            return const EmptyState(
              bambuIconName: 'spool',
              useGlass: true,
              title: '还没有消耗记录',
              subtitle: '在打印机卡片点「已用完」后会自动记录',
            );
          }

          // 顶部汇总：所有记录的 consumedGrams 求和
          final totalGrams = logs.fold<double>(
            0.0,
            (sum, log) => sum + log.consumedGrams,
          );
          final groups = _groupByDay(logs);

          return Padding(
            padding: const EdgeInsets.all(ExperienceTokens.pageGutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ExperiencePageHeader(
                  title: '材料流动时间轴',
                  description: '把每一次换卷与消耗还原成时间。移动鼠标查看最近两周的真实用量，再向下追溯到具体打印机和耗材。',
                ),
                const SizedBox(height: AppSpacing.lg),
                _SummaryCard(
                  logs: logs,
                  totalGrams: totalGrams,
                  count: logs.length,
                ),
                const SizedBox(height: AppSpacing.sm),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      // 批次消耗合并显示（无批次时自动隐藏）
                      const SliverToBoxAdapter(child: BatchUsageSection()),
                      for (final entry in groups.entries)
                        _DaySection(
                          label: entry.key,
                          logs: entry.value,
                          onDelete: (log) => _confirmDelete(context, log),
                        ),
                      const SliverToBoxAdapter(
                        child: SizedBox(height: AppSpacing.xxxl),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 顶部汇总卡片：累计消耗卷数 + 记录条数（白色 GlassCard）。
class _SummaryCard extends StatelessWidget {
  final List<UsageLog> logs;
  final double totalGrams;
  final int count;

  const _SummaryCard({
    required this.logs,
    required this.totalGrams,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [
      for (var offset = 13; offset >= 0; offset--)
        today.subtract(Duration(days: offset)),
    ];
    final values = [
      for (final day in days)
        logs
            .where(
              (log) =>
                  log.loggedAt.year == day.year &&
                  log.loggedAt.month == day.month &&
                  log.loggedAt.day == day.day,
            )
            .fold<double>(0, (sum, log) => sum + log.consumedGrams),
    ];
    final labels = [for (final day in days) DateFormat('M/d').format(day)];

    Widget summary() => Row(
          children: [
            // 左侧图标徽章（拓竹 'spool' SVG）
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.primaryContainer,
                borderRadius: BorderRadius.circular(AppColors.radiusLg),
              ),
              child: Center(
                child: BambuIcon(
                  name: 'spool',
                  size: 22,
                  color: AppColors.primary,
                  applyColorFilter: true,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            // 中间累计卷数
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '累计消耗',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  RichText(
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                        letterSpacing: -0.5,
                        height: 1.1,
                        fontFamily: AppTypography.monoFontFamily,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                      children: [
                        TextSpan(
                          text: (totalGrams / 1000).toStringAsFixed(1),
                        ),
                        TextSpan(
                          text: ' 卷',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary,
                            fontFamily: AppTypography.chineseFontFamily,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 右侧记录条数胶囊 → AppChip(default_ 变体，自带暗色适配)
            AppChip(
              variant: AppChipVariant.default_,
              label: '共 $count 条',
            ),
          ],
        );

    Widget timeline() => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ExperienceSectionHeading(title: '最近 14 天'),
            const SizedBox(height: AppSpacing.sm),
            ExperienceTimeline(
              values: values,
              labels: labels,
              height: 146,
              valueFormatter: (value) => '${value.toStringAsFixed(0)} g',
            ),
          ],
        );

    return OpenStage(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 720) {
            return Column(
              children: [
                summary(),
                const SizedBox(height: AppSpacing.lg),
                timeline(),
              ],
            );
          }
          return Row(
            children: [
              SizedBox(width: 300, child: summary()),
              const SizedBox(width: AppSpacing.xl),
              Expanded(child: timeline()),
            ],
          );
        },
      ),
    );
  }
}

/// 单日分组：小标题 + 卡片列表。build 直接返回 SliverToBoxAdapter，
/// 因此可放入 CustomScrollView 的 slivers 列表。
class _DaySection extends StatelessWidget {
  final String label;
  final List<UsageLog> logs;
  final ValueChanged<UsageLog> onDelete;

  const _DaySection({
    required this.label,
    required this.logs,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.lg,
          AppSpacing.xl,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 分组小标题 + 条数徽章
            Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                // 条数徽章 → AppChip(selected 变体，自带暗色适配)
                AppChip(
                  variant: AppChipVariant.selected,
                  label: '${logs.length}',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            // 卡片列表
            for (final log in logs)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm + 2),
                child: _UsageLogCard(
                  log: log,
                  onDelete: () => onDelete(log),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单条消耗记录卡片。通过 autoDispose family provider 查关联耗材/打印机信息。
/// 处理 printerId/consumableId 为 null 的情况（外键 setNull 后的兜底）。
class _UsageLogCard extends ConsumerWidget {
  final UsageLog log;
  final VoidCallback onDelete;

  const _UsageLogCard({required this.log, required this.onDelete});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // UsageLog 的 printerId/consumableId 是 nullable（外键 setNull），直接判空
    final consumableId = log.consumableId;
    final printerId = log.printerId;

    // id 为 null 时直接给一个 data(null) 的 AsyncValue，避免向 family 传 null
    final consumableAsync = consumableId == null
        ? const AsyncValue<Consumable?>.data(null)
        : ref.watch(consumableByIdProvider(consumableId));
    final printerAsync = printerId == null
        ? const AsyncValue<Printer?>.data(null)
        : ref.watch(printerByIdProvider(printerId));

    final timeText = DateFormat('HH:mm').format(log.loggedAt);
    final consumable = consumableAsync.maybeWhen(
      data: (c) => c,
      orElse: () => null,
    );
    final printer = printerAsync.maybeWhen(
      data: (p) => p,
      orElse: () => null,
    );
    final preset = printer == null
        ? null
        : PrinterPresets.findByModel(printer.model, brand: printer.brand);
    final channelLabel = printerFeedChannelLabel(
      log.channelIndex,
      compact: true,
      legacySingleExternal: preset?.externalInputCount == 1 ||
          (preset == null && printer?.channelCount == 1),
    );
    final consumableLoading = !consumableAsync.hasValue && consumableId != null;
    final printerLoading = !printerAsync.hasValue && printerId != null;

    final color = consumable?.colorHex != null
        ? ColorUtils.fromHex(consumable!.colorHex)
        : null;

    // 打印机标题：优先用 name，回退 model。null → 未关联；加载中 → 占位；查到 null → 已删除
    final printerTitle = printerId == null
        ? '未关联打印机'
        : printerLoading
            ? '加载中…'
            : printer == null
                ? '已删除的打印机'
                : (printer.name?.isNotEmpty == true
                    ? printer.name!
                    : printer.model);

    // 打印机型号（用于通道标签行小字）
    final printerModel = (printer == null || printerLoading)
        ? null
        : '${printer.brand} ${printer.model}';

    // 耗材副标题：null → 已删除；加载中 → 占位；查到 null → 已删除
    final consumableSubtitle = consumableId == null
        ? '已删除的耗材'
        : consumableLoading
            ? '加载中…'
            : consumable == null
                ? '已删除的耗材'
                : (consumable.colorName?.isNotEmpty == true
                    ? consumable.colorName!
                    : consumable.colorHex);

    final tertiaryColor =
        isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;
    final monoDataStyle = TextStyle(
      fontSize: 11,
      color: tertiaryColor,
      fontFamily: AppTypography.monoFontFamily,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md + 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(ExperienceTokens.objectRadius),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧色块（耗材被删除时用灰色占位）
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color ??
                  (isDark
                      ? AppColors.surfaceVariantDark
                      : AppColors.surfaceVariant),
              borderRadius: BorderRadius.circular(AppColors.radiusMd),
              border: Border.all(
                color: isDark ? AppColors.outlineDark : AppColors.outline,
                width: 1.5,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // 中间信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  printerTitle,
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
                const SizedBox(height: AppSpacing.xs + 2),
                // 通道 + 打印机型号 + 状态标签 → AppChip
                Wrap(
                  spacing: AppSpacing.xs + 2,
                  runSpacing: AppSpacing.xs + 2,
                  children: [
                    AppChip(
                      variant: AppChipVariant.default_,
                      label: '供料位 · $channelLabel',
                    ),
                    if (printerModel != null)
                      AppChip(
                        variant: AppChipVariant.default_,
                        label: printerModel,
                      ),
                    AppChip(
                      variant: log.finished
                          ? AppChipVariant.danger
                          : AppChipVariant.warn,
                      label: log.finished ? '已用完' : '部分消耗',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                // 消耗卷数 + 时间
                Row(
                  children: [
                    Text(
                      '${(log.consumedGrams / 1000).toStringAsFixed(1)} 卷',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                        fontFamily: AppTypography.monoFontFamily,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm + 2),
                    Icon(
                      Icons.schedule,
                      size: 13,
                      color: tertiaryColor,
                    ),
                    const SizedBox(width: 2),
                    Text(timeText, style: monoDataStyle),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                // 耗材副标题（颜色名/HEX）
                Text(
                  consumableSubtitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (log.note != null && log.note!.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs + 2),
                  Text(
                    log.note!,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          // 右侧删除按钮
          DeleteActionButton(
            onTap: onDelete,
            size: 30,
          ),
        ],
      ),
    );
  }
}
