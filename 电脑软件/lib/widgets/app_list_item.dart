import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/app_spacing.dart';
import '../core/theme/interaction_effects.dart';

/// macOS Sonoma 风格列表项。
///
/// 水平布局：leading 头像/图标（28x28，radiusSm 圆角）+ 主副文字 + trailing。
/// 点击时 InkWell ripple + hover 背景色（primary 6%）。圆角 radiusMd。支持暗色模式。
class AppListItem extends StatefulWidget {
  /// 前置图标/头像（调用方传真实图片如 PrinterImage 或 CircleAvatar）。
  /// 会被约束到 28x28 并以 radiusSm 圆角裁剪。
  final Widget? leading;

  /// 主标题（必填）。字号 13 w700。
  final String title;

  /// 副标题（可选）。字号 11 w400。
  final String? subtitle;

  /// 尾部控件。
  final Widget? trailing;

  /// 点击回调。为空时不可点击、不显示 hover 态。
  final VoidCallback? onTap;

  const AppListItem({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  @override
  State<AppListItem> createState() => _AppListItemState();
}

class _AppListItemState extends State<AppListItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final canHover = widget.onTap != null;
    final hovering = canHover && _hovering;

    // hover 背景：primary 6%
    final hoverColor = AppColors.primary.withValues(alpha: 0.06);
    final titleColor =
        isDark ? AppColors.textPrimaryDark : AppColors.textPrimary;
    final subtitleColor =
        isDark ? AppColors.textTertiaryDark : AppColors.textTertiary;

    return MouseRegion(
      cursor: canHover ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: canHover ? (_) => setState(() => _hovering = true) : null,
      onExit: canHover ? (_) => setState(() => _hovering = false) : null,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppCurves.durationHover),
        curve: AppCurves.curveHover,
        decoration: BoxDecoration(
          color: hovering ? hoverColor : Colors.transparent,
          borderRadius: BorderRadius.circular(AppColors.radiusMd),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(AppColors.radiusMd),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  // leading 头像/图标：28x28，radiusSm 圆角
                  if (widget.leading != null) ...[
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppColors.radiusSm),
                        child: widget.leading!,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                  ],
                  // 主副文字
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: titleColor,
                          ),
                        ),
                        if (widget.subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: subtitleColor,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // trailing 尾部控件
                  if (widget.trailing != null) ...[
                    const SizedBox(width: AppSpacing.md),
                    widget.trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
