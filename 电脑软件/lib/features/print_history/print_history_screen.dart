import 'dart:ui' as ui;

import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/gram_utils.dart';
import '../../core/utils/friendly_error.dart';
import '../../data/database/database.dart';
import '../../data/database/models/print_task.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/print_history_provider.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/app_stat_box.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import 'cloud_task_history_dialog.dart';
import 'print_task_detail_sheet.dart';

/// 时间范围模式。
enum _RangeMode { all, week, month, custom }

/// 按 id 查打印机（autoDispose 避免列表项销毁后缓存泄漏）。
final _printerByIdProvider = FutureProvider.autoDispose.family<Printer?, int>((
  ref,
  id,
) {
  return ref.read(printerDaoProvider).getById(id);
});

/// 按 id 查耗材。
final _consumableByIdProvider = FutureProvider.autoDispose
    .family<Consumable?, int>((ref, id) {
      return ref.read(consumableDaoProvider).getById(id);
    });

/// 打印历史与成功率统计页。
///
/// 布局参考 [FilamentCostScreen]：CustomScrollView + GlassCard 分块。
/// 顶部为 4 格汇总（总任务/成功率/失败/总消耗），中部为时间范围切换 +
/// 状态分布横向条形图，底部为按 今天/昨天/本周/更早 分组的任务列表。
class PrintHistoryScreen extends ConsumerStatefulWidget {
  const PrintHistoryScreen({super.key});

  @override
  ConsumerState<PrintHistoryScreen> createState() => _PrintHistoryScreenState();
}

class _PrintHistoryScreenState extends ConsumerState<PrintHistoryScreen> {
  _RangeMode _rangeMode = _RangeMode.all;

  /// 根据范围模式计算 [start, end]；all / custom 返回 (null, null)。
  /// custom 模式的时间范围由日期选择器直接写入 filter，不在此重算。
  (DateTime?, DateTime?) _rangeBounds(_RangeMode mode) {
    final now = DateTime.now();
    switch (mode) {
      case _RangeMode.all:
        return (null, null);
      case _RangeMode.week:
        var start = now.subtract(Duration(days: now.weekday - 1));
        start = DateTime(start.year, start.month, start.day);
        return (start, now);
      case _RangeMode.month:
        final start = DateTime(now.year, now.month, 1);
        return (start, now);
      case _RangeMode.custom:
        return (null, null);
    }
  }

  /// 切换范围模式。custom 弹出日期范围选择器。
  Future<void> _selectRange(_RangeMode mode) async {
    if (mode == _RangeMode.custom) {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 3, 1, 1),
        lastDate: now,
        initialDateRange: DateTimeRange(
          start: now.subtract(const Duration(days: 7)),
          end: now,
        ),
      );
      if (picked == null) return;
      setState(() => _rangeMode = mode);
      _updateFilter(start: picked.start, end: picked.end);
      return;
    }
    setState(() => _rangeMode = mode);
    final (start, end) = _rangeBounds(mode);
    _updateFilter(start: start, end: end);
  }

  /// 更新 filter 的时间范围，保留其他过滤条件（status/printer/model）。
  void _updateFilter({DateTime? start, DateTime? end}) {
    final old = ref.read(printHistoryFilterProvider);
    ref.read(printHistoryFilterProvider.notifier).state = PrintHistoryFilter(
      start: start,
      end: end,
      status: old.status,
      printerId: old.printerId,
      modelName: old.modelName,
    );
  }

  void _toggleStatusFilter(PrintTaskStatus status) {
    final current = ref.read(printHistoryFilterProvider);
    ref
        .read(printHistoryFilterProvider.notifier)
        .state = current.status == status
        ? current.copyWith(clearStatus: true)
        : current.copyWith(status: status);
  }

  /// 按 今天/昨天/本周/更早 分组，保持原倒序。
  Map<String, List<PrintTask>> _groupByPeriod(List<PrintTask> tasks) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final weekStart = today.subtract(Duration(days: now.weekday - 1));

    final groups = <String, List<PrintTask>>{
      '今天': <PrintTask>[],
      '昨天': <PrintTask>[],
      '本周': <PrintTask>[],
      '更早': <PrintTask>[],
    };
    for (final t in tasks) {
      final anchor = t.startedAt ?? t.createdAt;
      final day = DateTime(anchor.year, anchor.month, anchor.day);
      if (day == today) {
        groups['今天']!.add(t);
      } else if (day == yesterday) {
        groups['昨天']!.add(t);
      } else if (!day.isBefore(weekStart)) {
        groups['本周']!.add(t);
      } else {
        groups['更早']!.add(t);
      }
    }
    groups.removeWhere((_, v) => v.isEmpty);
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final tasksAsync = ref.watch(filteredPrintTasksProvider);
    final cloudLoggedIn = ref.watch(
      bambuCloudProvider.select((s) => s.session != null),
    );
    final activeFilter = ref.watch(printHistoryFilterProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: tasksAsync.when(
        // 范围筛选会让 StreamProvider 因依赖变化而重建。保留上一帧数据，
        // 只在筛选栏下显示一条局部进度线，避免整个页面闪成 loading 状态。
        skipLoadingOnReload: true,
        skipLoadingOnRefresh: true,
        loading: () => const LoadingState(label: '加载打印历史…'),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '加载失败：${friendlyError(err)}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.danger),
            ),
          ),
        ),
        data: (tasks) {
          if (tasks.isEmpty) {
            return EmptyState(
              bambuIconName: 'monitor_item_print',
              useGlass: true,
              title: activeFilter.status == null
                  ? '暂无打印历史记录'
                  : '没有${activeFilter.status!.label}任务',
              subtitle: activeFilter.status == null
                  ? '完成的打印任务会自动归档到这里'
                  : '可以清除状态筛选，查看其他打印记录',
              actionLabel: activeFilter.status == null ? null : '清除状态筛选',
              onAction: activeFilter.status == null
                  ? null
                  : () => _toggleStatusFilter(activeFilter.status!),
            );
          }
          final groups = _groupByPeriod(tasks);
          final stats = PrintHistoryStats.from(tasks);
          return Padding(
            padding: const EdgeInsets.all(ExperienceTokens.pageGutter),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const ExperiencePageHeader(
                  title: '打印记忆',
                  description: '沿时间回看每一次完成、失败与材料偏差。范围筛选会同步更新曲线、分布和下面的任务记录。',
                ),
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    border: Border.symmetric(
                      horizontal: BorderSide(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _RangeToggleBar(
                          mode: _rangeMode,
                          onChanged: _selectRange,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      _CloudHistoryButton(
                        loggedIn: cloudLoggedIn,
                        onTap: () => CloudTaskHistoryDialog.show(context),
                      ),
                    ],
                  ),
                ),
                AnimatedContainer(
                  key: const ValueKey('print-history-inline-refresh'),
                  duration: AppMotion.duration(
                    context,
                    ExperienceTokens.hoverDuration,
                  ),
                  curve: ExperienceTokens.motionCurve,
                  height: tasksAsync.isLoading ? 2 : 0,
                  child: tasksAsync.isLoading
                      ? const LinearProgressIndicator(minHeight: 2)
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: AppSpacing.md),
                _SummaryCard(stats: stats, tasks: tasks),
                const SizedBox(height: AppSpacing.sm),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.xl,
                            AppSpacing.sm,
                            AppSpacing.xl,
                            AppSpacing.md,
                          ),
                          child: _StatusDistributionCard(
                            tasks: tasks,
                            selectedStatus: activeFilter.status,
                            onStatusSelected: _toggleStatusFilter,
                          ),
                        ),
                      ),
                      for (final entry in groups.entries)
                        _DaySection(label: entry.key, tasks: entry.value),
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

/// 顶部汇总卡片：4 格统计（总任务/成功率/失败/总消耗）。
class _SummaryCard extends StatelessWidget {
  final PrintHistoryStats stats;
  final List<PrintTask> tasks;
  const _SummaryCard({required this.stats, required this.tasks});

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
        tasks
            .where((task) {
              final anchor = task.startedAt ?? task.createdAt;
              return anchor.year == day.year &&
                  anchor.month == day.month &&
                  anchor.day == day.day;
            })
            .length
            .toDouble(),
    ];
    final labels = [for (final day in days) DateFormat('M/d').format(day)];

    Widget statsPanel() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            BambuIcon(
              name: 'monitor_item_print',
              size: 16,
              color: AppColors.primary,
              applyColorFilter: true,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              '打印历史统计',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: AppStatBox(
                    label: '总任务',
                    value: '${stats.totalTasks}',
                    unit: '',
                    bambuIconName: 'monitor_item_print',
                    color: AppColors.primary,
                    useGlass: false,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppStatBox(
                    label: '成功率',
                    value: (stats.successRate * 100).toStringAsFixed(0),
                    unit: '%',
                    bambuIconName: 'completed',
                    color: AppColors.success,
                    highlight: true,
                    useGlass: false,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: AppStatBox(
                    label: '失败',
                    value: '${stats.failedCount}',
                    unit: '',
                    bambuIconName: 'warning',
                    color: AppColors.danger,
                    useGlass: false,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppStatBox(
                    label: '总消耗',
                    value: GramUtils.formatGrams(stats.totalActualGrams),
                    unit: '',
                    bambuIconName: 'spool',
                    color: AppColors.info,
                    useGlass: false,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );

    Widget timeline() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const ExperienceSectionHeading(title: '任务节奏 · 最近 14 天'),
        const SizedBox(height: AppSpacing.sm),
        ExperienceTimeline(
          values: values,
          labels: labels,
          height: 140,
          valueFormatter: (value) => '${value.toStringAsFixed(0)} 个任务',
        ),
      ],
    );

    return OpenStage(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 820) {
            return Column(
              children: [
                statsPanel(),
                const SizedBox(height: AppSpacing.lg),
                timeline(),
              ],
            );
          }
          return Row(
            children: [
              Expanded(flex: 5, child: statsPanel()),
              const SizedBox(width: AppSpacing.xl),
              Expanded(flex: 4, child: timeline()),
            ],
          );
        },
      ),
    );
  }
}

/// 时间范围切换按钮组（全部 / 本周 / 本月 / 自定义）。
class _RangeToggleBar extends StatelessWidget {
  final _RangeMode mode;
  final ValueChanged<_RangeMode> onChanged;

  const _RangeToggleBar({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        decoration: BoxDecoration(
          color: isDark
              ? AppColors.surfaceVariantDark
              : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: _RangeMode.values.map((m) {
            final selected = m == mode;
            final label = switch (m) {
              _RangeMode.all => '全部',
              _RangeMode.week => '本周',
              _RangeMode.month => '本月',
              _RangeMode.custom => '自定义',
            };
            if (GlassButtonsTheme.enabledOf(context)) {
              return Semantics(
                selected: selected,
                child: AppGlassButton(
                  key: ValueKey('print-history-range-${m.name}'),
                  label: label,
                  onPressed: () => onChanged(m),
                  variant: selected
                      ? AppGlassButtonVariant.primary
                      : AppGlassButtonVariant.quiet,
                  compact: true,
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs + 2,
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              );
            }
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                key: ValueKey('print-history-range-${m.name}'),
                onTap: () => onChanged(m),
                child: AnimatedContainer(
                  duration: AppMotion.duration(
                    context,
                    ExperienceTokens.hoverDuration,
                  ),
                  curve: ExperienceTokens.motionCurve,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs + 2,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppColors.radiusSm),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? Colors.white
                          : (isDark
                                ? AppColors.textSecondaryDark
                                : AppColors.textSecondary),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// 云端历史入口按钮。
///
/// 未登录拓竹云时按钮置灰，点击仍可打开对话框（对话框内会提示去登录）。
class _CloudHistoryButton extends StatelessWidget {
  final bool loggedIn;
  final VoidCallback onTap;

  const _CloudHistoryButton({required this.loggedIn, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = loggedIn
        ? AppColors.info
        : (isDark ? AppColors.textTertiaryDark : AppColors.textTertiary);
    if (GlassButtonsTheme.enabledOf(context)) {
      return Tooltip(
        message: loggedIn ? '查看拓竹云端任务历史' : '未登录拓竹云账号',
        child: AppGlassButton(
          label: '云端历史',
          onPressed: onTap,
          variant: AppGlassButtonVariant.secondary,
          tint: loggedIn ? AppColors.info : null,
          compact: true,
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs + 2,
          ),
          icon: Builder(
            builder: (context) => BambuIcon(
              name: loggedIn ? 'monitor_upgrade_online' : 'monitor_signal_no',
              size: 14,
              color: IconTheme.of(context).color,
              applyColorFilter: true,
            ),
          ),
        ),
      );
    }
    return Tooltip(
      message: loggedIn ? '查看拓竹云端任务历史' : '未登录拓竹云账号',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs + 2,
          ),
          decoration: BoxDecoration(
            color: loggedIn
                ? AppColors.info.withValues(alpha: 0.12)
                : (isDark
                      ? AppColors.surfaceVariantDark
                      : AppColors.surfaceVariant),
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            border: Border.all(
              color: loggedIn
                  ? AppColors.info.withValues(alpha: 0.3)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              BambuIcon(
                name: loggedIn ? 'monitor_upgrade_online' : 'monitor_signal_no',
                size: 14,
                color: color,
                applyColorFilter: true,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '云端历史',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态分布卡片：横向堆叠条形图 + 图例。
class _StatusDistributionCard extends StatelessWidget {
  final List<PrintTask> tasks;
  final PrintTaskStatus? selectedStatus;
  final ValueChanged<PrintTaskStatus> onStatusSelected;

  const _StatusDistributionCard({
    required this.tasks,
    required this.selectedStatus,
    required this.onStatusSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final counts = <PrintTaskStatus, int>{
      for (final s in PrintTaskStatus.values) s: 0,
    };
    for (final t in tasks) {
      counts[t.status] = counts[t.status]! + 1;
    }
    final total = tasks.length;
    final activeStatuses = PrintTaskStatus.values
        .where((s) => counts[s]! > 0)
        .toList();

    return OpenStage(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BambuIcon(
                name: 'monitor_item_prediction',
                size: 16,
                color: AppColors.primary,
                applyColorFilter: true,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '状态分布',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                selectedStatus == null
                    ? '共 $total 个任务 · 点击图例筛选'
                    : '已筛选 ${selectedStatus!.label} · 再次点击清除',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                  fontFamily: AppTypography.monoFontFamily,
                  fontFeatures: const [ui.FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppColors.radiusFull),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  for (final s in activeStatuses)
                    Expanded(
                      flex: counts[s]!,
                      child: Tooltip(
                        message: selectedStatus == s
                            ? '清除 ${s.label} 筛选'
                            : '只看 ${s.label} 任务',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onStatusSelected(s),
                          child: ColoredBox(color: _statusColor(s, isDark)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.sm,
            children: [
              for (final s in activeStatuses)
                Tooltip(
                  message: selectedStatus == s ? '清除筛选' : '筛选 ${s.label}',
                  child: GlassButtonsTheme.enabledOf(context)
                      ? Semantics(
                          selected: selectedStatus == s,
                          child: AppGlassButton(
                            key: ValueKey('history-status-filter-${s.name}'),
                            label: '${s.label} ${counts[s]}',
                            onPressed: () => onStatusSelected(s),
                            variant: selectedStatus == s
                                ? AppGlassButtonVariant.primary
                                : AppGlassButtonVariant.quiet,
                            tint: _statusColor(s, isDark),
                            compact: true,
                            minimumSize: const Size(0, 26),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            child: Text(
                              '${s.label} ${counts[s]}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontFeatures: [ui.FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        )
                      : MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            key: ValueKey('history-status-filter-${s.name}'),
                            onTap: () => onStatusSelected(s),
                            child: AnimatedContainer(
                              duration: ExperienceTokens.hoverDuration,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: selectedStatus == s
                                    ? _statusColor(
                                        s,
                                        isDark,
                                      ).withValues(alpha: 0.12)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(
                                  AppColors.radiusFull,
                                ),
                                border: Border.all(
                                  color: selectedStatus == s
                                      ? _statusColor(
                                          s,
                                          isDark,
                                        ).withValues(alpha: 0.42)
                                      : Colors.transparent,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: _statusColor(s, isDark),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.xs),
                                  Text(
                                    '${s.label} ${counts[s]}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isDark
                                          ? AppColors.textSecondaryDark
                                          : AppColors.textSecondary,
                                      fontFamily: AppTypography.monoFontFamily,
                                      fontFeatures: const [
                                        ui.FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '${(counts[s]! / total * 100).toStringAsFixed(0)}%',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: isDark
                                          ? AppColors.textTertiaryDark
                                          : AppColors.textTertiary,
                                      fontFamily: AppTypography.monoFontFamily,
                                      fontFeatures: const [
                                        ui.FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 单日分组：小标题 + 条数徽章 + 任务卡片列表。
class _DaySection extends StatelessWidget {
  final String label;
  final List<PrintTask> tasks;

  const _DaySection({required this.label, required this.tasks});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.xs,
          AppSpacing.xl,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                AppChip(
                  variant: AppChipVariant.selected,
                  label: '${tasks.length}',
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm + 2),
            for (final t in tasks)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm + 2),
                child: _TaskCard(task: t),
              ),
          ],
        ),
      ),
    );
  }
}

/// 单条打印任务卡片。
///
/// 通过 autoDispose family provider 查关联打印机/耗材信息。
/// 处理 printerId/consumableId 为 null 的情况（外键 setNull 后的兜底）。
class _TaskCard extends ConsumerWidget {
  final PrintTask task;
  const _TaskCard({required this.task});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final printerId = task.printerId;
    final consumableId = task.consumableId;

    final printerAsync = printerId == null
        ? const AsyncValue<Printer?>.data(null)
        : ref.watch(_printerByIdProvider(printerId));
    final consumableAsync = consumableId == null
        ? const AsyncValue<Consumable?>.data(null)
        : ref.watch(_consumableByIdProvider(consumableId));

    final printer = printerAsync.maybeWhen(data: (p) => p, orElse: () => null);
    final consumable = consumableAsync.maybeWhen(
      data: (c) => c,
      orElse: () => null,
    );
    final printerLoading = printerId != null && !printerAsync.hasValue;
    final consumableLoading = consumableId != null && !consumableAsync.hasValue;

    final color = consumable?.colorHex != null
        ? ColorUtils.fromHex(consumable!.colorHex)
        : null;

    final printerText = printerId == null
        ? null
        : printerLoading
        ? '加载中…'
        : printer == null
        ? '已删除的打印机'
        : (printer.name?.isNotEmpty == true ? printer.name! : printer.model);
    final consumableText = consumableId == null
        ? null
        : consumableLoading
        ? '加载中…'
        : consumable == null
        ? '已删除的耗材'
        : (consumable.colorName?.isNotEmpty == true
              ? consumable.colorName!
              : consumable.colorHex);

    // 预估 vs 实际偏差
    final hasEst = task.estimatedGrams > 0;
    final dev = hasEst
        ? (task.actualGrams - task.estimatedGrams) / task.estimatedGrams * 100
        : 0.0;
    final devText = hasEst
        ? '${dev >= 0 ? '+' : ''}${dev.toStringAsFixed(0)}%'
        : '—';
    final devOversize = hasEst && dev.abs() > 10;

    // 时间 / 耗时 / 进度
    final startText = task.startedAt == null
        ? '—'
        : DateFormat('HH:mm').format(task.startedAt!);
    final durText = _durationText(task.elapsedSeconds);

    final tertiaryColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;
    final monoDataStyle = TextStyle(
      fontSize: 11,
      color: tertiaryColor,
      fontFamily: AppTypography.monoFontFamily,
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );

    return TactileLift(
      onTap: () => showPrintTaskDetailSheet(context, task: task, ref: ref),
      child: Container(
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
                color:
                    color ??
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
                  // 任务名 + 状态徽章
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          task.taskName,
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
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      AppChip(
                        variant: _statusChipVariant(task.status),
                        label: task.status.label,
                      ),
                    ],
                  ),
                  // 打印机 + 耗材
                  if (printerText != null || consumableText != null) ...[
                    const SizedBox(height: AppSpacing.xs + 2),
                    Text(
                      [
                        printerText,
                        consumableText,
                      ].whereType<String>().join(' · '),
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  // 预估 vs 实际克数 + 偏差
                  Row(
                    children: [
                      Text(
                        '预估 ${GramUtils.formatGrams(task.estimatedGrams)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: tertiaryColor,
                          fontFamily: AppTypography.monoFontFamily,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.xs + 2),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: 12,
                        color: tertiaryColor,
                      ),
                      const SizedBox(width: AppSpacing.xs + 2),
                      Text(
                        '实际 ${GramUtils.formatGrams(task.actualGrams)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary,
                          fontFamily: AppTypography.monoFontFamily,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '偏差 $devText',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: devOversize ? AppColors.danger : tertiaryColor,
                          fontFamily: AppTypography.monoFontFamily,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs + 2),
                  // 开始时间 + 耗时 + 进度
                  Row(
                    children: [
                      Icon(Icons.schedule, size: 12, color: tertiaryColor),
                      const SizedBox(width: 3),
                      Text(startText, style: monoDataStyle),
                      const SizedBox(width: AppSpacing.sm + 2),
                      Icon(
                        Icons.timer_outlined,
                        size: 12,
                        color: tertiaryColor,
                      ),
                      const SizedBox(width: 3),
                      Text(durText, style: monoDataStyle),
                      const SizedBox(width: AppSpacing.sm + 2),
                      Icon(
                        Icons.trending_up_rounded,
                        size: 12,
                        color: tertiaryColor,
                      ),
                      const SizedBox(width: 3),
                      Text('${task.lastMcPercent}%', style: monoDataStyle),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 状态 → AppChip 变体映射。
AppChipVariant _statusChipVariant(PrintTaskStatus s) {
  switch (s) {
    case PrintTaskStatus.finished:
      return AppChipVariant.selected;
    case PrintTaskStatus.failed:
      return AppChipVariant.danger;
    case PrintTaskStatus.cancelled:
      return AppChipVariant.warn;
    case PrintTaskStatus.printing:
      return AppChipVariant.info;
    case PrintTaskStatus.paused:
      return AppChipVariant.default_;
    case PrintTaskStatus.planned:
      return AppChipVariant.default_;
  }
}

/// 状态 → 分布条/图例圆点颜色。
Color _statusColor(PrintTaskStatus s, bool isDark) {
  switch (s) {
    case PrintTaskStatus.finished:
      return AppColors.success;
    case PrintTaskStatus.failed:
      return AppColors.danger;
    case PrintTaskStatus.cancelled:
      return AppColors.warning;
    case PrintTaskStatus.printing:
      return AppColors.info;
    case PrintTaskStatus.paused:
      return isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;
    case PrintTaskStatus.planned:
      return isDark ? AppColors.textTertiaryDark : AppColors.textMuted;
  }
}

/// 秒数 → 耗时文本（如 "1h 23m" / "12m" / "45s"）。
String _durationText(int seconds) {
  if (seconds <= 0) return '—';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m';
  return '${seconds}s';
}
