import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/personal_desktop_theme.dart';
import '../core/theme/glass_button_theme.dart';
import 'app_glass_button.dart';

/// 按钮变体。
enum AppButtonVariant {
  /// 主按钮：渐变绿背景 + 白字 + 顶部高光 + 外发光。
  primary,

  /// 次按钮：玻璃描边 + primary 字。
  secondary,

  /// 幽灵按钮：透明背景，hover 时背景 primary 8%。
  ghost,

  /// 危险按钮：红色渐变 + 白字 + 红发光。
  danger,

  /// 禁用态：灰色背景 + 三级文字。
  disabled,
}

/// 苹果风格按钮。
///
/// 5 种变体 + 可选前置图标 + 胶囊形态。配套点按回弹动效（AnimatedScale 0.97）。
/// 暗色模式下主按钮增强发光，次按钮切换玻璃深色填充。
class AppButton extends StatefulWidget {
  /// 按钮文字（必填）。
  final String label;

  /// 按钮变体，默认 primary。
  final AppButtonVariant variant;

  /// 可选前置图标，置于文字左侧，间距 8。
  final Widget? icon;

  /// 点击回调；为 null 时按钮禁用。
  final VoidCallback? onPressed;

  /// 是否使用胶囊圆角（radiusFull）。
  final bool capsule;

  /// 紧凑尺寸。仅缩小字号、间距和高度，不改变按钮的颜色与动效体系。
  final bool compact;

  const AppButton({
    super.key,
    required this.label,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.onPressed,
    this.capsule = false,
    this.compact = false,
  });

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _tapping = false;
  bool _hovering = false;

  /// 是否处于禁用态：onPressed 为空 或 显式指定 disabled 变体。
  bool get _isDisabled =>
      widget.onPressed == null || widget.variant == AppButtonVariant.disabled;

  @override
  Widget build(BuildContext context) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return AppGlassButton(
        label: widget.label,
        icon: widget.icon,
        onPressed: _isDisabled ? null : widget.onPressed,
        compact: widget.compact,
        variant: switch (widget.variant) {
          AppButtonVariant.primary ||
          AppButtonVariant.disabled => AppGlassButtonVariant.primary,
          AppButtonVariant.secondary => AppGlassButtonVariant.secondary,
          AppButtonVariant.ghost => AppGlassButtonVariant.quiet,
          AppButtonVariant.danger => AppGlassButtonVariant.danger,
        },
        tint: widget.variant == AppButtonVariant.danger
            ? AppColors.danger
            : null,
        minimumSize: Size(0, widget.compact ? 34 : 42),
        padding: EdgeInsets.symmetric(
          horizontal: widget.compact ? 13 : 22,
          vertical: widget.compact ? 8 : 12,
        ),
        borderRadius: widget.capsule
            ? BorderRadius.circular(AppColors.radiusFull)
            : null,
      );
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final personal = PersonalDesktopTheme.of(context) != null;
    final motionEnabled = AppMotion.enabled(context);
    final radius = BorderRadius.circular(
      widget.capsule ? AppColors.radiusFull : AppColors.radiusMd,
    );

    // 真实生效变体：禁用态统一为 disabled 样式
    final variant = _isDisabled ? AppButtonVariant.disabled : widget.variant;

    // 解析装饰 / 前景色（boxShadow 已内嵌到各 case 的 BoxDecoration 中）
    final BoxDecoration decoration;
    final Color foregroundColor;

    switch (variant) {
      case AppButtonVariant.primary:
        decoration = BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: personal
                ? [
                    Color.lerp(AppColors.primary, Colors.black, 0.24)!,
                    Color.lerp(AppColors.primary, Colors.black, 0.30)!,
                  ]
                : [AppColors.primary, AppColors.primary600],
          ),
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(
                alpha: personal
                    ? (isDark ? 0.20 : 0.14)
                    : (isDark ? 0.55 : 0.40),
              ),
              blurRadius: personal
                  ? (_hovering && motionEnabled ? 9 : 6)
                  : isDark
                  ? (_hovering && motionEnabled ? 20 : 16)
                  : (_hovering && motionEnabled ? 14 : 10),
              offset: Offset(0, _hovering && motionEnabled ? 5 : 4),
            ),
            // 暗色模式叠加一层白色透明发光，增强亮度感
            if (isDark && !personal)
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.10),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
          ],
        );
        foregroundColor = AppColors.onPrimary;
      case AppButtonVariant.secondary:
        decoration = BoxDecoration(
          color: personal
              ? personalDesktopGlassFill(Theme.of(context))
              : (isDark ? AppColors.glassFillL1Dark : AppColors.glassFillL1),
          borderRadius: radius,
          border: Border.all(
            color: personal
                ? personalDesktopGlassRim(Theme.of(context))
                : (isDark
                      ? AppColors.glassBorderDarkMode
                      : AppColors.glassBorder),
            width: 1,
          ),
        );
        foregroundColor = personal
            ? personalDesktopAccentText(Theme.of(context))
            : AppColors.primary;
      case AppButtonVariant.ghost:
        // hover 时叠加 primary 8%
        decoration = BoxDecoration(
          color: _hovering
              ? AppColors.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: radius,
        );
        foregroundColor = personal
            ? personalDesktopAccentText(Theme.of(context))
            : AppColors.primary;
      case AppButtonVariant.danger:
        decoration = BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.danger, Color(0xFFE53935)],
          ),
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: AppColors.danger.withValues(alpha: 0.28),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        );
        foregroundColor = AppColors.onPrimary;
      case AppButtonVariant.disabled:
        decoration = BoxDecoration(
          color: isDark
              ? AppColors.surfaceVariantDark
              : AppColors.surfaceVariant,
          borderRadius: radius,
        );
        foregroundColor = isDark
            ? AppColors.textTertiaryDark
            : AppColors.textTertiary;
    }

    // 仅 primary / danger 显示顶部高光
    final showHighlight =
        variant == AppButtonVariant.primary ||
        variant == AppButtonVariant.danger;

    // 内容：可选图标 + 文字
    Widget content = Text(
      widget.label,
      style: TextStyle(
        color: foregroundColor,
        fontSize: widget.compact ? 12 : 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        height: 1.2,
      ),
    );
    if (widget.icon != null) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconTheme(
            data: IconThemeData(
              color: foregroundColor,
              size: widget.compact ? 16 : 18,
            ),
            child: widget.icon!,
          ),
          SizedBox(width: widget.compact ? AppSpacing.xs : AppSpacing.sm),
          content,
        ],
      );
    }

    return MouseRegion(
      cursor: _isDisabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: _isDisabled ? null : (_) => setState(() => _hovering = true),
      onExit: _isDisabled ? null : (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTapDown: _isDisabled ? null : (_) => setState(() => _tapping = true),
        onTapUp: _isDisabled
            ? null
            : (_) {
                setState(() => _tapping = false);
                widget.onPressed?.call();
              },
        onTapCancel: _isDisabled
            ? null
            : () => setState(() => _tapping = false),
        child: AnimatedScale(
          scale: _tapping && motionEnabled ? 0.97 : 1.0,
          duration: AppMotion.duration(context, AppCurves.durationTap),
          curve: AppCurves.curveTap,
          child: AnimatedContainer(
            duration: AppMotion.duration(context, AppCurves.durationHover),
            curve: AppCurves.curveHover,
            transform:
                motionEnabled &&
                    _hovering &&
                    (variant == AppButtonVariant.primary ||
                        variant == AppButtonVariant.danger)
                ? Matrix4.translationValues(0, -1, 0)
                : Matrix4.identity(),
            constraints: BoxConstraints(minHeight: widget.compact ? 34 : 42),
            // antiAlias 让顶部高光被圆角裁切
            clipBehavior: Clip.antiAlias,
            decoration: decoration,
            child: Stack(
              children: [
                // 顶部白色高光 inset：模拟受光（白 35% → 透明）
                if (showHighlight)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Container(
                      height: widget.compact ? 9 : 12,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withValues(
                              alpha: personal ? 0.12 : 0.35,
                            ),
                            Colors.white.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.compact ? 13 : 22,
                      vertical: widget.compact ? 8 : 12,
                    ),
                    child: content,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
