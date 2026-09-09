import 'package:flutter/material.dart';
import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../data/external/printer/bambu_cloud_models.dart';
import '../../providers/bambu_cloud_provider.dart';
import '../../providers/bambu_cloud_tasks_provider.dart';
import '../../widgets/app_button.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/glass_card.dart';
import '../settings/cloud_login_dialog.dart';

/// 云端任务筛选器。
enum _CloudTaskFilter { all, success, failed, cancelled, active }

/// 拓竹云端任务历史对话框。
///
/// 显示当前活跃账号下拓竹云端的任务历史，每条任务含：
/// - 任务标题
/// - 设备名 / 设备型号
/// - 起止时间 / 耗时
/// - 实际耗材克数 + AMS 颜色映射
/// - 状态（成功/失败/取消）
///
/// 与本地打印历史不同：
/// - 本地记录：本软件发起的任务，耗材扣减的依据
/// - 云端记录：所有任务（含打印机屏幕启动、其他客户端发起），更完整
///
/// 入口：打印历史页面顶部 "云端历史" 按钮。
class CloudTaskHistoryDialog extends ConsumerStatefulWidget {
  const CloudTaskHistoryDialog({super.key});

  /// 打开对话框。
  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => const CloudTaskHistoryDialog(),
    );
  }

  @override
  ConsumerState<CloudTaskHistoryDialog> createState() =>
      _CloudTaskHistoryDialogState();
}

class _CloudTaskHistoryDialogState
    extends ConsumerState<CloudTaskHistoryDialog> {
  _CloudTaskFilter _filter = _CloudTaskFilter.all;

  /// 按当前筛选条件过滤任务列表。
  List<BambuCloudTask> _applyFilter(
    List<BambuCloudTask> tasks,
    _CloudTaskFilter filter,
  ) {
    switch (filter) {
      case _CloudTaskFilter.all:
        return tasks;
      case _CloudTaskFilter.success:
        return tasks.where((t) => t.status == '4').toList();
      case _CloudTaskFilter.failed:
        return tasks.where((t) => t.status == '5').toList();
      case _CloudTaskFilter.cancelled:
        return tasks.where((t) => t.status == '6').toList();
      case _CloudTaskFilter.active:
        return tasks
            .where((t) => const ['0', '1', '2', '3'].contains(t.status))
            .toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cloudState = ref.watch(bambuCloudProvider);
    final tasksAsync = ref.watch(bambuCloudTasksProvider);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        child: GlassCard(
          level: GlassLevel.l3,
          blur: 42,
          boxShadow: isDark ? AppColors.shadow4Dark : AppColors.shadow4,
          borderRadius: BorderRadius.circular(AppColors.radiusXl),
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                isLoggedIn: cloudState.session != null,
                onRefresh: () => ref.invalidate(bambuCloudTasksProvider),
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: AppSpacing.md),
              tasksAsync.whenData((tasks) {
                    if (cloudState.session == null || tasks.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _StatsOverview(tasks: tasks),
                        const SizedBox(height: AppSpacing.sm),
                        _FilterBar(
                          filter: _filter,
                          onChanged: (f) => setState(() => _filter = f),
                          tasks: tasks,
                        ),
                        const SizedBox(height: AppSpacing.md),
                      ],
                    );
                  }).valueOrNull ??
                  const SizedBox.shrink(),
              Flexible(
                fit: FlexFit.loose,
                child: tasksAsync.when(
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(40),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (err, _) => _ErrorView(
                    message: err.toString().replaceFirst(
                      'BambuCloudException: ',
                      '',
                    ),
                    onRetry: () => ref.invalidate(bambuCloudTasksProvider),
                  ),
                  data: (tasks) {
                    if (cloudState.session == null) {
                      return const _LoginPrompt();
                    }
                    if (tasks.isEmpty) {
                      return const EmptyState(
                        icon: Icons.cloud_off_outlined,
                        title: '云端没有打印任务',
                        subtitle: '使用打印机或发送任务后会在此显示',
                      );
                    }
                    final filtered = _applyFilter(tasks, _filter);
                    if (filtered.isEmpty) {
                      return const EmptyState(
                        icon: Icons.filter_alt_off_outlined,
                        title: '当前筛选无结果',
                        subtitle: '试试切换到"全部"',
                      );
                    }
                    return _TaskList(tasks: filtered);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 标题栏。
class _Header extends StatelessWidget {
  final bool isLoggedIn;
  final VoidCallback onRefresh;
  final VoidCallback onClose;
  const _Header({
    required this.isLoggedIn,
    required this.onRefresh,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.infoContainer,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
          child: const Icon(
            Icons.cloud_done_rounded,
            size: 20,
            color: AppColors.info,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '云端任务历史',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.2,
                  color: isDark
                      ? AppColors.textPrimaryDark
                      : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                isLoggedIn ? '来自拓竹云的真实打印记录' : '需要登录拓竹账号后查看',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.refresh_rounded, size: 18),
          tooltip: '刷新',
          onPressed: onRefresh,
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, size: 18),
          onPressed: onClose,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}

/// 统计概览：总任务 / 成功率 / 失败数 / 总耗材。
class _StatsOverview extends StatelessWidget {
  final List<BambuCloudTask> tasks;
  const _StatsOverview({required this.tasks});

  @override
  Widget build(BuildContext context) {
    final total = tasks.length;
    final success = tasks.where((t) => t.status == '4').length;
    final failed = tasks.where((t) => t.status == '5').length;
    final totalWeight = tasks.fold<double>(0, (sum, t) => sum + t.weight);
    final successRate = total > 0 ? success / total : 0.0;

    return Row(
      children: [
        Expanded(
          child: _StatChip(
            label: '总任务',
            value: '$total',
            color: AppColors.info,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _StatChip(
            label: '成功率',
            value: '${(successRate * 100).toStringAsFixed(0)}%',
            color: AppColors.success,
            highlight: true,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _StatChip(
            label: '失败',
            value: '$failed',
            color: AppColors.danger,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _StatChip(
            label: '总耗材',
            value:
                '${totalWeight.toStringAsFixed(totalWeight >= 100 ? 0 : 1)} g',
            color: AppColors.primary,
          ),
        ),
      ],
    );
  }
}

/// 单个统计块。
class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool highlight;

  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: highlight
            ? color.withValues(alpha: 0.08)
            : (isDark
                  ? AppColors.surfaceVariantDark.withValues(alpha: 0.4)
                  : AppColors.surfaceVariant.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: highlight
            ? Border.all(color: color.withValues(alpha: 0.2))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: highlight
                  ? color
                  : (isDark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 筛选栏：全部 / 进行中 / 成功 / 失败 / 取消，每项带计数。
class _FilterBar extends StatelessWidget {
  final _CloudTaskFilter filter;
  final ValueChanged<_CloudTaskFilter> onChanged;
  final List<BambuCloudTask> tasks;

  const _FilterBar({
    required this.filter,
    required this.onChanged,
    required this.tasks,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final counts = <_CloudTaskFilter, int>{
      _CloudTaskFilter.all: tasks.length,
      _CloudTaskFilter.active: tasks
          .where((t) => const ['0', '1', '2', '3'].contains(t.status))
          .length,
      _CloudTaskFilter.success: tasks.where((t) => t.status == '4').length,
      _CloudTaskFilter.failed: tasks.where((t) => t.status == '5').length,
      _CloudTaskFilter.cancelled: tasks.where((t) => t.status == '6').length,
    };

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: _CloudTaskFilter.values.map((f) {
        final selected = f == filter;
        final count = counts[f] ?? 0;
        final label = switch (f) {
          _CloudTaskFilter.all => '全部',
          _CloudTaskFilter.active => '进行中',
          _CloudTaskFilter.success => '成功',
          _CloudTaskFilter.failed => '失败',
          _CloudTaskFilter.cancelled => '取消',
        };
        if (GlassButtonsTheme.enabledOf(context)) {
          return Semantics(
            selected: selected,
            child: AppGlassButton(
              label: '$label ($count)',
              onPressed: () => onChanged(f),
              variant: selected
                  ? AppGlassButtonVariant.primary
                  : AppGlassButtonVariant.quiet,
              tint: selected ? AppColors.info : null,
              compact: true,
              minimumSize: const Size(0, 26),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                '$label ($count)',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          );
        }
        return GestureDetector(
          onTap: () => onChanged(f),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: selected
                  ? AppColors.info.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppColors.radiusSm),
              border: Border.all(
                color: selected
                    ? AppColors.info.withValues(alpha: 0.4)
                    : (isDark ? AppColors.outlineDark : AppColors.outline),
                width: 0.8,
              ),
            ),
            child: Text(
              '$label ($count)',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: selected
                    ? AppColors.info
                    : (isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// 错误视图。
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 40,
              color: AppColors.danger,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '拉取失败',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: isDark
                    ? AppColors.textPrimaryDark
                    : AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.md),
            AppButton(
              label: '重试',
              variant: AppButtonVariant.secondary,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// 未登录提示。
class _LoginPrompt extends StatelessWidget {
  const _LoginPrompt();

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.lock_outline,
      title: '请先登录拓竹账号',
      subtitle: '登录后可查看云端所有打印任务记录',
      actionLabel: '去登录',
      onAction: () {
        Navigator.of(context).pop();
        CloudLoginDialog.show(context);
      },
    );
  }
}

/// 任务列表。
class _TaskList extends StatelessWidget {
  final List<BambuCloudTask> tasks;
  const _TaskList({required this.tasks});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: tasks.length,
      separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (_, i) => _TaskItem(task: tasks[i]),
    );
  }
}

/// 单个任务卡片。
class _TaskItem extends StatelessWidget {
  final BambuCloudTask task;
  const _TaskItem({required this.task});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final statusInfo = _parseStatus(task.status);
    final costTimeStr = _formatDuration(task.costTime);
    final timeStr = _formatTimeRange(task.startTime, task.endTime);

    return GlassCard(
      level: GlassLevel.l2,
      borderRadius: BorderRadius.circular(AppColors.radiusLg),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态色点
          Container(
            margin: const EdgeInsets.only(top: 4),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusInfo.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 第一行：标题 + 状态徽章
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.title.isNotEmpty ? task.title : '未命名任务',
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
                    ),
                    const SizedBox(width: 8),
                    _StatusBadge(
                      label: statusInfo.label,
                      color: statusInfo.color,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 第二行：设备信息
                Text(
                  task.deviceName.isNotEmpty
                      ? '${task.deviceName} · ${task.deviceModel}'
                      : task.deviceModel,
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                // 第三行：时间 + 耗时
                Text(
                  '$timeStr · $costTimeStr',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark
                        ? AppColors.textTertiaryDark
                        : AppColors.textTertiary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                // 第四行：耗材克数 + AMS 颜色映射（仅当有耗材时）
                if (task.weight > 0 || task.amsFilaments.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  _FilamentRow(task: task),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 解析拓竹 status 字段为 (label, color)。
  _StatusInfo _parseStatus(String status) {
    switch (status) {
      case '4':
        return const _StatusInfo(label: '成功', color: AppColors.success);
      case '5':
        return const _StatusInfo(label: '失败', color: AppColors.danger);
      case '6':
        return const _StatusInfo(label: '取消', color: AppColors.warning);
      case '2':
        return _StatusInfo(label: '打印中', color: AppColors.primary);
      case '3':
        return const _StatusInfo(label: '已暂停', color: AppColors.warning);
      case '0':
      case '1':
        return const _StatusInfo(label: '排队中', color: AppColors.info);
      default:
        return _StatusInfo(
          label: '未知($status)',
          color: AppColors.textSecondary,
        );
    }
  }

  /// 格式化耗时（秒 → "Xh Ym" 或 "Xm Ys"）。
  String _formatDuration(int seconds) {
    if (seconds <= 0) return '未知耗时';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m';
    return '${seconds}s';
  }

  /// 格式化起止时间范围。
  String _formatTimeRange(DateTime? start, DateTime? end) {
    String fmt(DateTime t) {
      final m = t.month.toString().padLeft(2, '0');
      final d = t.day.toString().padLeft(2, '0');
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      return '$m-$d $hh:$mm';
    }

    if (start == null && end == null) return '时间未知';
    if (start == null) return '至 ${fmt(end!)}';
    if (end == null) return '从 ${fmt(start)}';
    return '${fmt(start)} → ${fmt(end)}';
  }
}

/// 状态信息元组。
class _StatusInfo {
  final String label;
  final Color color;
  const _StatusInfo({required this.label, required this.color});
}

/// 状态徽章。
class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppColors.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.8),
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

/// 耗材行：克数 + AMS 颜色色块。
class _FilamentRow extends StatelessWidget {
  final BambuCloudTask task;
  const _FilamentRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Icon(
          Icons.scale_outlined,
          size: 12,
          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
        ),
        const SizedBox(width: 4),
        Text(
          '${task.weight.toStringAsFixed(task.weight >= 10 ? 0 : 1)} g',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
          ),
        ),
        if (task.amsFilaments.isNotEmpty) ...[
          const SizedBox(width: 8),
          ...task.amsFilaments.map(
            (f) => Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Tooltip(
                message:
                    '${f.filamentType} · ${f.filamentId}\n'
                    '${f.weight.toStringAsFixed(1)} g · AMS#${f.ams}',
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _parseColor(f.sourceColor),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isDark ? AppColors.outlineDark : AppColors.outline,
                      width: 0.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 解析拓竹颜色字符串（RRGGBBAA 或 RRGGBB）。
  Color _parseColor(String hex) {
    if (hex.isEmpty) return Colors.grey;
    try {
      String normalized;
      if (hex.length == 8) {
        // 拓竹 RRGGBBAA 格式：取前 6 位 RRGGBB，alpha 默认 FF（不透明）
        normalized = 'FF${hex.substring(0, 6)}';
      } else if (hex.length == 6) {
        normalized = 'FF$hex';
      } else {
        return Colors.grey;
      }
      return Color(int.parse(normalized, radix: 16));
    } catch (_) {
      return Colors.grey;
    }
  }
}
