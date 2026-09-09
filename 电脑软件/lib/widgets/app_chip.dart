import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/glass_button_theme.dart';
import 'app_glass_button.dart';

/// Chip 变体。
enum AppChipVariant {
  /// 默认：surfaceVariant 背景 + textSecondary 字。
  default_,

  /// 选中：primaryContainer 背景 + primary 字 + primary 描边。
  selected,

  /// 带圆点：左侧 6px 圆点（用 dotColor）+ default 样式。
  dot,

  /// 警告：warningContainer 背景 + warning 字。
  warn,

  /// 危险：dangerContainer 背景 + danger 字。
  danger,

  /// 信息：infoContainer 背景 + info 字。
  info,
}

/// 苹果风格标签 / 胶囊。
///
/// 6 种变体，可选点击（hover 时背景加深）。圆角胶囊，padding 水平 10 垂直 4，字号 12 w600。
/// 暗色模式下使用对应 container 色降低透明度，保持可读性。
class AppChip extends StatefulWidget {
  /// 文字（必填）。
  final String label;

  /// 变体，默认 default_。
  final AppChipVariant variant;

  /// dot 变体的圆点颜色；其他变体忽略。
  /// 默认为 [AppColors.primary]。
  final Color? dotColor;

  /// 是否选中。为 true 时强制使用 selected 变体样式。
  final bool selected;

  /// 点击回调；非空时可点击，hover 时背景加深。
  final VoidCallback? onTap;

  const AppChip({
    super.key,
    required this.label,
    this.variant = AppChipVariant.default_,
    this.dotColor,
    this.selected = false,
    this.onTap,
  });

  @override
  State<AppChip> createState() => _AppChipState();
}

class _AppChipState extends State<AppChip> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isClickable = widget.onTap != null;

    // 真实生效变体：selected=true 时强制 selected 样式
    final variant = widget.selected ? AppChipVariant.selected : widget.variant;
    if (isClickable && GlassButtonsTheme.enabledOf(context)) {
      return Semantics(
        selected: variant == AppChipVariant.selected,
        child: AppGlassButton(
          label: widget.label,
          onPressed: widget.onTap,
          compact: true,
          variant: variant == AppChipVariant.selected
              ? AppGlassButtonVariant.primary
              : AppGlassButtonVariant.quiet,
          tint: switch (variant) {
            AppChipVariant.warn => AppColors.warning,
            AppChipVariant.danger => AppColors.danger,
            AppChipVariant.info => AppColors.info,
            _ => null,
          },
          icon: variant == AppChipVariant.dot
              ? Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: widget.dotColor ?? AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                )
              : null,
          minimumSize: const Size(0, 26),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          borderRadius: BorderRadius.circular(AppColors.radiusFull),
        ),
      );
    }

    // 解析颜色：基础背景 / hover 背景 / 前景色 / 描边色 / 圆点色
    final Color baseBg;
    final Color hoverBg;
    final Color fgColor;
    final Color? borderColor;
    final Color? dotColor;

    switch (variant) {
      case AppChipVariant.default_:
        baseBg = isDark
            ? AppColors.surfaceVariantDark
            : AppColors.surfaceVariant;
        hoverBg = isDark
            ? AppColors.surfaceContainerHighDark
            : AppColors.surfaceContainerHighest;
        fgColor = isDark
            ? AppColors.textSecondaryDark
            : AppColors.textSecondary;
        borderColor = null;
        dotColor = widget.dotColor;
      case AppChipVariant.selected:
        baseBg = isDark
            ? AppColors.primaryContainer.withValues(alpha: 0.20)
            : AppColors.primaryContainer;
        hoverBg = isDark
            ? AppColors.primaryContainer.withValues(alpha: 0.32)
            : AppColors.primaryContainer.withValues(alpha: 0.85);
        fgColor = AppColors.primary;
        borderColor = AppColors.primary.withValues(alpha: isDark ? 0.6 : 1.0);
        dotColor = null;
      case AppChipVariant.dot:
        baseBg = isDark
            ? AppColors.surfaceVariantDark
            : AppColors.surfaceVariant;
        hoverBg = isDark
            ? AppColors.surfaceContainerHighDark
            : AppColors.surfaceContainerHighest;
        fgColor = isDark
            ? AppColors.textSecondaryDark
            : AppColors.textSecondary;
        borderColor = null;
        dotColor = widget.dotColor ?? AppColors.primary;
      case AppChipVariant.warn:
        baseBg = isDark
            ? AppColors.warningContainer.withValues(alpha: 0.18)
            : AppColors.warningContainer;
        hoverBg = isDark
            ? AppColors.warningContainer.withValues(alpha: 0.28)
            : AppColors.warningContainer.withValues(alpha: 0.85);
        fgColor = AppColors.warning;
        borderColor = null;
        dotColor = null;
      case AppChipVariant.danger:
        baseBg = isDark
            ? AppColors.dangerContainer.withValues(alpha: 0.18)
            : AppColors.dangerContainer;
        hoverBg = isDark
            ? AppColors.dangerContainer.withValues(alpha: 0.28)
            : AppColors.dangerContainer.withValues(alpha: 0.85);
        fgColor = AppColors.danger;
        borderColor = null;
        dotColor = null;
      case AppChipVariant.info:
        baseBg = isDark
            ? AppColors.infoContainer.withValues(alpha: 0.18)
            : AppColors.infoContainer;
        hoverBg = isDark
            ? AppColors.infoContainer.withValues(alpha: 0.28)
            : AppColors.infoContainer.withValues(alpha: 0.85);
        fgColor = AppColors.info;
        borderColor = null;
        dotColor = null;
    }

    final bg = (_hovering && isClickable) ? hoverBg : baseBg;

    // 内容：可选圆点 + 文字
    Widget content = Text(
      widget.label,
      style: TextStyle(
        color: fgColor,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        height: 1.2,
      ),
    );
    if (variant == AppChipVariant.dot && dotColor != null) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          content,
        ],
      );
    }

    return MouseRegion(
      cursor: isClickable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: isClickable ? (_) => setState(() => _hovering = true) : null,
      onExit: isClickable ? (_) => setState(() => _hovering = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppCurves.durationHover),
          curve: AppCurves.curveHover,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppColors.radiusFull),
            border: borderColor != null
                ? Border.all(color: borderColor, width: 1)
                : null,
          ),
          child: content,
        ),
      ),
    );
  }
}
