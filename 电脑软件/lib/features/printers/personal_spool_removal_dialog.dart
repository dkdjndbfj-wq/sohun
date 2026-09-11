import 'package:flutter/material.dart';

import '../../core/constants/personal_spool_policy.dart';
import '../../core/theme/glass_button_theme.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/gram_utils.dart';
import '../../widgets/app_dialog.dart';

enum PersonalSpoolRemovalDecision { maintenance, takeOff, usedUp, replace }

/// 个人模式取下耗材前的原因确认。
///
/// 堵头或维修只暂停槽位，不结算、不扣库存；正常取下/确认用完仍由调用方
/// 执行原有业务。统一通过 [AppDialog] 展示，以保持个人工作台弹窗风格一致。
class PersonalSpoolRemovalDialog {
  PersonalSpoolRemovalDialog._();

  static Future<PersonalSpoolRemovalDecision?> show({
    required BuildContext context,
    required String channelLabel,
    required String spoolLabel,
    required double remainingGrams,
    required PersonalSpoolRemovalDecision normalDecision,
  }) {
    assert(
      normalDecision == PersonalSpoolRemovalDecision.takeOff ||
          normalDecision == PersonalSpoolRemovalDecision.usedUp,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final preserved = GramUtils.formatGrams(
      remainingGrams < 0 ? 0 : remainingGrams,
    );
    final marksUsedUp = normalDecision == PersonalSpoolRemovalDecision.usedUp;
    final reusable = canReusePersonalSpool(remainingGrams);

    return AppDialog.show<PersonalSpoolRemovalDecision>(
      context: context,
      title: '取下耗材前确认',
      barrierDismissible: false,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$channelLabel · $spoolLabel',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: secondaryColor,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: isDark ? 0.16 : 0.1),
              borderRadius: BorderRadius.circular(AppColors.radiusMd),
              border: Border.all(
                color: AppColors.warning.withValues(alpha: 0.38),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.build_outlined,
                  size: 20,
                  color: AppColors.warning,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '如果只是堵头或维修，请选择“维修暂取”。系统会保留当前 '
                    '$preserved，不进行扣除；'
                    '${reusable ? '重新装回后从这个克数继续计算。' : '余量需大于 30g 且不超过 1000g 才能继续使用，低余量不会自动清零。'}',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.55,
                      color: secondaryColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            marksUsedUp
                ? '只有这卷耗材确实已经用完时，才选择“确认用完”。'
                : '如果只是结束使用并放回库存，选择“正常取下”，克数同样不会变化。',
            style: TextStyle(fontSize: 12, height: 1.5, color: secondaryColor),
          ),
        ],
      ),
      actions: [
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton(
                key: const ValueKey('personal-spool-removal-cancel'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              OutlinedButton(
                key: const ValueKey('personal-spool-removal-maintenance'),
                onPressed: () => Navigator.of(
                  context,
                ).pop(PersonalSpoolRemovalDecision.maintenance),
                child: const Text('维修暂取'),
              ),
              if (marksUsedUp && remainingGrams > 0)
                TextButton(
                  key: const ValueKey('personal-spool-removal-return'),
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(PersonalSpoolRemovalDecision.takeOff),
                  child: const Text('余料回库'),
                ),
              FilledButton(
                key: ValueKey(
                  marksUsedUp
                      ? 'personal-spool-removal-used-up'
                      : 'personal-spool-removal-take-off',
                ),
                style: marksUsedUp
                    ? glassButtonStyle(
                        context,
                        FilledButton.styleFrom(
                          backgroundColor: AppColors.danger,
                        ),
                        variant: AppGlassButtonVariant.primary,
                      )
                    : null,
                onPressed: () => Navigator.of(context).pop(normalDecision),
                child: Text(marksUsedUp ? '确认用完' : '正常取下'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 物理传感器稳定检测到拔料后的原因确认。
  ///
  /// 与手动“取下”入口不同，这里需要覆盖用户未提前操作软件的四种真实场景。
  static Future<PersonalSpoolRemovalDecision?> showDetected({
    required BuildContext context,
    required String channelLabel,
    required String spoolLabel,
    required double remainingGrams,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final preserved = GramUtils.formatGrams(
      remainingGrams < 0 ? 0 : remainingGrams,
    );
    final reusable = canReusePersonalSpool(remainingGrams);

    return AppDialog.show<PersonalSpoolRemovalDecision>(
      context: context,
      title: '检测到耗材已取下',
      barrierDismissible: false,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$channelLabel · $spoolLabel',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: secondaryColor,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '当前记录为 $preserved。请选择这次拔料的原因，系统会按你的选择处理库存。',
            style: TextStyle(fontSize: 12, height: 1.5, color: secondaryColor),
          ),
          const SizedBox(height: AppSpacing.md),
          _RemovalChoiceTile(
            key: const ValueKey('detected-removal-maintenance'),
            icon: Icons.build_outlined,
            color: AppColors.warning,
            title: '堵头或维修暂取',
            subtitle: reusable
                ? '保留 $preserved，不扣除；装回原卷后继续计算'
                : '保留 $preserved，不扣除；余量需大于 30g 才能继续使用',
            onTap: () => Navigator.of(
              context,
            ).pop(PersonalSpoolRemovalDecision.maintenance),
          ),
          const SizedBox(height: AppSpacing.sm),
          _RemovalChoiceTile(
            key: const ValueKey('detected-removal-take-off'),
            icon: Icons.inventory_2_outlined,
            color: AppColors.primary,
            title: '正常取下并放回库存',
            subtitle: '解除料位绑定，库存克数保持不变',
            onTap: () =>
                Navigator.of(context).pop(PersonalSpoolRemovalDecision.takeOff),
          ),
          const SizedBox(height: AppSpacing.sm),
          _RemovalChoiceTile(
            key: const ValueKey('detected-removal-replace'),
            icon: Icons.swap_horiz_rounded,
            color: AppColors.primary,
            title: '准备换上新料卷',
            subtitle: '保留旧卷记录，装入新卷后再确认绑定',
            onTap: () =>
                Navigator.of(context).pop(PersonalSpoolRemovalDecision.replace),
          ),
          const SizedBox(height: AppSpacing.sm),
          _RemovalChoiceTile(
            key: const ValueKey('detected-removal-used-up'),
            icon: Icons.delete_outline_rounded,
            color: AppColors.danger,
            title: '这卷已经用完',
            subtitle: '按耗尽结算并清空当前料位',
            onTap: () =>
                Navigator.of(context).pop(PersonalSpoolRemovalDecision.usedUp),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('detected-removal-later'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('稍后处理'),
        ),
      ],
    );
  }
}

class _RemovalChoiceTile extends StatelessWidget {
  const _RemovalChoiceTile({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: color.withValues(alpha: isDark ? 0.13 : 0.08),
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            border: Border.all(color: color.withValues(alpha: 0.28)),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.textPrimaryDark
                            : AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 10,
                        height: 1.35,
                        color: isDark
                            ? AppColors.textSecondaryDark
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
