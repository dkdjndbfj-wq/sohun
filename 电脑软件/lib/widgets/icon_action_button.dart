import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/glass_button_theme.dart';
import 'app_glass_button.dart';
import 'glass_button_material.dart';
import 'bambu_icon.dart';

/// 通用图标操作按钮（v5 升级：hover 背景变化 + 可选拓竹 SVG 图标）。
///
/// 圆形浅底 + 语义色图标 + 涟漪。用于卡片右上角的删除/更多操作入口。
///
/// v5 变更：
/// - 新增 [bambuIconName]：使用拓竹 SVG 图标替代 IconData
/// - hover 时背景色加深（MouseRegion + AnimatedContainer）
/// - 220ms easeOutCubic 过渡
class IconActionButton extends StatefulWidget {
  final IconData? icon;
  final String? bambuIconName;
  final VoidCallback? onTap;
  final Color? color;
  final Color? background;
  final double size;
  final String? tooltip;

  const IconActionButton({
    super.key,
    this.icon,
    this.bambuIconName,
    this.onTap,
    this.color,
    this.background,
    this.size = 32,
    this.tooltip,
  }) : assert(
         icon != null || bambuIconName != null,
         '必须提供 icon 或 bambuIconName 之一',
       );

  @override
  State<IconActionButton> createState() => _IconActionButtonState();
}

class _IconActionButtonState extends State<IconActionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg =
        widget.color ??
        (isDark ? AppColors.textTertiaryDark : AppColors.textTertiary);
    if (GlassButtonsTheme.enabledOf(context)) {
      final ink = GlassButtonPalette.resolve(
        Theme.of(context),
        variant: AppGlassButtonVariant.quiet,
        enabled: widget.onTap != null,
        tint: widget.color,
      ).foreground;
      return AppGlassButton(
        label: widget.tooltip ?? '操作',
        tooltip: widget.tooltip,
        onPressed: widget.onTap,
        variant: AppGlassButtonVariant.quiet,
        tint: widget.color,
        padding: EdgeInsets.zero,
        minimumSize: Size.square(widget.size),
        borderRadius: BorderRadius.circular(widget.size / 2),
        child: widget.bambuIconName != null
            ? BambuIcon(
                name: widget.bambuIconName!,
                size: widget.size * .5,
                color: ink,
                applyColorFilter: true,
              )
            : Icon(widget.icon, size: widget.size * .5, color: ink),
      );
    }
    final baseBg = widget.background ?? Colors.transparent;
    // hover 时背景透明度提升（如 0.08 → 0.15）
    final hoverBg = baseBg == Colors.transparent
        ? fg.withValues(alpha: _isHovered ? 0.15 : 0.0)
        : Color.lerp(baseBg, fg, _isHovered ? 0.15 : 0.0) ?? baseBg;

    return Tooltip(
      message: widget.tooltip ?? '',
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: widget.onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppCurves.durationHover),
          curve: Curves.easeOutCubic,
          transform: AppMotion.enabled(context) && _isHovered
              ? Matrix4.diagonal3Values(1.05, 1.05, 1)
              : Matrix4.identity(),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(color: hoverBg, shape: BoxShape.circle),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              child: SizedBox(
                width: widget.size,
                height: widget.size,
                child: Center(
                  child: widget.bambuIconName != null
                      ? BambuIcon(
                          name: widget.bambuIconName!,
                          size: widget.size * 0.5,
                          color: fg,
                          applyColorFilter: true,
                        )
                      : Icon(widget.icon, size: widget.size * 0.5, color: fg),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 删除按钮：浅红底 + 红色图标。
class DeleteActionButton extends StatelessWidget {
  final VoidCallback? onTap;
  final double size;
  final String? tooltip;
  final String? bambuIconName;

  const DeleteActionButton({
    super.key,
    this.onTap,
    this.size = 32,
    this.tooltip,
    this.bambuIconName,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IconActionButton(
      icon: bambuIconName == null ? Icons.delete_outline_rounded : null,
      bambuIconName: bambuIconName ?? 'delete_filament',
      onTap: onTap,
      color: AppColors.danger,
      background: isDark
          ? AppColors.danger.withValues(alpha: 0.15)
          : AppColors.dangerContainer,
      size: size,
      tooltip: tooltip ?? '删除',
    );
  }
}

/// 更多操作按钮（三点）。浅灰底 + 灰色图标。
class MoreActionButton extends StatelessWidget {
  final VoidCallback? onTap;
  final double size;

  const MoreActionButton({super.key, this.onTap, this.size = 32});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return IconActionButton(
      icon: Icons.more_horiz_rounded,
      onTap: onTap,
      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
      background: isDark
          ? AppColors.surfaceVariantDark
          : AppColors.surfaceVariant,
      size: size,
    );
  }
}
