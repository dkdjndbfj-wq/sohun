// 打印任务详情底部弹窗。
//
// 任务书 Phase D 要求：
// - 在打印历史详情中提供"补充打印结果"，让用户选择
//   "成功 / 有瑕疵但可用 / 成品失败"，并填写可选评分、粘附、质量和失败分类。
// - 打印历史详情显示关联参数名称、revision 和"查看参数快照"。
// - 对未关联任务提供搜索式参数选择器；用户确认后才建立关联。
// - 用户补充评分只能更新主观字段，不能改写自动采集的任务事实。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/services/kill_switch_service.dart';
import '../../core/utils/gram_utils.dart';
import '../../data/database/daos/preset_result_dao.dart';
import '../../data/database/models/print_task.dart';
import '../../providers/database_provider.dart';
import '../../providers/community_share_provider.dart';
import '../../widgets/app_chip.dart';
import '../../widgets/icon_action_button.dart';
import '../../widgets/confirm_dialog.dart';
import 'print_result_supplement_dialog.dart';

/// 显示打印任务详情底部弹窗。
///
/// 用户可在此查看任务详情、关联参数信息，并补充打印结果评价。
Future<void> showPrintTaskDetailSheet(
  BuildContext context, {
  required PrintTask task,
  required WidgetRef ref,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _TaskDetailSheet(task: task, ref: ref),
  );
}

class _TaskDetailSheet extends ConsumerStatefulWidget {
  final PrintTask task;
  final WidgetRef ref;

  const _TaskDetailSheet({required this.task, required this.ref});

  @override
  ConsumerState<_TaskDetailSheet> createState() => _TaskDetailSheetState();
}

class _TaskDetailSheetState extends ConsumerState<_TaskDetailSheet> {
  PresetPrintResult? _result;
  bool _loading = true;
  bool _sharing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadResult();
  }

  Future<void> _loadResult() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dao = PresetResultDao(ref.read(databaseProvider));
      final r = await dao.getByTaskId(widget.task.id!);
      final resultId = _result?.id;
      if (resultId != null && _result?.syncStatus == ShareConsent.synced) {
        await ref
            .read(communityShareServiceProvider)
            .syncUserOutcomeUpdate(resultId);
      }
      if (!mounted) return;
      setState(() {
        _result = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _toggleCommunityShare() async {
    final result = _result;
    if (result == null || result.communityPublicationId == null || _sharing) {
      return;
    }
    final isShared = result.shareConsent == ShareConsent.pending ||
        result.shareConsent == ShareConsent.synced ||
        result.shareConsent == ShareConsent.revokePending;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isShared ? '撤回社区记录' : '分享匿名打印记录'),
        content: SizedBox(
          width: 480,
          child: Text(
            isShared
                ? '撤回后，该记录将从社区可信统计中移除。断网时会保留撤回任务，恢复连接后继续。'
                : '将上传：参数版本指纹、设备型号、喷嘴直径、材料型号、'
                    '脱敏湿度档位、技术状态、耗时、克数和你填写的成品评价。\n\n'
                    '不会上传：打印机序列号、IP、trayUuid、本地路径、G-code、'
                    '邮箱和本地备注。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isShared ? '确认撤回' : '确认分享'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _sharing = true);
    try {
      if (isShared) {
        await ref.read(communityShareServiceProvider).revokeShare(result.id);
      } else {
        if (!ref.read(communityShareEnabledProvider)) {
          await ref
              .read(communityShareEnabledProvider.notifier)
              .setEnabled(true);
        }
        await ref
            .read(communityShareServiceProvider)
            .setShareConsent(result.id, true);
      }
      await _loadResult();
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _openSupplement() async {
    final task = widget.task;
    final supplement = await showPrintResultSupplementDialog(
      context,
      taskName: task.taskName,
      existing: _result,
    );
    if (supplement == null) return;

    try {
      final dao = PresetResultDao(ref.read(databaseProvider));
      // 若结果不存在，先创建一条空结果记录（upsert）
      if (_result == null) {
        // 自动采集字段保留默认值（任务事实由状态机写入）
        final id = await dao.upsertResultForTask(
          taskId: task.id!,
          taskUid: task.uid,
          presetDisplayName: '',
          attribution: ResultAttribution.unknown,
          printerModel: '',
          technicalStatus: _mapTaskStatus(task.status),
          evidenceLevel: EvidenceLevel.deviceRecorded,
        );
        await dao.updateUserOutcome(
          resultId: id,
          userOutcome: supplement.userOutcome,
          rating: supplement.rating,
          adhesionOk: supplement.adhesionOk,
          qualityScore: supplement.qualityScore,
          userNote: supplement.userNote,
        );
      } else {
        await dao.updateUserOutcome(
          resultId: _result!.id,
          userOutcome: supplement.userOutcome,
          rating: supplement.rating,
          adhesionOk: supplement.adhesionOk,
          qualityScore: supplement.qualityScore,
          userNote: supplement.userNote,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnack(
        context,
        '已保存打印结果评价',
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      if (!mounted) return;
      showSnack(
        context,
        '保存失败：$e',
        error: true,
        duration: const Duration(seconds: 3),
      );
    }
  }

  TechnicalStatus _mapTaskStatus(PrintTaskStatus s) {
    switch (s) {
      case PrintTaskStatus.finished:
        return TechnicalStatus.finished;
      case PrintTaskStatus.failed:
        return TechnicalStatus.failed;
      case PrintTaskStatus.cancelled:
        return TechnicalStatus.cancelled;
      case PrintTaskStatus.printing:
      case PrintTaskStatus.paused:
      case PrintTaskStatus.planned:
        return TechnicalStatus.finished; // 进行中任务进入终态时为 finished
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final task = widget.task;
    final isTerminal = task.status == PrintTaskStatus.finished ||
        task.status == PrintTaskStatus.failed ||
        task.status == PrintTaskStatus.cancelled;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surface,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppColors.radiusLg),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部把手
          Container(
            margin: const EdgeInsets.only(top: AppSpacing.sm),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: isDark ? AppColors.outlineDark : AppColors.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '任务详情',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark
                          ? AppColors.textPrimaryDark
                          : AppColors.textPrimary,
                    ),
                  ),
                ),
                IconActionButton(
                  icon: Icons.close,
                  tooltip: '关闭',
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: AppSpacing.lg),

          // 内容
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 任务名 + 状态
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          task.taskName,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? AppColors.textPrimaryDark
                                : AppColors.textPrimary,
                          ),
                          maxLines: 2,
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
                  const SizedBox(height: AppSpacing.md),

                  // 任务信息
                  _InfoRow(
                    label: '开始时间',
                    value: task.startedAt != null
                        ? DateFormat('yyyy-MM-dd HH:mm:ss')
                            .format(task.startedAt!)
                        : '—',
                    isDark: isDark,
                  ),
                  _InfoRow(
                    label: '结束时间',
                    value: task.finishedAt != null
                        ? DateFormat('yyyy-MM-dd HH:mm:ss')
                            .format(task.finishedAt!)
                        : '—',
                    isDark: isDark,
                  ),
                  _InfoRow(
                    label: '耗时',
                    value: _durationText(task.elapsedSeconds),
                    isDark: isDark,
                  ),
                  _InfoRow(
                    label: '预估克数',
                    value: GramUtils.formatGrams(task.estimatedGrams),
                    isDark: isDark,
                  ),
                  _InfoRow(
                    label: '实际克数',
                    value: GramUtils.formatGrams(task.actualGrams),
                    isDark: isDark,
                  ),
                  _InfoRow(
                    label: '完成进度',
                    value: '${task.lastMcPercent}%',
                    isDark: isDark,
                  ),

                  const SizedBox(height: AppSpacing.md),

                  // 关联参数信息
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(AppSpacing.md),
                      child: Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (_error != null)
                    _ErrorBox(message: _error!)
                  else ...[
                    if (_result != null) ...[
                      _SectionTitle(title: '参数关联', isDark: isDark),
                      if (_result!.presetDisplayName.isNotEmpty)
                        _InfoRow(
                          label: '参数名称',
                          value: _result!.presetDisplayName,
                          isDark: isDark,
                        )
                      else
                        _InfoRow(
                          label: '参数名称',
                          value: '未关联参数',
                          isDark: isDark,
                        ),
                      _InfoRow(
                        label: '归因方式',
                        value: _attributionLabel(_result!.attribution),
                        isDark: isDark,
                      ),
                      if (_result!.communityRevision != null)
                        _InfoRow(
                          label: '社区版本',
                          value: 'rev ${_result!.communityRevision}',
                          isDark: isDark,
                        ),
                      const SizedBox(height: AppSpacing.md),
                    ],

                    // 已有补充评价
                    if (_result?.userOutcome != null) ...[
                      _SectionTitle(title: '已记录的评价', isDark: isDark),
                      _InfoRow(
                        label: '成品结果',
                        value: _outcomeLabel(_result!.userOutcome!),
                        isDark: isDark,
                      ),
                      if (_result!.rating != null)
                        _InfoRow(
                          label: '整体评分',
                          value: '${_result!.rating} / 5',
                          isDark: isDark,
                        ),
                      if (_result!.adhesionOk != null)
                        _InfoRow(
                          label: '粘附',
                          value: _result!.adhesionOk! ? '成功' : '失败',
                          isDark: isDark,
                        ),
                      if (_result!.qualityScore != null)
                        _InfoRow(
                          label: '质量评分',
                          value: '${_result!.qualityScore} / 5',
                          isDark: isDark,
                        ),
                      if (_result!.userNote != null &&
                          _result!.userNote!.isNotEmpty)
                        _InfoRow(
                          label: '备注',
                          value: _result!.userNote!,
                          isDark: isDark,
                        ),
                      const SizedBox(height: AppSpacing.md),
                    ],

                    // 补充按钮
                    if (isTerminal)
                      Column(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              icon: const Icon(Icons.rate_review, size: 18),
                              label: Text(
                                _result?.userOutcome != null
                                    ? '修改打印结果评价'
                                    : '补充打印结果',
                              ),
                              onPressed: _openSupplement,
                            ),
                          ),
                          if (_result?.communityPublicationId != null) ...[
                            const SizedBox(height: AppSpacing.sm),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                icon: _sharing
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(
                                        _result!.shareConsent ==
                                                    ShareConsent.synced ||
                                                _result!.shareConsent ==
                                                    ShareConsent.pending
                                            ? Icons.cloud_done_outlined
                                            : Icons.cloud_upload_outlined,
                                        size: 18,
                                      ),
                                label: Text(
                                  switch (_result!.shareConsent) {
                                    ShareConsent.synced => '已分享，点击撤回',
                                    ShareConsent.pending => '等待分享同步',
                                    ShareConsent.revokePending => '撤回待同步',
                                    ShareConsent.failed => '分享失败，点击重试',
                                    _ => '分享匿名打印记录',
                                  },
                                ),
                                onPressed:
                                    _sharing ? null : _toggleCommunityShare,
                              ),
                            ),
                          ],
                        ],
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _durationText(int seconds) {
    if (seconds <= 0) return '—';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m ${s}s';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  String _attributionLabel(ResultAttribution a) {
    switch (a) {
      case ResultAttribution.exact:
        return '精确归因（切片产物 hash）';
      case ResultAttribution.manual:
        return '手动归因';
      case ResultAttribution.ambiguous:
        return '模糊归因（多个候选）';
      case ResultAttribution.unknown:
        return '未关联参数';
    }
  }

  String _outcomeLabel(UserOutcome o) {
    switch (o) {
      case UserOutcome.success:
        return '成功';
      case UserOutcome.usable:
        return '有瑕疵但可用';
      case UserOutcome.qualityFailed:
        return '成品失败';
    }
  }
}

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
    case PrintTaskStatus.planned:
      return AppChipVariant.default_;
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool isDark;
  const _InfoRow({
    required this.label,
    required this.value,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
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
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color:
                    isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final bool isDark;
  const _SectionTitle({required this.title, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.danger),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
