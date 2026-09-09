// 打印结果补充评价对话框。
//
// 任务书 Phase D 要求：
// - 在打印历史详情中提供"补充打印结果"，让用户选择
//   "成功 / 有瑕疵但可用 / 成品失败"，并填写可选评分、粘附、质量和失败分类。
// - 用户补充评分只能更新主观字段，不能改写自动采集的任务事实。
// - 结果补充表单拒绝 0、6、NaN 等非法评分。
// - 不得把"任务状态为 finished"等同于"打印品质优秀"。
// - 防重复提交：保存操作在进行中禁用。
// - 危险操作需确认。

import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../data/database/models/preset_print_result.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/icon_action_button.dart';

/// 打印结果补充评价结果。
///
/// 返回给调用方写入 DAO。null 表示用户取消。
class PrintResultSupplement {
  final UserOutcome userOutcome;
  final int? rating; // 1-5
  final bool? adhesionOk;
  final int? qualityScore; // 1-5
  final String? userNote;

  const PrintResultSupplement({
    required this.userOutcome,
    required this.rating,
    required this.adhesionOk,
    required this.qualityScore,
    required this.userNote,
  });
}

/// 显示打印结果补充评价对话框。
///
/// [existing] 为已存在的补充评价（编辑模式），null 为首次补充。
/// 返回用户填写的补充评价；用户取消返回 null。
Future<PrintResultSupplement?> showPrintResultSupplementDialog(
  BuildContext context, {
  required String taskName,
  PresetPrintResult? existing,
}) {
  return showDialog<PrintResultSupplement>(
    context: context,
    builder: (ctx) => _SupplementDialog(taskName: taskName, existing: existing),
  );
}

class _SupplementDialog extends ConsumerStatefulWidget {
  final String taskName;
  final PresetPrintResult? existing;

  const _SupplementDialog({required this.taskName, required this.existing});

  @override
  ConsumerState<_SupplementDialog> createState() => _SupplementDialogState();
}

class _SupplementDialogState extends ConsumerState<_SupplementDialog> {
  late UserOutcome? _outcome;
  late TextEditingController _ratingCtrl;
  late TextEditingController _qualityCtrl;
  late TextEditingController _noteCtrl;
  bool? _adhesionOk;
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _outcome = e?.userOutcome;
    _ratingCtrl = TextEditingController(
      text: e?.rating != null ? e!.rating.toString() : '',
    );
    _qualityCtrl = TextEditingController(
      text: e?.qualityScore != null ? e!.qualityScore.toString() : '',
    );
    _noteCtrl = TextEditingController(text: e?.userNote ?? '');
    _adhesionOk = e?.adhesionOk;
  }

  @override
  void dispose() {
    _ratingCtrl.dispose();
    _qualityCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // 校验
    if (_outcome == null) {
      setState(() => _errorText = '请选择打印成品结果');
      return;
    }

    int? rating;
    if (_ratingCtrl.text.trim().isNotEmpty) {
      rating = int.tryParse(_ratingCtrl.text.trim());
      if (rating == null || rating < 1 || rating > 5) {
        setState(() => _errorText = '评分必须为 1-5 的整数');
        return;
      }
    }

    int? quality;
    if (_qualityCtrl.text.trim().isNotEmpty) {
      quality = int.tryParse(_qualityCtrl.text.trim());
      if (quality == null || quality < 1 || quality > 5) {
        setState(() => _errorText = '质量评分必须为 1-5 的整数');
        return;
      }
    }

    setState(() {
      _saving = true;
      _errorText = null;
    });

    final result = PrintResultSupplement(
      userOutcome: _outcome!,
      rating: rating,
      adhesionOk: _adhesionOk,
      qualityScore: quality,
      userNote: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
    );

    // 模拟保存延迟（实际保存由调用方执行）
    await Future.delayed(const Duration(milliseconds: 100));

    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Dialog(
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: GlassCard(
          level: GlassLevel.l1,
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '补充打印结果',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                    ),
                  ),
                  IconActionButton(
                    icon: Icons.close,
                    tooltip: '取消',
                    onTap: _saving ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                widget.taskName,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark
                      ? AppColors.textSecondaryDark
                      : AppColors.textSecondary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.lg),

              // 成品结果（必选）
              const _Label('成品结果 *'),
              const SizedBox(height: AppSpacing.xs),
              _OutcomeSelector(
                value: _outcome,
                onChanged: _saving ? null : (v) => setState(() => _outcome = v),
              ),
              const SizedBox(height: AppSpacing.lg),

              // 评分（1-5）
              const _Label('整体评分（1-5，可选）'),
              const SizedBox(height: AppSpacing.xs),
              _NumberField(
                controller: _ratingCtrl,
                hint: '1-5',
                enabled: !_saving,
              ),
              const SizedBox(height: AppSpacing.lg),

              // 粘附成功
              const _Label('粘附是否成功（可选）'),
              const SizedBox(height: AppSpacing.xs),
              _AdhesionSelector(
                value: _adhesionOk,
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _adhesionOk = v),
              ),
              const SizedBox(height: AppSpacing.lg),

              // 质量评分
              const _Label('表面质量评分（1-5，可选）'),
              const SizedBox(height: AppSpacing.xs),
              _NumberField(
                controller: _qualityCtrl,
                hint: '1-5',
                enabled: !_saving,
              ),
              const SizedBox(height: AppSpacing.lg),

              // 备注
              const _Label('备注（可选，仅本地保存）'),
              const SizedBox(height: AppSpacing.xs),
              TextField(
                controller: _noteCtrl,
                enabled: !_saving,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(
                  hintText: '补充打印细节、失败原因等',
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppColors.radiusMd),
                  ),
                ),
              ),

              // 错误提示
              if (_errorText != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _errorText!,
                  style: const TextStyle(fontSize: 12, color: AppColors.danger),
                ),
              ],

              const SizedBox(height: AppSpacing.lg),

              // 操作按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? Builder(
                            builder: (context) => SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: GlassButtonsTheme.enabledOf(context)
                                    ? IconTheme.of(context).color
                                    : Colors.white,
                              ),
                            ),
                          )
                        : const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
      ),
    );
  }
}

class _OutcomeSelector extends StatelessWidget {
  final UserOutcome? value;
  final ValueChanged<UserOutcome?>? onChanged;

  const _OutcomeSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        _ChoiceChip(
          label: '成功',
          selected: value == UserOutcome.success,
          color: AppColors.success,
          onTap: onChanged == null
              ? null
              : () => onChanged!(UserOutcome.success),
        ),
        _ChoiceChip(
          label: '有瑕疵但可用',
          selected: value == UserOutcome.usable,
          color: AppColors.warning,
          onTap: onChanged == null
              ? null
              : () => onChanged!(UserOutcome.usable),
        ),
        _ChoiceChip(
          label: '成品失败',
          selected: value == UserOutcome.qualityFailed,
          color: AppColors.danger,
          onTap: onChanged == null
              ? null
              : () => onChanged!(UserOutcome.qualityFailed),
        ),
      ],
    );
  }
}

class _AdhesionSelector extends StatelessWidget {
  final bool? value;
  final ValueChanged<bool?>? onChanged;

  const _AdhesionSelector({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.sm,
      children: [
        _ChoiceChip(
          label: '粘附成功',
          selected: value == true,
          color: AppColors.success,
          onTap: onChanged == null ? null : () => onChanged!(true),
        ),
        _ChoiceChip(
          label: '粘附失败',
          selected: value == false,
          color: AppColors.danger,
          onTap: onChanged == null ? null : () => onChanged!(false),
        ),
      ],
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color color;
  final VoidCallback? onTap;

  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return Semantics(
        selected: selected,
        child: AppGlassButton(
          label: label,
          onPressed: onTap,
          variant: selected
              ? AppGlassButtonVariant.primary
              : AppGlassButtonVariant.secondary,
          tint: selected ? color : null,
          compact: true,
          minimumSize: const Size(0, 34),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.15) : null,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            border: Border.all(
              color: selected ? color : AppColors.outline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected
                  ? color
                  : (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textPrimaryDark
                        : AppColors.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool enabled;

  const _NumberField({
    required this.controller,
    required this.hint,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: TextField(
        controller: controller,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        decoration: InputDecoration(
          hintText: hint,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
        ),
        inputFormatters: [
          // 只允许 1-5
          FilteringTextInputFormatter.allow(RegExp(r'^[1-5]?$')),
        ],
      ),
    );
  }
}
