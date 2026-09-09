import 'dart:async';
import '../../core/theme/glass_button_theme.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/kill_switch_service.dart';
import '../../core/services/product_issue_collector.dart';
import '../../core/services/remote_config_service.dart';
import '../../core/services/telemetry_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/app_version.dart';

import '../../core/services/error_logger.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../data/database/daos/telemetry_event_dao.dart';
import '../../data/database/database.dart';
import '../../providers/database_provider.dart';
import '../../widgets/app_stat_box.dart';
import '../../widgets/app_select.dart';
import '../../widgets/bambu_icon.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/icon_action_button.dart';
import 'bind_sniffer_dialog.dart';

/// 诊断中心页面。
///
/// 任务书 11.5 要求三个页签：
/// - 错误日志：保留现有能力。
/// - 运行指标：成功率、延迟、连接稳定性、同步新鲜度，支持时间范围和刷新。
/// - 隐私与导出：明确本地保存、列出不会导出的敏感字段，导出脱敏诊断包。
class DiagnosticsScreen extends ConsumerStatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  ConsumerState<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

enum _DiagnosticsTab { logs, metrics, privacy }

class _DiagnosticsScreenState extends ConsumerState<DiagnosticsScreen> {
  _DiagnosticsTab _tab = _DiagnosticsTab.logs;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              ExperienceTokens.pageGutter,
              ExperienceTokens.pageGutter,
              ExperienceTokens.pageGutter,
              AppSpacing.sm,
            ),
            child: ExperiencePageHeader(
              title: '健康与因果',
              description: '从问题来源追到影响结果，再保留完整日志用于核对。这里的每个节点都来自本地诊断数据。',
            ),
          ),
          _TabBar(current: _tab, onChanged: (t) => setState(() => _tab = t)),
          Expanded(
            child: switch (_tab) {
              _DiagnosticsTab.logs => const _LogsTab(),
              _DiagnosticsTab.metrics => const _MetricsTab(),
              _DiagnosticsTab.privacy => const _PrivacyTab(),
            },
          ),
        ],
      ),
    );
  }
}

/// 顶部页签栏。
class _TabBar extends StatelessWidget {
  final _DiagnosticsTab current;
  final ValueChanged<_DiagnosticsTab> onChanged;

  const _TabBar({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        ExperienceTokens.pageGutter,
        AppSpacing.xs,
        ExperienceTokens.pageGutter,
        AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _TabChip(
              label: '错误日志',
              icon: 'error',
              selected: current == _DiagnosticsTab.logs,
              onTap: () => onChanged(_DiagnosticsTab.logs),
            ),
            const SizedBox(width: AppSpacing.sm),
            _TabChip(
              label: '运行指标',
              icon: 'monitor_network_wired',
              selected: current == _DiagnosticsTab.metrics,
              onTap: () => onChanged(_DiagnosticsTab.metrics),
            ),
            const SizedBox(width: AppSpacing.sm),
            _TabChip(
              label: '隐私与导出',
              icon: 'info',
              selected: current == _DiagnosticsTab.privacy,
              onTap: () => onChanged(_DiagnosticsTab.privacy),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final String icon;
  final bool selected;
  final VoidCallback onTap;

  const _TabChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : AppColors.textSecondary;
    return Material(
      color: selected
          ? AppColors.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              BambuIcon(
                name: icon,
                size: 14,
                color: color,
                applyColorFilter: true,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppTypography.label.copyWith(
                  color: color,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== 错误日志页签（保留原有功能） =====

class _LogsTab extends ConsumerStatefulWidget {
  const _LogsTab();

  @override
  ConsumerState<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends ConsumerState<_LogsTab> {
  List<ErrorLogEntry> _logs = [];
  ({int error, int warning, int info}) _stats = (error: 0, warning: 0, info: 0);
  bool _loading = true;
  String? _sourceFilter;
  ErrorLevel? _levelFilter;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _loading = true);
    try {
      final logs = await ErrorLogger.query(
        limit: 200,
        sourceFilter: _sourceFilter,
        levelFilter: _levelFilter,
      );
      final stats = await ErrorLogger.getStats();
      if (mounted) {
        setState(() {
          _logs = logs;
          _stats = stats;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _exportLogs() async {
    try {
      final text = await ErrorLogger.exportLogs(limit: 500);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => _ExportDialog(content: text),
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(context, '导出失败：${friendlyError(e)}', error: true);
    }
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空所有日志？'),
        content: const Text('此操作不可恢复，确定清空所有错误日志及本地问题线索？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: glassButtonStyle(
              context,
              TextButton.styleFrom(foregroundColor: AppColors.danger),
              variant: AppGlassButtonVariant.quiet,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ErrorLogger.clearAll();
    await _loadLogs();
    if (mounted) {
      showSnack(context, '已清空所有日志及本地问题线索');
    }
  }

  void _openSniffer() {
    if (!kDebugMode) return;
    showDialog<void>(
      context: context,
      builder: (_) => const BindSnifferDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: _HealthCausalMap(
              logs: _logs,
              stats: _stats,
              selectedSource: _sourceFilter,
              onSelectSource: (source) {
                setState(() {
                  _sourceFilter = _sourceFilter == source ? null : source;
                });
                _loadLogs();
              },
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: _StatsCard(
              stats: _stats,
              totalLogs: _logs.length,
              onRefresh: _loadLogs,
              onExport: _exportLogs,
              onClear: _clearAll,
              onOpenSniffer: _openSniffer,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: _FilterBar(
              sourceFilter: _sourceFilter,
              levelFilter: _levelFilter,
              onSourceChanged: (s) {
                setState(() => _sourceFilter = s);
                _loadLogs();
              },
              onLevelChanged: (l) {
                setState(() => _levelFilter = l);
                _loadLogs();
              },
            ),
          ),
        ),
        if (_loading)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: LoadingState(label: '诊断中…'),
          )
        else if (_logs.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              bambuIconName: 'confirm',
              useGlass: true,
              title: '暂无错误日志',
              subtitle: '应用运行正常',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            sliver: SliverList.separated(
              itemCount: _logs.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) => _LogItem(log: _logs[i]),
            ),
          ),
      ],
    );
  }
}

class _HealthCausalMap extends StatelessWidget {
  const _HealthCausalMap({
    required this.logs,
    required this.stats,
    required this.selectedSource,
    required this.onSelectSource,
  });

  final List<ErrorLogEntry> logs;
  final ({int error, int warning, int info}) stats;
  final String? selectedSource;
  final ValueChanged<String> onSelectSource;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final counts = <String, int>{};
    for (final log in logs) {
      counts[log.source] = (counts[log.source] ?? 0) + 1;
    }
    final sources = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final visibleSources = sources.take(4).toList(growable: false);
    final healthColor = stats.error > 0
        ? AppColors.danger
        : stats.warning > 0
        ? AppColors.warning
        : AppColors.success;
    final healthLabel = stats.error > 0
        ? '需要处理'
        : stats.warning > 0
        ? '保持观察'
        : '运行平稳';

    Widget map() => SizedBox(
      width: 760,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 210,
            child: visibleSources.isEmpty
                ? const _CausalNode(
                    icon: Icons.check_circle_outline_rounded,
                    title: '暂无问题来源',
                    subtitle: '当前筛选没有日志',
                    color: AppColors.success,
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (
                        var index = 0;
                        index < visibleSources.length;
                        index++
                      ) ...[
                        _CausalNode(
                          icon: _sourceIcon(visibleSources[index].key),
                          title: _sourceLabel(visibleSources[index].key),
                          subtitle: '${visibleSources[index].value} 条记录',
                          color: selectedSource == visibleSources[index].key
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          selected: selectedSource == visibleSources[index].key,
                          onTap: () =>
                              onSelectSource(visibleSources[index].key),
                        ),
                        if (index != visibleSources.length - 1)
                          const SizedBox(height: 6),
                      ],
                    ],
                  ),
          ),
          const Expanded(child: _CausalConnector(label: '汇聚')),
          _CausalNode(
            icon: Icons.health_and_safety_rounded,
            title: healthLabel,
            subtitle: '${stats.error} 错误 · ${stats.warning} 警告',
            color: healthColor,
            selected: true,
            width: 180,
          ),
          const Expanded(child: _CausalConnector(label: '影响')),
          SizedBox(
            width: 190,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CausalOutcome(
                  label: '错误',
                  value: stats.error,
                  color: AppColors.danger,
                ),
                const SizedBox(height: 6),
                _CausalOutcome(
                  label: '警告',
                  value: stats.warning,
                  color: AppColors.warning,
                ),
                const SizedBox(height: 6),
                _CausalOutcome(
                  label: '信息',
                  value: stats.info,
                  color: AppColors.info,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return OpenStage(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ExperienceSectionHeading(
            title: '健康因果地图',
            trailing: Text(
              selectedSource == null ? '点击来源可筛选日志' : '再次点击取消筛选',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 760) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: map(),
                );
              }
              return map();
            },
          ),
        ],
      ),
    );
  }

  static String _sourceLabel(String source) => switch (source) {
    'print_task' => '打印任务',
    'ftp' => 'FTP 上传',
    'mqtt' => 'MQTT 连接',
    'cloud_api' => '云 API',
    'gcode_parser' => 'G-code 解析',
    'database' => '本地数据库',
    'flutter_framework' => '界面运行时',
    'isolate' => '后台任务',
    _ => source,
  };

  static IconData _sourceIcon(String source) => switch (source) {
    'print_task' => Icons.print_rounded,
    'ftp' => Icons.upload_file_rounded,
    'mqtt' => Icons.cable_rounded,
    'cloud_api' => Icons.cloud_outlined,
    'gcode_parser' => Icons.code_rounded,
    'database' => Icons.storage_rounded,
    'flutter_framework' => Icons.desktop_windows_rounded,
    'isolate' => Icons.memory_rounded,
    _ => Icons.device_hub_rounded,
  };
}

class _CausalNode extends StatelessWidget {
  const _CausalNode({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.selected = false,
    this.onTap,
    this.width,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TactileLift(
      enabled: onTap != null,
      onTap: onTap,
      maxTilt: 0.012,
      lift: 2,
      child: AnimatedContainer(
        duration: ExperienceTokens.hoverDuration,
        width: width ?? double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.1) : scheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? color : scheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 9,
                    ),
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

class _CausalConnector extends StatelessWidget {
  const _CausalConnector({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 9)),
          Row(
            children: [
              Expanded(child: Divider(color: color, thickness: 1.5)),
              Icon(Icons.chevron_right_rounded, size: 16, color: color),
            ],
          ),
        ],
      ),
    );
  }
}

class _CausalOutcome extends StatelessWidget {
  const _CausalOutcome({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 10),
            ),
          ),
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部统计卡片 + 操作按钮。
class _StatsCard extends StatelessWidget {
  final ({int error, int warning, int info}) stats;
  final int totalLogs;
  final VoidCallback onRefresh;
  final VoidCallback onExport;
  final VoidCallback onClear;
  final VoidCallback onOpenSniffer;

  const _StatsCard({
    required this.stats,
    required this.totalLogs,
    required this.onRefresh,
    required this.onExport,
    required this.onClear,
    required this.onOpenSniffer,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    return OpenStage(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BambuIcon(
                name: 'monitor',
                size: 16,
                color: AppColors.primary,
                applyColorFilter: true,
              ),
              const SizedBox(width: 6),
              Text(
                '错误日志概览',
                style: AppTypography.title.copyWith(
                  fontSize: 14,
                  color: titleColor,
                ),
              ),
              const Spacer(),
              if (kDebugMode)
                IconActionButton(
                  bambuIconName: 'monitor_network_wired',
                  onTap: onOpenSniffer,
                  size: 32,
                  tooltip: 'Bind 流量嗅探器（跨设备绑定研究工具）',
                ),
              IconActionButton(
                bambuIconName: 'refresh_normal',
                onTap: onRefresh,
                size: 32,
                tooltip: '刷新',
              ),
              IconActionButton(
                bambuIconName: 'save',
                onTap: onExport,
                size: 32,
                tooltip: '导出日志',
              ),
              IconActionButton(
                icon: Icons.delete_outline_rounded,
                onTap: onClear,
                color: AppColors.danger,
                size: 32,
                tooltip: '清空',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: AppStatBox(
                  label: '近 7 天错误',
                  value: '${stats.error}',
                  unit: '',
                  bambuIconName: 'error',
                  color: AppColors.danger,
                  useGlass: false,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: AppStatBox(
                  label: '警告',
                  value: '${stats.warning}',
                  unit: '',
                  bambuIconName: 'warning',
                  color: AppColors.warning,
                  useGlass: false,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: AppStatBox(
                  label: '信息',
                  value: '${stats.info}',
                  unit: '',
                  bambuIconName: 'info',
                  color: AppColors.info,
                  useGlass: false,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: AppStatBox(
                  label: '总条数',
                  value: '$totalLogs',
                  unit: '',
                  bambuIconName: 'monitor',
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                  useGlass: false,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 筛选栏。
class _FilterBar extends StatelessWidget {
  final String? sourceFilter;
  final ErrorLevel? levelFilter;
  final ValueChanged<String?> onSourceChanged;
  final ValueChanged<ErrorLevel?> onLevelChanged;

  const _FilterBar({
    required this.sourceFilter,
    required this.levelFilter,
    required this.onSourceChanged,
    required this.onLevelChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _buildDropdown<String?>(
            label: '来源',
            value: sourceFilter,
            items: const [
              DropdownMenuItem(value: null, child: Text('全部来源')),
              DropdownMenuItem(value: 'print_task', child: Text('打印任务')),
              DropdownMenuItem(value: 'ftp', child: Text('FTP 上传')),
              DropdownMenuItem(value: 'mqtt', child: Text('MQTT 连接')),
              DropdownMenuItem(value: 'cloud_api', child: Text('云 API')),
              DropdownMenuItem(value: 'gcode_parser', child: Text('G-code 解析')),
              DropdownMenuItem(value: 'database', child: Text('数据库')),
              DropdownMenuItem(
                value: 'flutter_framework',
                child: Text('Flutter 框架'),
              ),
              DropdownMenuItem(value: 'isolate', child: Text('Isolate')),
            ],
            onChanged: onSourceChanged,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildDropdown<ErrorLevel?>(
            label: '等级',
            value: levelFilter,
            items: const [
              DropdownMenuItem(value: null, child: Text('全部等级')),
              DropdownMenuItem(value: ErrorLevel.error, child: Text('错误')),
              DropdownMenuItem(value: ErrorLevel.warning, child: Text('警告')),
              DropdownMenuItem(value: ErrorLevel.info, child: Text('信息')),
            ],
            onChanged: onLevelChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return AppSelect<T>(
      value: value,
      items: items,
      onChanged: onChanged,
      hint: label,
    );
  }
}

/// 单条日志卡片。
class _LogItem extends StatelessWidget {
  final ErrorLogEntry log;
  const _LogItem({required this.log});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final levelColor = switch (log.level) {
      ErrorLevel.error => AppColors.danger,
      ErrorLevel.warning => AppColors.warning,
      ErrorLevel.info => AppColors.info,
    };

    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: levelColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: levelColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        log.level.code.toUpperCase(),
                        style: AppTypography.label.copyWith(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: levelColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        log.source,
                        style: AppTypography.label.copyWith(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatTime(log.createdAt),
                      style: AppTypography.data.copyWith(
                        fontSize: 10,
                        color: isDark
                            ? AppColors.textTertiaryDark
                            : AppColors.textTertiary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  log.message,
                  style: AppTypography.body.copyWith(
                    fontSize: 12,
                    color: isDark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimary,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                if (log.context != null && log.context!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '上下文：${jsonEncode(log.context)}',
                    style: AppTypography.data.copyWith(
                      fontSize: 10,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    return '$m-$d $hh:$mm:$ss';
  }
}

/// 导出对话框（显示日志内容供用户复制）。
class _ExportDialog extends StatelessWidget {
  final String content;
  const _ExportDialog({required this.content});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(
                    '日志导出',
                    style: AppTypography.title.copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconActionButton(
                    icon: Icons.copy,
                    size: 32,
                    tooltip: '复制到剪贴板',
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: content));
                      if (!context.mounted) return;
                      showSnack(context, '日志已复制到剪贴板');
                    },
                  ),
                  IconActionButton(
                    bambuIconName: 'cross',
                    size: 32,
                    tooltip: '关闭',
                    onTap: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: isDark
                        ? AppColors.surfaceContainerHighDark
                        : AppColors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(AppSpacing.sm),
                    border: Border.all(
                      color: isDark ? AppColors.dividerDark : AppColors.divider,
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      content,
                      style: AppTypography.data.copyWith(
                        fontSize: 11,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== 运行指标页签 =====

/// 时间范围筛选。
enum _MetricTimeRange { hour, day, week }

class _MetricsTab extends ConsumerStatefulWidget {
  const _MetricsTab();

  @override
  ConsumerState<_MetricsTab> createState() => _MetricsTabState();
}

class _MetricsTabState extends ConsumerState<_MetricsTab> {
  _MetricTimeRange _range = _MetricTimeRange.week;
  List<TelemetryAggregateRow> _rows = [];
  Map<String, int> _statusCounts = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dao = ref.read(telemetryEventDaoProvider);
      final since = switch (_range) {
        _MetricTimeRange.hour => DateTime.now().subtract(
          const Duration(hours: 1),
        ),
        _MetricTimeRange.day => DateTime.now().subtract(
          const Duration(days: 1),
        ),
        _MetricTimeRange.week => DateTime.now().subtract(
          const Duration(days: 7),
        ),
      };
      final rows = await dao.aggregateByEvent(since: since);
      final statusCounts = await dao.countByStatus();
      if (mounted) {
        setState(() {
          _rows = rows;
          _statusCounts = statusCounts;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: _MetricsHeader(
              range: _range,
              statusCounts: _statusCounts,
              onRangeChanged: (r) {
                setState(() => _range = r);
                _load();
              },
              onRefresh: _load,
            ),
          ),
        ),
        // 任务书 11.6：UI 必须显示配置来源、最后更新时间和过期状态。
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: _RemoteConfigStatusCard(
              remoteConfig: ref.watch(remoteConfigServiceProvider),
            ),
          ),
        ),
        if (_loading)
          const SliverFillRemaining(child: LoadingState(label: '加载指标中…'))
        else if (_error != null)
          SliverFillRemaining(
            child: _MetricsErrorView(error: _error!, onRetry: _load),
          )
        else if (_rows.isEmpty)
          const SliverFillRemaining(
            child: EmptyState(
              bambuIconName: 'monitor',
              useGlass: true,
              title: '暂无指标数据',
              subtitle: '应用运行事件将在使用过程中逐步采集',
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            sliver: SliverList.separated(
              itemCount: _rows.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (_, i) => _MetricRow(row: _rows[i]),
            ),
          ),
      ],
    );
  }
}

/// 远程配置状态卡片：显示配置来源、最后更新时间和过期状态。
/// 任务书 11.6：无数据时不能假装已同步。
class _RemoteConfigStatusCard extends StatelessWidget {
  final RemoteConfigState remoteConfig;

  const _RemoteConfigStatusCard({required this.remoteConfig});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final source = remoteConfig.source;
    final updatedAt = remoteConfig.updatedAtMillis;
    final stale = remoteConfig.isStale;

    // 源标签映射
    final sourceLabel = switch (source) {
      'built_in' => '内置默认',
      'cached' => '本地缓存',
      'community_server' => '社区服务',
      _ => source,
    };
    final sourceColor = switch (source) {
      'community_server' => AppColors.primary,
      'cached' => stale ? AppColors.warning : AppColors.primary,
      _ => AppColors.textSecondary,
    };

    // 最后更新时间
    final updatedLabel = updatedAt == 0
        ? '从未更新'
        : DateTime.fromMillisecondsSinceEpoch(
            updatedAt,
          ).toLocal().toString().substring(0, 19);

    return GlassCard(
      level: GlassLevel.l1,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BambuIcon(
                name: 'info',
                size: 14,
                color: AppColors.primary,
                applyColorFilter: true,
              ),
              const SizedBox(width: 6),
              Text('远程配置状态', style: AppTypography.title.copyWith(fontSize: 13)),
              const Spacer(),
              if (stale && source != 'built_in')
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '已过期',
                    style: AppTypography.label.copyWith(
                      color: AppColors.warning,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _configItem('来源', sourceLabel, sourceColor, isDark),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _configItem(
                  '最后更新',
                  updatedLabel,
                  stale && source != 'built_in'
                      ? AppColors.warning
                      : (isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary),
                  isDark,
                ),
              ),
            ],
          ),
          if (source == 'built_in') ...[
            const SizedBox(height: 6),
            Text(
              '尚未连接 sohun 云或从未成功拉取远程配置，当前使用内置默认值。',
              style: AppTypography.label.copyWith(
                height: 1.4,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _configItem(
    String label,
    String value,
    Color valueColor,
    bool isDark,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTypography.label.copyWith(
            color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: AppTypography.body.copyWith(
            fontSize: 12,
            color: valueColor,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _MetricsHeader extends StatelessWidget {
  final _MetricTimeRange range;
  final Map<String, int> statusCounts;
  final ValueChanged<_MetricTimeRange> onRangeChanged;
  final VoidCallback onRefresh;

  const _MetricsHeader({
    required this.range,
    required this.statusCounts,
    required this.onRangeChanged,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final pending = statusCounts['pending'] ?? 0;
    final synced = statusCounts['synced'] ?? 0;
    final failed = statusCounts['failed'] ?? 0;
    return GlassCard(
      level: GlassLevel.l1,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BambuIcon(
                name: 'monitor_network_wired',
                size: 16,
                color: AppColors.primary,
                applyColorFilter: true,
              ),
              const SizedBox(width: 6),
              Text('运行指标', style: AppTypography.title.copyWith(fontSize: 14)),
              const Spacer(),
              IconActionButton(
                bambuIconName: 'refresh_normal',
                onTap: onRefresh,
                size: 32,
                tooltip: '刷新',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('时间范围：', style: AppTypography.label),
              const SizedBox(width: 8),
              _rangeChip('最近 1 小时', _MetricTimeRange.hour),
              const SizedBox(width: 6),
              _rangeChip('最近 24 小时', _MetricTimeRange.day),
              const SizedBox(width: 6),
              _rangeChip('最近 7 天', _MetricTimeRange.week),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: AppStatBox(
                  label: '待上传',
                  value: '$pending',
                  unit: '条',
                  bambuIconName: 'info',
                  color: AppColors.warning,
                  useGlass: false,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: AppStatBox(
                  label: '已上传',
                  value: '$synced',
                  unit: '条',
                  bambuIconName: 'confirm',
                  color: AppColors.primary,
                  useGlass: false,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: AppStatBox(
                  label: '上传失败',
                  value: '$failed',
                  unit: '条',
                  bambuIconName: 'error',
                  color: AppColors.danger,
                  useGlass: false,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _rangeChip(String label, _MetricTimeRange value) {
    final selected = range == value;
    final color = selected ? AppColors.primary : AppColors.textSecondary;
    return Material(
      color: selected
          ? AppColors.primary.withValues(alpha: 0.12)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => onRangeChanged(value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            label,
            style: AppTypography.label.copyWith(
              color: color,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final TelemetryAggregateRow row;
  const _MetricRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tertiaryColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;
    return GlassCard(
      level: GlassLevel.l2,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.eventName,
                  style: AppTypography.body.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (row.resultCategory.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '类别：${row.resultCategory}',
                      style: AppTypography.data.copyWith(
                        fontSize: 10,
                        color: tertiaryColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${row.count} 次',
                  style: AppTypography.data.copyWith(
                    fontSize: 12,
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (row.avgDurationMs != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '均值 ${row.avgDurationMs}ms',
                      style: AppTypography.data.copyWith(
                        fontSize: 10,
                        color: tertiaryColor,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              _formatTime(row.lastRecordedAt),
              textAlign: TextAlign.right,
              style: AppTypography.data.copyWith(
                fontSize: 10,
                color: tertiaryColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '$m-$d $hh:$mm';
  }
}

class _MetricsErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _MetricsErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 36, color: AppColors.danger),
          const SizedBox(height: 12),
          Text('指标加载失败', style: AppTypography.title.copyWith(fontSize: 15)),
          const SizedBox(height: 6),
          Text(
            error,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.label,
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

// ===== 隐私与导出页签 =====

class _PrivacyTab extends ConsumerStatefulWidget {
  const _PrivacyTab();

  @override
  ConsumerState<_PrivacyTab> createState() => _PrivacyTabState();
}

class _PrivacyTabState extends ConsumerState<_PrivacyTab> {
  bool _uploadEnabled = false;
  bool _loading = true;
  bool _exporting = false;
  bool _toggling = false;
  bool _clearing = false;
  String? _error;
  int _pendingCount = 0;
  ProductIssueSummary _issueSummary = ProductIssueSummary.empty();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await ref.read(telemetryEventDaoProvider).countPending();
      final issueSummary = await ProductIssueCollector.loadSummary();
      if (mounted) {
        setState(() {
          _uploadEnabled =
              prefs.getBool(TelemetryService.kUploadEnabledKey) ?? false;
          _pendingCount = pending;
          _issueSummary = issueSummary;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _toggleUpload(bool value) async {
    if (_toggling) return;
    setState(() => _toggling = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(TelemetryService.kUploadEnabledKey, value);
      // 任务书 11.5：关闭开关后停止上传并清空未发送队列，
      // 但不删除用户主动保留的本地错误日志（error_logs 表不受影响），
      // 也不删除已 synced/failed 的遥测历史聚合数据。
      if (!value) {
        try {
          await ref.read(telemetryEventDaoProvider).clearPending();
        } catch (e) {
          debugPrint('[Privacy] 关闭开关时清空待发送队列失败: $e');
        }
      }
      final pending = value
          ? _pendingCount
          : await ref.read(telemetryEventDaoProvider).countPending();
      if (mounted) {
        setState(() {
          _uploadEnabled = value;
          _pendingCount = pending;
          _toggling = false;
        });
        showSnack(
          context,
          value ? '已开启匿名诊断上传' : '已关闭匿名诊断上传，待发送队列已清空（本地错误日志与已上传历史保留）',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _toggling = false);
        showSnack(context, '操作失败：${friendlyError(e)}', error: true);
      }
    }
  }

  Future<void> _clearPending() async {
    if (_clearing || _pendingCount == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空待上传队列？'),
        content: const Text(
          '此操作不可恢复，确定清空所有待上传的匿名诊断数据？'
          '本地错误日志和已上传的遥测历史不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: glassButtonStyle(
              context,
              TextButton.styleFrom(foregroundColor: AppColors.danger),
              variant: AppGlassButtonVariant.quiet,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _clearing = true);
    try {
      await ref.read(telemetryEventDaoProvider).clearPending();
      await _load();
      if (mounted) showSnack(context, '已清空待上传队列');
    } catch (e) {
      if (mounted) {
        showSnack(context, '清空失败：${friendlyError(e)}', error: true);
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _exportBundle() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final dao = ref.read(telemetryEventDaoProvider);
      final aggregates = await dao.aggregateByEvent();
      final statusCounts = await dao.countByStatus();
      final telemetrySummary = StringBuffer()
        ..writeln('遥测事件状态：${jsonEncode(statusCounts)}')
        ..writeln('聚合明细：');
      for (final row in aggregates) {
        telemetrySummary.writeln(
          '- ${row.eventName}|${row.resultCategory}: '
          '${row.count} 次，均值 ${row.avgDurationMs ?? '-'} ms',
        );
      }

      // 收集功能开关当前状态
      final killSwitch = ref.read(killSwitchServiceProvider);
      final flags = <String, bool>{
        'community_share': killSwitch.isEnabled('community_share'),
        'auto_schedule': killSwitch.isEnabled('auto_schedule'),
        'rfid_auto_adopt': killSwitch.isEnabled('rfid_auto_adopt'),
        'experiment_auto_enqueue': killSwitch.isEnabled(
          'experiment_auto_enqueue',
        ),
      };
      final remoteConfig = ref.read(remoteConfigServiceProvider.notifier);
      flags['telemetry_upload_enabled'] = _uploadEnabled;
      final communityFeedEnhanced = remoteConfig.getFlag(
        'community_feed_enhanced',
      );
      flags['remote_config_community_feed_enhanced'] =
          communityFeedEnhanced is bool ? communityFeedEnhanced : false;

      final text = await ErrorLogger.exportDiagnosticsBundle(
        appVersion: AppVersion.fullVersion,
        databaseSchemaVersion: AppDatabase.kSchemaVersion,
        featureFlags: flags,
        telemetrySummary: telemetrySummary.toString(),
        productIssueSummary: await ProductIssueCollector.exportSummary(),
      );
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => _ExportDialog(content: text),
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(context, '导出失败：${friendlyError(e)}', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: LoadingState(label: '加载中…'));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '加载失败：$_error',
                style: AppTypography.body.copyWith(color: AppColors.danger),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.md),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xs,
        AppSpacing.xl,
        AppSpacing.xxxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassCard(
            level: GlassLevel.l1,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BambuIcon(
                      name: 'info',
                      size: 16,
                      color: AppColors.primary,
                      applyColorFilter: true,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      '隐私与数据本地保存',
                      style: AppTypography.title.copyWith(fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  '错误日志、运行指标、打印结果、耗材轨迹、故障记录和摄像头链路'
                  '诊断默认仅保存在本地，不会自动上传。设备诊断上传默认关闭，'
                  '需要你明确开启后，才向 sohun 云上传诊断事件（含打印机序列号、'
                  '型号与摄像头链路上下文，用于定位具体设备）。',
                  style: AppTypography.body.copyWith(fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  '以下字段既不会进入诊断包导出，也不会进入设备诊断上传'
                  '（账号注册按账号页说明单独处理）：',
                  style: AppTypography.label.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                const Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    _ForbiddenChip('访问令牌 (access token)'),
                    _ForbiddenChip('刷新令牌 (refresh token)'),
                    _ForbiddenChip('密码'),
                    _ForbiddenChip('局域网访问码 (LAN access code)'),
                    _ForbiddenChip('IP 地址'),
                    _ForbiddenChip('邮箱'),
                    _ForbiddenChip('料盘 UUID (trayUuid)'),
                    _ForbiddenChip('完整文件路径'),
                    _ForbiddenChip('G-code 内容'),
                    _ForbiddenChip('用户本地备注'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _IssueSummaryCard(summary: _issueSummary, onRefresh: _load),
          const SizedBox(height: AppSpacing.md),
          GlassCard(
            level: GlassLevel.l1,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '设备诊断上传',
                  style: AppTypography.title.copyWith(fontSize: 14),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '开启后将向 sohun 云上传崩溃、升级结果、设备兼容、摄像头链路'
                  '与首次使用等诊断事件，并携带打印机序列号、型号与组件指纹以定位'
                  '具体设备。访问令牌、LAN access code、TTCode、签名值、邮箱、IP、'
                  '完整路径与料盘 UUID 在任何情况下都不会上传。云服务不可用时不会'
                  '发送；本开关默认关闭。',
                  style: AppTypography.label.copyWith(height: 1.5),
                ),
                const SizedBox(height: AppSpacing.md),
                SwitchListTile(
                  value: _uploadEnabled,
                  onChanged: _toggling ? null : _toggleUpload,
                  title: Text(
                    '允许设备诊断数据上传（含设备标识）',
                    style: AppTypography.body.copyWith(fontSize: 13),
                  ),
                  subtitle: Text(
                    _uploadEnabled ? '已开启' : '默认关闭',
                    style: AppTypography.label,
                  ),
                  activeThumbColor: AppColors.primary,
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: AppStatBox(
                        label: '待上传事件',
                        value: '$_pendingCount',
                        unit: '条',
                        bambuIconName: 'info',
                        color: _pendingCount > 0
                            ? AppColors.warning
                            : AppColors.textSecondary,
                        useGlass: false,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    OutlinedButton.icon(
                      onPressed: (_clearing || _pendingCount == 0)
                          ? null
                          : _clearPending,
                      icon: _clearing
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_outline, size: 16),
                      label: Text(_clearing ? '清空中…' : '清空待发送队列'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          GlassCard(
            level: GlassLevel.l1,
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '导出诊断包',
                  style: AppTypography.title.copyWith(fontSize: 14),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  '生成包含应用版本、数据库 schema、功能开关、指标汇总、本地问题线索和'
                  '脱敏错误日志的完整诊断包。导出前会再次扫描全部文本，确保不包含敏感'
                  '信息。可复制后发送给开发者协助排查问题。',
                  style: AppTypography.label.copyWith(height: 1.5),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _exporting ? null : _exportBundle,
                        icon: _exporting
                            ? const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download_outlined, size: 16),
                        label: Text(_exporting ? '生成中…' : '生成脱敏诊断包'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IssueSummaryCard extends StatelessWidget {
  const _IssueSummaryCard({required this.summary, required this.onRefresh});

  final ProductIssueSummary summary;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      level: GlassLevel.l1,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BambuIcon(
                name: 'monitor',
                size: 16,
                color: AppColors.primary,
                applyColorFilter: true,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('本地问题线索', style: AppTypography.title.copyWith(fontSize: 14)),
              const Spacer(),
              Text('最近 30 天 · ${summary.total} 条', style: AppTypography.label),
              const SizedBox(width: AppSpacing.sm),
              IconActionButton(
                bambuIconName: 'refresh_normal',
                onTap: onRefresh,
                size: 30,
                tooltip: '刷新问题线索',
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '自动归类崩溃、升级、设备兼容和首次使用结果。内容仅保存在本机，'
            '不会记录账号、序列号、IP、访问码或完整路径；你主动生成诊断包时才会导出。',
            style: AppTypography.label.copyWith(height: 1.5),
          ),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 720 ? 4 : 2;
              final width =
                  (constraints.maxWidth - AppSpacing.sm * (columns - 1)) /
                  columns;
              return Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final category in ProductIssueCategory.values)
                    SizedBox(
                      width: width,
                      child: _IssueCountTile(
                        category: category,
                        count: summary.counts[category] ?? 0,
                        lastSeen: summary.lastSeen[category],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _IssueCountTile extends StatelessWidget {
  const _IssueCountTile({
    required this.category,
    required this.count,
    required this.lastSeen,
  });

  final ProductIssueCategory category;
  final int count;
  final DateTime? lastSeen;

  @override
  Widget build(BuildContext context) {
    final color = switch (category) {
      ProductIssueCategory.crash => AppColors.danger,
      ProductIssueCategory.upgrade => AppColors.primary,
      ProductIssueCategory.deviceCompatibility => AppColors.warning,
      ProductIssueCategory.firstUse => AppColors.success,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.label,
                  style: AppTypography.label.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  lastSeen == null
                      ? '暂无记录'
                      : '最近 ${_formatIssueTime(lastSeen!)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.label.copyWith(fontSize: 10),
                ),
              ],
            ),
          ),
          Text(
            '$count',
            style: AppTypography.data.copyWith(
              color: color,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  String _formatIssueTime(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }
}

class _ForbiddenChip extends StatelessWidget {
  final String label;
  const _ForbiddenChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: AppTypography.label.copyWith(
          fontSize: 10,
          color: AppColors.danger,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
