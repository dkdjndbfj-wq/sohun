import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/interaction_effects.dart';
import 'glass_card.dart';
import '../core/theme/glass_button_theme.dart';
import 'app_glass_button.dart';

/// 苹果风格对话框。
///
/// 22px 圆角 + 重玻璃（GlassCard L3 + blur 42 + shadow4）+ scale 入场动效。
/// 通过 [AppDialog.show] 静态方法调用，封装 [showGeneralDialog]，
/// transitionBuilder 使用 ScaleTransition 0.92→1 + FadeTransition
/// （durationModal curveModal）。支持暗色模式（GlassCard 自动处理）。
class AppDialog {
  AppDialog._();

  /// 弹出对话框。返回 [actions] 中通过 `Navigator.pop` 传入的值。
  static Future<T?> show<T>({
    required BuildContext context,
    required String title,
    required Widget content,
    required List<Widget> actions,
    bool barrierDismissible = true,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: AppMotion.duration(context, AppCurves.durationModal),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        if (!AppMotion.enabled(context)) return child;
        // 修复：原实现每帧创建 CurvedAnimation 对象且未 dispose，造成累积泄漏。
        // 改用 AnimatedBuilder + 手动 curve.transform，不在每帧产生监听对象。
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final t = animation.value;
            final curvedScale = AppCurves.curveModal.transform(t);
            final scale = 0.92 + 0.08 * curvedScale;
            final fade = Curves.easeOut.transform(t).clamp(0.0, 1.0);
            return Opacity(
              opacity: fade,
              child: Transform.scale(scale: scale, child: child),
            );
          },
          child: child,
        );
      },
      pageBuilder: (context, animation, secondaryAnimation) {
        return _AppDialogContent(
          title: title,
          content: content,
          actions: actions,
        );
      },
    );
  }

  /// 便捷确认框。
  ///
  /// [destructive] 为 true 时确认按钮使用 [AppColors.danger] 色。
  /// 返回是否确认；点击遮罩或取消返回 false。
  static Future<bool> confirm(
    BuildContext context,
    String title,
    String content, {
    VoidCallback? onConfirm,
    String confirmText = '确认',
    String cancelText = '取消',
    bool destructive = false,
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final result = await show<bool>(
      context: context,
      title: title,
      content: Text(
        content,
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
        ),
      ),
      actions: [
        _DialogActionButton(
          label: cancelText,
          primary: false,
          onTap: () => Navigator.of(context).pop<bool>(false),
        ),
        const SizedBox(width: AppSpacing.sm),
        _DialogActionButton(
          label: confirmText,
          primary: true,
          destructive: destructive,
          onTap: () {
            Navigator.of(context).pop<bool>(true);
            onConfirm?.call();
          },
        ),
      ],
    );
    return result ?? false;
  }
}

/// 对话框内容容器：GlassCard L3 + radiusXl + blur 42 + shadow4，最大宽 400。
class _AppDialogContent extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;

  const _AppDialogContent({
    required this.title,
    required this.content,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: GlassCard(
            level: GlassLevel.l3,
            blur: 42,
            boxShadow: isDark ? AppColors.shadow4Dark : AppColors.shadow4,
            borderRadius: BorderRadius.circular(AppColors.radiusXl),
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题：字号 16 w800
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: titleColor,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                // 内容（可滚动，避免超长溢出）
                Flexible(
                  fit: FlexFit.loose,
                  child: SingleChildScrollView(child: content),
                ),
                const SizedBox(height: AppSpacing.xxl),
                // actions 右对齐
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 对话框按钮：统一圆角 + 语义色填充。
class _DialogActionButton extends StatelessWidget {
  final String label;
  final bool primary;
  final bool destructive;
  final VoidCallback onTap;

  const _DialogActionButton({
    required this.label,
    required this.primary,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color bg;
    final Color fg;
    if (GlassButtonsTheme.enabledOf(context)) {
      return AppGlassButton(
        label: label,
        onPressed: onTap,
        variant: primary
            ? (destructive
                  ? AppGlassButtonVariant.danger
                  : AppGlassButtonVariant.primary)
            : AppGlassButtonVariant.secondary,
        tint: destructive ? AppColors.danger : null,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      );
    }
    if (primary && destructive) {
      bg = AppColors.danger;
      fg = Colors.white;
    } else if (primary) {
      bg = AppColors.primary;
      fg = Colors.white;
    } else {
      bg = isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant;
      fg = isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    }
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppColors.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}
