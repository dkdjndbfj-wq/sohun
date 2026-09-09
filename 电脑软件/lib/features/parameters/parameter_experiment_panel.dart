// 参数实验面板 UI。
//
// 嵌入质量优化页面，展示实验列表、详情、变体、运行和描述性比较结果。
//
// 任务书要求：
// - 列表展示所有实验（按创建时间倒序），点击展开详情。
// - 顶部有"创建实验"按钮。
// - 状态徽章颜色：draft 灰、running 蓝、paused 黄、completed 绿、archived 灰暗、cancelled 红。
// - 操作按钮：start/pause/archive/cancel/delete，防重复提交。
// - 描述性比较文案，禁止"显著/胜出/最佳"。

import '../../core/theme/glass_button_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:intl/intl.dart';

import '../../core/services/parameter_experiment_service.dart';
import '../../core/services/preset_diff_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../data/database/models/experiment_models.dart';
import '../../data/database/models/preset_print_result.dart';
import '../../data/models/print_parameter.dart';
import '../../providers/parameter_preset_provider.dart';
import '../../providers/print_queue_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/experience_ui.dart';
import '../../widgets/glass_card.dart';
import 'preset_compare_dialog.dart';

/// 参数实验面板。
///
/// 嵌入质量优化页面，展示所有参数实验的列表和详情。
/// 支持创建、启动、暂停、归档、取消、删除实验，
/// 以及查看变体、运行和描述性比较结果。
class ParameterExperimentPanel extends ConsumerStatefulWidget {
  const ParameterExperimentPanel({super.key});

  @override
  ConsumerState<ParameterExperimentPanel> createState() =>
      _ParameterExperimentPanelState();
}

class _ParameterExperimentPanelState
    extends ConsumerState<ParameterExperimentPanel> {
  /// 已展开的实验 ID 集合。
  final _expandedIds = <String>{};

  /// 正在执行操作的实验 ID 集合（防重复提交）。
  final _pendingOps = <String>{};

  @override
  Widget build(BuildContext context) {
    final listAsync = ref.watch(experimentsListProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Column(
      children: [
        // 顶部标题栏 + 创建按钮
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.sm,
          ),
          child: ExperiencePageHeader(
            title: '参数实验跑道',
            description: '让 A/B 变体按真实打印运行交替前进，结果只做描述性比较，不用模糊的“最佳”替代你的判断。',
            actions: [_CreateButton(onTap: _showCreateDialog)],
          ),
        ),
        // 实验列表
        Expanded(
          child: listAsync.when(
            data: (experiments) {
              if (experiments.isEmpty) {
                return EmptyState(
                  icon: Icons.science_outlined,
                  useGlass: true,
                  title: '暂无参数实验',
                  subtitle: '创建实验来对比不同参数组合的打印效果。\n支持 A/B 变体交替运行和描述性比较。',
                  actionLabel: '创建实验',
                  onAction: _showCreateDialog,
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.lg,
                ),
                itemCount: experiments.length,
                itemBuilder: (context, index) {
                  final exp = experiments[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _ExperimentCard(
                      experiment: exp,
                      isExpanded: _expandedIds.contains(exp.id),
                      isPending: _pendingOps.contains(exp.id),
                      onToggle: () {
                        setState(() {
                          if (_expandedIds.contains(exp.id)) {
                            _expandedIds.remove(exp.id);
                          } else {
                            _expandedIds.add(exp.id);
                          }
                        });
                      },
                      onAction: (action) => _handleAction(action, exp.id),
                      onQueueRun: (runId, variantLabel) =>
                          _queueRun(exp.id, runId, variantLabel),
                      onLinkResult: (runId, variantLabel) =>
                          _linkResult(exp.id, runId, variantLabel),
                    ),
                  );
                },
              );
            },
            loading: () => const LoadingState(label: '正在加载实验列表…'),
            error: (error, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 48,
                      color: AppColors.danger,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      '加载失败',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '$error',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    TextButton.icon(
                      onPressed: () => ref.invalidate(experimentsListProvider),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 处理实验操作。
  Future<void> _handleAction(String action, String experimentId) async {
    if (action == 'delete') {
      final confirmed = await _confirmDeleteExperiment();
      if (confirmed != true || !mounted) return;
    }

    setState(() => _pendingOps.add(experimentId));
    try {
      final service = ref.read(experimentServiceProvider);
      switch (action) {
        case 'start':
          await service.startExperiment(experimentId);
          break;
        case 'pause':
          await service.pauseExperiment(experimentId);
          break;
        case 'archive':
          await service.archiveExperiment(experimentId);
          break;
        case 'cancel':
          await service.cancelExperiment(experimentId);
          break;
        case 'delete':
          await service.deleteExperimentIfDraft(experimentId);
          // 删除后折叠卡片
          setState(() => _expandedIds.remove(experimentId));
          break;
        case 'plan':
          // 这里只生成本地 A/B 运行清单，不会自动向打印机发送任务。
          // 真正的自动入队仍应由 experiment_auto_enqueue 安全开关保护。
          final count = await service.planRuns(experimentId);
          if (mounted) {
            _showSnackBar(count > 0 ? '已生成 $count 个运行计划' : '运行计划已存在，未重复创建');
          }
          break;
      }
      // 刷新详情和比较数据
      ref.invalidate(experimentDetailProvider(experimentId));
      ref.invalidate(experimentComparisonProvider(experimentId));
    } catch (e) {
      if (mounted) {
        _showSnackBar('操作失败：$e', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _pendingOps.remove(experimentId));
      }
    }
  }

  Future<bool?> _confirmDeleteExperiment() {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除参数实验？'),
        content: const Text('将删除此草稿及其尚未执行的运行清单，此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: glassButtonStyle(
              context,
              FilledButton.styleFrom(backgroundColor: AppColors.danger),
              variant: AppGlassButtonVariant.primary,
            ),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _queueRun(
    String experimentId,
    String runId,
    String variantLabel,
  ) async {
    final printer = ref.read(activePrinterConfigProvider);
    if (printer == null) {
      _showSnackBar('请先选择并连接一台打印机', isError: true);
      return;
    }

    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '打印文件', extensions: ['gcode', '3mf']),
      ],
    );
    if (file == null || !mounted) return;

    setState(() => _pendingOps.add(experimentId));
    try {
      final service = ref.read(experimentServiceProvider);
      final check = await service.prepareRunForQueue(
        runId: runId,
        filePath: file.path,
        printer: printer,
      );
      if (!mounted) return;

      if (!check.canQueue) {
        await _showQueueCheckBlocked(check);
        return;
      }
      final confirmed = await _confirmExperimentQueue(check);
      if (confirmed != true || !mounted) return;

      await ref
          .read(printQueueProvider(printer.serial).notifier)
          .enqueueExperiment(check);
      ref.invalidate(experimentDetailProvider(experimentId));
      ref.invalidate(experimentComparisonProvider(experimentId));
      _showSnackBar('变体 $variantLabel 已加入 ${printer.displayLabel} 的打印队列');
    } catch (error) {
      if (mounted) _showSnackBar('入队失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _pendingOps.remove(experimentId));
    }
  }

  Future<void> _showQueueCheckBlocked(ExperimentQueueCheck check) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('无法加入打印队列'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${check.variantLabel} · ${check.filename}'),
                const SizedBox(height: AppSpacing.md),
                ...check.blockers.map(
                  (reason) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.cancel_outlined,
                          color: AppColors.danger,
                          size: 18,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(child: Text(reason)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<bool?> _confirmExperimentQueue(ExperimentQueueCheck check) {
    final slice = check.slice;
    final material = slice.filaments
        .map((filament) => filament.materialType)
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet()
        .join(' / ');
    final attribution = check.attribution == ResultAttribution.exact
        ? '精确匹配文件哈希与参数应用记录'
        : '手动归因到当前实验快照';
    final facts = <(String, String)>[
      ('实验变体', check.variantLabel),
      ('参数快照', check.presetName),
      ('打印文件', check.filename),
      ('目标打印机', check.printerLabel),
      ('切片机型', slice.printerSettingsId ?? '未知'),
      ('喷嘴', '${slice.nozzleDiameter?.toStringAsFixed(2) ?? '未知'} mm'),
      if (material.isNotEmpty) ('材料', material),
      ('预计耗材', '${slice.totalGrams.toStringAsFixed(1)} g'),
      ('预计时长', slice.formattedDuration),
      (
        '兼容性',
        '${check.compatibility.status.label} · '
            '${check.compatibility.score} 分 · '
            '置信度 ${check.compatibility.confidence}%',
      ),
      ('结果归因', attribution),
    ];

    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认实验打印'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 560),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...facts.map(
                  (fact) => Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: _InfoRow(label: fact.$1, value: fact.$2),
                  ),
                ),
                if (check.warnings.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sm),
                  const Text(
                    '需要确认',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  ...check.warnings.map(
                    (warning) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.warning_amber_rounded,
                            color: AppColors.warning,
                            size: 18,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(child: Text(warning)),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.add_to_queue_rounded, size: 18),
            label: const Text('确认入队'),
          ),
        ],
      ),
    );
  }

  Future<void> _linkResult(
    String experimentId,
    String runId,
    String variantLabel,
  ) async {
    try {
      final service = ref.read(experimentServiceProvider);
      final candidates = await service.getLinkableResults(runId);
      if (!mounted) return;
      if (candidates.isEmpty) {
        _showSnackBar('暂无与变体 $variantLabel 参数快照匹配的打印结果', isError: true);
        return;
      }

      final selected = await showDialog<PresetPrintResult>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('关联变体 $variantLabel 的打印结果'),
          content: SizedBox(
            width: 520,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: candidates.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, index) {
                  final result = candidates[index];
                  final statusLabel = switch (result.technicalStatus) {
                    TechnicalStatus.finished => '已完成',
                    TechnicalStatus.failed => '已失败',
                    TechnicalStatus.cancelled => '已取消',
                  };
                  final facts = <String>[
                    statusLabel,
                    if (result.actualSeconds > 0) '${result.actualSeconds} 秒',
                    if (result.actualGrams > 0)
                      '${result.actualGrams.toStringAsFixed(1)} 克',
                    if (result.rating != null) '${result.rating} 分',
                  ];
                  return ListTile(
                    leading: const Icon(Icons.task_alt_rounded),
                    title: Text('打印任务 #${result.taskId}'),
                    subtitle: Text(
                      '${DateFormat('yyyy-MM-dd HH:mm').format(result.createdAt)}'
                      ' · ${facts.join(' · ')}',
                    ),
                    onTap: () => Navigator.of(dialogContext).pop(result),
                  );
                },
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        ),
      );
      if (selected == null || !mounted) return;

      setState(() => _pendingOps.add(experimentId));
      await service.linkResultToRun(runId: runId, resultId: selected.id);
      ref.invalidate(experimentDetailProvider(experimentId));
      ref.invalidate(experimentComparisonProvider(experimentId));
      _showSnackBar('已关联打印任务 #${selected.taskId}');
    } catch (error) {
      if (mounted) _showSnackBar('关联失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _pendingOps.remove(experimentId));
    }
  }

  /// 显示创建实验对话框。
  void _showCreateDialog() {
    showDialog(
      context: context,
      builder: (context) => const _CreateExperimentDialog(),
    ).then((result) {
      if (result == true && mounted) {
        _showSnackBar('实验创建成功');
      }
    });
  }

  void _showSnackBar(String message, {bool isError = false}) {
    showSnack(
      context,
      message,
      error: isError,
      duration: Duration(seconds: isError ? 4 : 2),
    );
  }
}

// ===== 实验卡片 =====

/// 单个实验卡片，支持展开/折叠。
///
/// 展开时通过 [experimentDetailProvider] 和 [experimentComparisonProvider]
/// 获取详情和比较数据。
class _ExperimentCard extends ConsumerWidget {
  final ParameterExperiment experiment;
  final bool isExpanded;
  final bool isPending;
  final VoidCallback onToggle;
  final void Function(String action) onAction;
  final void Function(String runId, String variantLabel) onQueueRun;
  final void Function(String runId, String variantLabel) onLinkResult;

  const _ExperimentCard({
    required this.experiment,
    required this.isExpanded,
    required this.isPending,
    required this.onToggle,
    required this.onAction,
    required this.onQueueRun,
    required this.onLinkResult,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dateFormat = DateFormat('yyyy-MM-dd HH:mm');

    return GlassCard(
      level: GlassLevel.l2,
      padding: EdgeInsets.zero,
      onTap: onPending ? null : onToggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：名称 + 状态徽章 + 展开/折叠图标
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        experiment.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: isDark
                              ? AppColors.textPrimaryDark
                              : AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          _StatusBadge(status: experiment.status),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            dateFormat.format(experiment.createdAt),
                            style: TextStyle(
                              fontSize: 11,
                              color: isDark
                                  ? AppColors.textTertiaryDark
                                  : AppColors.textTertiary,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          AppChip(
                            label: EvaluationMetric.fromString(
                              experiment.evaluationMetrics,
                            ).label,
                            variant: AppChipVariant.default_,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  isExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary,
                ),
              ],
            ),
          ),
          // 展开内容
          if (isExpanded)
            _ExpandedContent(
              experimentId: experiment.id,
              status: experiment.status,
              isPending: isPending,
              onAction: onAction,
              onQueueRun: onQueueRun,
              onLinkResult: onLinkResult,
            ),
        ],
      ),
    );
  }

  bool get onPending => isPending;
}

/// 展开内容：变体列表、运行列表、比较结果、操作按钮。
class _ExpandedContent extends ConsumerWidget {
  final String experimentId;
  final ExperimentStatus status;
  final bool isPending;
  final void Function(String action) onAction;
  final void Function(String runId, String variantLabel) onQueueRun;
  final void Function(String runId, String variantLabel) onLinkResult;

  const _ExpandedContent({
    required this.experimentId,
    required this.status,
    required this.isPending,
    required this.onAction,
    required this.onQueueRun,
    required this.onLinkResult,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(experimentDetailProvider(experimentId));
    final comparisonAsync = ref.watch(
      experimentComparisonProvider(experimentId),
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return detailAsync.when(
      data: (detail) {
        final variantLabels = <String, String>{
          for (final variant in detail.variants) variant.id: variant.label,
        };
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Divider(
                height: 1,
                color: isDark ? AppColors.dividerDark : AppColors.divider,
              ),
              const SizedBox(height: AppSpacing.md),
              // 目标
              if (detail.experiment.goal.isNotEmpty) ...[
                _InfoRow(label: '目标', value: detail.experiment.goal),
                const SizedBox(height: AppSpacing.sm),
              ],
              // 控制变量
              if (detail.experiment.controlVariables.isNotEmpty) ...[
                _InfoRow(
                  label: '控制变量',
                  value: detail.experiment.controlVariables,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              // 目标重复次数
              _InfoRow(
                label: '目标重复',
                value: '${detail.experiment.targetRepeats} 次',
              ),
              const SizedBox(height: AppSpacing.lg),
              // 变体列表
              _SectionTitle(title: '变体（${detail.variants.length}）'),
              const SizedBox(height: AppSpacing.sm),
              if (detail.variants.isEmpty)
                const _EmptyHint(text: '暂无变体，请在创建时添加或通过服务添加')
              else
                ...detail.variants.map((v) => _VariantRow(variant: v)),
              const SizedBox(height: AppSpacing.lg),
              // 运行列表
              _SectionTitle(title: '运行（${detail.runs.length}）'),
              const SizedBox(height: AppSpacing.sm),
              if (detail.runs.isEmpty)
                const _EmptyHint(text: '暂无运行计划')
              else
                ...detail.runs.map(
                  (run) => _RunRow(
                    run: run,
                    variantLabel: variantLabels[run.variantId],
                    canQueue:
                        !isPending &&
                        status == ExperimentStatus.running &&
                        run.status == RunStatus.pending,
                    canLink:
                        !isPending &&
                        run.resultId == null &&
                        ((status == ExperimentStatus.running ||
                                    status == ExperimentStatus.paused) &&
                                run.status == RunStatus.pending ||
                            status == ExperimentStatus.completed &&
                                run.status.isTerminal),
                    onQueueRun: onQueueRun,
                    onLinkResult: onLinkResult,
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),
              // 比较结果
              const _SectionTitle(title: '结果比较'),
              const SizedBox(height: AppSpacing.sm),
              _ComparisonSection(comparisonAsync: comparisonAsync),
              const SizedBox(height: AppSpacing.lg),
              // 操作按钮
              _ActionButtons(
                status: status,
                isPending: isPending,
                onAction: onAction,
              ),
            ],
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          '详情加载失败：$e',
          style: const TextStyle(fontSize: 12, color: AppColors.danger),
        ),
      ),
    );
  }
}

// ===== 比较结果区块 =====

/// 比较结果展示。
///
/// 任务书要求：
/// - 未达到目标显示"样本未完成"。
/// - 达到目标且数据齐全显示"当前指标领先"（含描述性说明）。
/// - 并列时显示"当前指标并列"。
/// - 永远不出现"显著胜出"。
class _ComparisonSection extends StatelessWidget {
  final AsyncValue<ExperimentComparison> comparisonAsync;

  const _ComparisonSection({required this.comparisonAsync});

  @override
  Widget build(BuildContext context) {
    return comparisonAsync.when(
      data: (comparison) {
        if (comparison.variants.isEmpty) {
          return const _EmptyHint(text: '暂无变体数据');
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 比较结论
            _ComparisonConclusion(comparison: comparison),
            const SizedBox(height: AppSpacing.sm),
            // 各变体指标明细
            ...comparison.variants.map((v) => _VariantMetricsRow(summary: v)),
          ],
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (e, _) => Text(
        '比较加载失败：$e',
        style: const TextStyle(fontSize: 12, color: AppColors.danger),
      ),
    );
  }
}

/// 比较结论徽章。
class _ComparisonConclusion extends StatelessWidget {
  final ExperimentComparison comparison;

  const _ComparisonConclusion({required this.comparison});

  @override
  Widget build(BuildContext context) {
    // 未全部达标 → 样本未完成
    if (!comparison.allMeetTarget) {
      return const AppChip(label: '样本未完成', variant: AppChipVariant.warn);
    }

    // 并列
    if (comparison.isTied) {
      return const AppChip(label: '当前指标并列', variant: AppChipVariant.info);
    }

    // 有领先变体
    if (comparison.leadingVariantId != null &&
        comparison.leadingDescription != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppChip(label: '当前指标领先', variant: AppChipVariant.selected),
          const SizedBox(height: AppSpacing.xs),
          Text(
            comparison.leadingDescription!,
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      );
    }

    // 数据不足（有达标变体但指标值缺失）
    return const AppChip(label: '数据不足，暂无法比较', variant: AppChipVariant.default_);
  }
}

/// 单个变体的指标明细行。
class _VariantMetricsRow extends StatelessWidget {
  final VariantResultSummary summary;

  const _VariantMetricsRow({required this.summary});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 变体标签
          SizedBox(
            width: 32,
            child: Text(
              summary.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          // 指标列表
          Expanded(
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: 2,
              children: [
                _MetricChip(
                  label: '完成',
                  value: '${summary.completedCount}/${summary.totalRuns}',
                ),
                if (summary.completionRate != null)
                  _MetricChip(
                    label: '完成率',
                    value:
                        '${(summary.completionRate! * 100).toStringAsFixed(0)}%',
                  ),
                if (summary.usableRate != null)
                  _MetricChip(
                    label: '可用率',
                    value: '${(summary.usableRate! * 100).toStringAsFixed(0)}%',
                  ),
                if (summary.averageRating != null)
                  _MetricChip(
                    label: '评分',
                    value:
                        '${summary.averageRating!.toStringAsFixed(1)} (${summary.ratingCount}人)',
                  ),
                if (summary.averageActualSeconds != null)
                  _MetricChip(
                    label: '耗时',
                    value:
                        '${summary.averageActualSeconds!.toStringAsFixed(0)}秒'
                        '${summary.stdDevActualSeconds != null ? " ±${summary.stdDevActualSeconds!.toStringAsFixed(0)}" : ""}',
                  ),
                if (summary.averageActualGrams != null)
                  _MetricChip(
                    label: '克数',
                    value:
                        '${summary.averageActualGrams!.toStringAsFixed(1)}克'
                        '${summary.stdDevActualGrams != null ? " ±${summary.stdDevActualGrams!.toStringAsFixed(2)}" : ""}',
                  ),
                if (summary.failedCount > 0)
                  _MetricChip(
                    label: '失败',
                    value: '${summary.failedCount}',
                    color: AppColors.danger,
                  ),
                if (summary.skippedCount > 0)
                  _MetricChip(
                    label: '跳过',
                    value: '${summary.skippedCount}',
                    color: AppColors.warning,
                  ),
              ],
            ),
          ),
          // 达标状态
          Icon(
            summary.meetsTarget
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 14,
            color: summary.meetsTarget
                ? AppColors.success
                : (isDark
                      ? AppColors.textTertiaryDark
                      : AppColors.textTertiary),
          ),
        ],
      ),
    );
  }
}

/// 指标小标签。
class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _MetricChip({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final c =
        color ??
        (isDark ? AppColors.textSecondaryDark : AppColors.textSecondary);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(fontSize: 11, color: c.withValues(alpha: 0.7)),
          ),
          TextSpan(
            text: value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: c,
            ),
          ),
        ],
      ),
    );
  }
}

// ===== 操作按钮 =====

/// 实验操作按钮组。
///
/// 按状态显示可用操作，防重复提交时全部禁用。
class _ActionButtons extends StatelessWidget {
  final ExperimentStatus status;
  final bool isPending;
  final void Function(String action) onAction;

  const _ActionButtons({
    required this.status,
    required this.isPending,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final buttons = <_ActionButtonData>[];

    // 生成运行计划（draft 可用）
    if (status == ExperimentStatus.draft) {
      buttons.add(
        const _ActionButtonData(
          action: 'plan',
          label: '生成计划',
          icon: Icons.list_alt_rounded,
          color: AppColors.info,
        ),
      );
    }

    // 启动（draft/paused 可用）
    if (status.canStart) {
      buttons.add(
        const _ActionButtonData(
          action: 'start',
          label: '启动',
          icon: Icons.play_arrow_rounded,
          color: AppColors.success,
        ),
      );
    }

    // 暂停（running 可用）
    if (status.canPause) {
      buttons.add(
        const _ActionButtonData(
          action: 'pause',
          label: '暂停',
          icon: Icons.pause_rounded,
          color: AppColors.warning,
        ),
      );
    }

    // 取消（running/paused 可用）
    if (status == ExperimentStatus.running ||
        status == ExperimentStatus.paused) {
      buttons.add(
        const _ActionButtonData(
          action: 'cancel',
          label: '取消',
          icon: Icons.stop_circle_outlined,
          color: AppColors.danger,
        ),
      );
    }

    // 归档（completed/cancelled 可用）
    if (status.canArchive) {
      buttons.add(
        const _ActionButtonData(
          action: 'archive',
          label: '归档',
          icon: Icons.archive_outlined,
          color: AppColors.textSecondary,
        ),
      );
    }

    // 删除（仅 draft）
    if (status == ExperimentStatus.draft) {
      buttons.add(
        const _ActionButtonData(
          action: 'delete',
          label: '删除',
          icon: Icons.delete_outline_rounded,
          color: AppColors.danger,
        ),
      );
    }

    if (buttons.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: buttons
          .map(
            (b) => _ActionButton(
              data: b,
              disabled: isPending,
              onTap: () => onAction(b.action),
            ),
          )
          .toList(),
    );
  }
}

/// 操作按钮数据。
class _ActionButtonData {
  final String action;
  final String label;
  final IconData icon;
  final Color color;

  const _ActionButtonData({
    required this.action,
    required this.label,
    required this.icon,
    required this.color,
  });
}

/// 单个操作按钮。
class _ActionButton extends StatelessWidget {
  final _ActionButtonData data;
  final bool disabled;
  final VoidCallback onTap;

  const _ActionButton({
    required this.data,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: disabled ? null : onTap,
      icon: Icon(data.icon, size: 16),
      label: Text(
        data.label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
      style: glassButtonStyle(
        context,
        TextButton.styleFrom(
          foregroundColor: data.color,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.xs,
          ),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        variant: AppGlassButtonVariant.quiet,
      ),
    );
  }
}

// ===== 辅助组件 =====

/// 状态徽章。
class _StatusBadge extends StatelessWidget {
  final ExperimentStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final style = _statusChipStyle(status);
    return AppChip(
      label: _statusLabel(status),
      variant: style.variant,
      dotColor: style.dotColor,
    );
  }

  static String _statusLabel(ExperimentStatus s) {
    return switch (s) {
      ExperimentStatus.draft => '草稿',
      ExperimentStatus.running => '运行中',
      ExperimentStatus.paused => '已暂停',
      ExperimentStatus.completed => '已完成',
      ExperimentStatus.archived => '已归档',
      ExperimentStatus.cancelled => '已取消',
    };
  }

  static ({AppChipVariant variant, Color? dotColor}) _statusChipStyle(
    ExperimentStatus s,
  ) {
    return switch (s) {
      ExperimentStatus.draft => (
        variant: AppChipVariant.dot,
        dotColor: AppColors.textTertiary,
      ),
      ExperimentStatus.running => (
        variant: AppChipVariant.info,
        dotColor: null,
      ),
      ExperimentStatus.paused => (variant: AppChipVariant.warn, dotColor: null),
      ExperimentStatus.completed => (
        variant: AppChipVariant.selected,
        dotColor: null,
      ),
      ExperimentStatus.archived => (
        variant: AppChipVariant.dot,
        dotColor: AppColors.textMuted,
      ),
      ExperimentStatus.cancelled => (
        variant: AppChipVariant.danger,
        dotColor: null,
      ),
    };
  }
}

/// 变体行。
class _VariantRow extends StatelessWidget {
  final ExperimentVariant variant;

  const _VariantRow({required this.variant});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppChip(label: variant.label, variant: AppChipVariant.selected),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (variant.diffSummary.isNotEmpty)
                  Text(
                    variant.diffSummary,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark
                          ? AppColors.textSecondaryDark
                          : AppColors.textSecondary,
                    ),
                  ),
                if (variant.snapshotId != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '快照: ${_truncateId(variant.snapshotId!)}',
                    style: TextStyle(
                      fontSize: 10,
                      color: isDark
                          ? AppColors.textTertiaryDark
                          : AppColors.textTertiary,
                    ),
                  ),
                ],
                if (variant.revision > 1) ...[
                  const SizedBox(height: 2),
                  Text(
                    'revision ${variant.revision}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.warning,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _truncateId(String id) {
    if (id.length <= 12) return id;
    return '${id.substring(0, 8)}…';
  }
}

/// 运行行。
class _RunRow extends StatelessWidget {
  final ExperimentRun run;
  final String? variantLabel;
  final bool canQueue;
  final bool canLink;
  final void Function(String runId, String variantLabel) onQueueRun;
  final void Function(String runId, String variantLabel) onLinkResult;

  const _RunRow({
    required this.run,
    required this.variantLabel,
    required this.canQueue,
    required this.canLink,
    required this.onQueueRun,
    required this.onLinkResult,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusStyle = _runStatusStyle(run.status);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '#${run.runOrder}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isDark
                    ? AppColors.textSecondaryDark
                    : AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          AppChip(label: variantLabel ?? '?', variant: AppChipVariant.selected),
          const SizedBox(width: AppSpacing.xs),
          AppChip(
            label: _runStatusLabel(run.status),
            variant: statusStyle.variant,
            dotColor: statusStyle.dotColor,
          ),
          const Spacer(),
          if (run.taskId != null)
            Text(
              'task ${run.taskId}',
              style: TextStyle(
                fontSize: 10,
                color: isDark
                    ? AppColors.textTertiaryDark
                    : AppColors.textTertiary,
              ),
            )
          else if (canQueue || canLink)
            SizedBox(
              height: 32,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (canQueue)
                    IconButton(
                      onPressed: () => onQueueRun(run.id, variantLabel ?? '?'),
                      tooltip: '选择打印文件并加入队列',
                      icon: const Icon(Icons.add_to_queue_rounded, size: 17),
                      visualDensity: VisualDensity.compact,
                    ),
                  if (canLink)
                    IconButton(
                      onPressed: () =>
                          onLinkResult(run.id, variantLabel ?? '?'),
                      tooltip: '关联已有真实打印结果',
                      icon: const Icon(Icons.link_rounded, size: 17),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _runStatusLabel(RunStatus s) {
    return switch (s) {
      RunStatus.pending => '待执行',
      RunStatus.queued => '已排队',
      RunStatus.printing => '打印中',
      RunStatus.completed => '已完成',
      RunStatus.failed => '已失败',
      RunStatus.cancelled => '已取消',
      RunStatus.skipped => '已跳过',
    };
  }

  static ({AppChipVariant variant, Color? dotColor}) _runStatusStyle(
    RunStatus s,
  ) {
    return switch (s) {
      RunStatus.pending => (
        variant: AppChipVariant.dot,
        dotColor: AppColors.textTertiary,
      ),
      RunStatus.queued => (variant: AppChipVariant.info, dotColor: null),
      RunStatus.printing => (
        variant: AppChipVariant.info,
        dotColor: AppColors.info,
      ),
      RunStatus.completed => (variant: AppChipVariant.selected, dotColor: null),
      RunStatus.failed => (variant: AppChipVariant.danger, dotColor: null),
      RunStatus.cancelled => (
        variant: AppChipVariant.dot,
        dotColor: AppColors.textMuted,
      ),
      RunStatus.skipped => (
        variant: AppChipVariant.dot,
        dotColor: AppColors.textMuted,
      ),
    };
  }
}

/// 信息行（标签 + 值）。
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? AppColors.textTertiaryDark
                  : AppColors.textTertiary,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: isDark
                  ? AppColors.textSecondaryDark
                  : AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 区块标题。
class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      title,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
        letterSpacing: 0.2,
      ),
    );
  }
}

/// 空提示文字。
class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: isDark ? AppColors.textTertiaryDark : AppColors.textTertiary,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// 创建按钮。
class _CreateButton extends StatelessWidget {
  final VoidCallback onTap;

  const _CreateButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.add_rounded, size: 18),
      label: const Text(
        '创建实验',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      style: glassButtonStyle(
        context,
        TextButton.styleFrom(
          foregroundColor: AppColors.primary,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
        ),
        variant: AppGlassButtonVariant.quiet,
      ),
    );
  }
}

// ===== 创建实验对话框 =====

/// 创建实验对话框。
///
/// 表单字段：名称、目标、A/B 参数、目标重复次数、控制变量和评价指标。
class _CreateExperimentDialog extends ConsumerStatefulWidget {
  const _CreateExperimentDialog();

  @override
  ConsumerState<_CreateExperimentDialog> createState() =>
      _CreateExperimentDialogState();
}

class _CreateExperimentDialogState
    extends ConsumerState<_CreateExperimentDialog> {
  final _nameController = TextEditingController();
  final _goalController = TextEditingController();
  final _repeatsController = TextEditingController(text: '3');
  final _controlVarsController = TextEditingController();
  String? _baselinePresetId;
  String? _candidatePresetId;
  EvaluationMetric _metric = EvaluationMetric.usableRate;
  bool _submitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _goalController.dispose();
    _repeatsController.dispose();
    _controlVarsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showSnack(context, '请输入实验名称', error: true);
      return;
    }

    final repeats = int.tryParse(_repeatsController.text.trim()) ?? 3;
    if (repeats < 1) {
      showSnack(context, '目标重复次数必须大于 0', error: true);
      return;
    }

    final presets = ref.read(parameterPresetProvider);
    final baseline = _findPreset(presets, _baselinePresetId);
    final candidate = _findPreset(presets, _candidatePresetId);
    if (baseline == null || candidate == null) {
      _showValidationError('请选择参数 A 和参数 B');
      return;
    }
    if (baseline.id == candidate.id) {
      _showValidationError('参数 A 和参数 B 不能是同一个预设');
      return;
    }

    setState(() => _submitting = true);
    try {
      final service = ref.read(experimentServiceProvider);
      await service.createExperimentFromPresets(
        name: name,
        baseline: baseline,
        candidate: candidate,
        goal: _goalController.text.trim(),
        controlVariables: _controlVarsController.text.trim(),
        evaluationMetrics: _metric.value,
        targetRepeats: repeats,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        showSnack(context, '创建失败：$e', error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  PrintParameterPreset? _findPreset(
    List<PrintParameterPreset> presets,
    String? id,
  ) {
    if (id == null) return null;
    for (final preset in presets) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  void _showValidationError(String message) {
    showSnack(context, message, error: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final presets = ref.watch(parameterPresetProvider);
    final baseline = _findPreset(presets, _baselinePresetId);
    final candidate = _findPreset(presets, _candidatePresetId);
    final diffs = baseline == null || candidate == null
        ? const <PresetParameterDiff>[]
        : PresetDiffService.comparePresets(baseline, candidate);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.science_outlined, size: 22, color: AppColors.primary),
          const SizedBox(width: AppSpacing.sm),
          const Text('创建参数实验'),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _DialogField(
                label: '实验名称',
                controller: _nameController,
                hint: '如：层高 0.2 vs 0.16 对比',
              ),
              const SizedBox(height: AppSpacing.md),
              _DialogField(
                label: '实验目标',
                controller: _goalController,
                hint: '描述要观察的指标（可选）',
                maxLines: 2,
              ),
              const SizedBox(height: AppSpacing.md),
              _DialogField(
                label: '目标重复次数',
                controller: _repeatsController,
                hint: '3',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: AppSpacing.md),
              _PresetSelector(
                label: '参数 A（基准）',
                value: _baselinePresetId,
                presets: presets,
                onChanged: (value) => setState(() => _baselinePresetId = value),
              ),
              const SizedBox(height: AppSpacing.md),
              _PresetSelector(
                label: '参数 B（候选）',
                value: _candidatePresetId,
                presets: presets,
                onChanged: (value) =>
                    setState(() => _candidatePresetId = value),
              ),
              if (baseline != null && candidate != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        diffs.isEmpty ? '没有实际参数差异' : '检测到 ${diffs.length} 项差异',
                        style: TextStyle(
                          fontSize: 11,
                          color: diffs.isEmpty
                              ? AppColors.danger
                              : (isDark
                                    ? AppColors.textTertiaryDark
                                    : AppColors.textTertiary),
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => PresetCompareDialog(
                          presetAName: baseline.name,
                          presetAValues: PresetDiffService.flatten(baseline),
                          presetBName: candidate.name,
                          presetBValues: PresetDiffService.flatten(candidate),
                        ),
                      ),
                      icon: const Icon(Icons.compare_arrows_rounded, size: 16),
                      label: const Text('查看差异'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              _DialogField(
                label: '控制变量说明',
                controller: _controlVarsController,
                hint: '如：相同打印机/材料/温度（可选）',
                maxLines: 2,
              ),
              const SizedBox(height: AppSpacing.md),
              // 评价指标选择
              Text(
                '评价指标',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              DropdownButtonFormField<EvaluationMetric>(
                initialValue: _metric,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  isDense: true,
                ),
                items: EvaluationMetric.values.map((m) {
                  return DropdownMenuItem(
                    value: m,
                    child: Text(m.label, style: const TextStyle(fontSize: 13)),
                  );
                }).toList(),
                onChanged: (v) {
                  if (v != null) {
                    setState(() => _metric = v);
                  }
                },
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '实验创建后可添加变体并生成运行计划',
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
      actions: [
        TextButton(
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? Builder(
                  builder: (context) => SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: GlassButtonsTheme.enabledOf(context)
                          ? IconTheme.of(context).color
                          : Colors.white,
                    ),
                  ),
                )
              : const Text('创建'),
        ),
      ],
    );
  }
}

class _PresetSelector extends StatelessWidget {
  final String label;
  final String? value;
  final List<PrintParameterPreset> presets;
  final ValueChanged<String?> onChanged;

  const _PresetSelector({
    required this.label,
    required this.value,
    required this.presets,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: presets
          .map(
            (preset) => DropdownMenuItem(
              value: preset.id,
              child: Text(preset.name, overflow: TextOverflow.ellipsis),
            ),
          )
          .toList(growable: false),
      onChanged: presets.isEmpty ? null : onChanged,
    );
  }
}

/// 对话框表单字段。
class _DialogField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final TextInputType? keyboardType;

  const _DialogField({
    required this.label,
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isDark
                ? AppColors.textSecondaryDark
                : AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            isDense: true,
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ],
    );
  }
}
