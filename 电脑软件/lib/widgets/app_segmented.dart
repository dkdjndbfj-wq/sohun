import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/glass_button_theme.dart';
import 'app_glass_button.dart';

/// 分段控件的一个段。
class AppSegment<T> {
  /// 段文字。
  final String label;

  /// 段图标（可选）。
  final Widget? icon;

  /// 段对应的值。
  final T value;

  const AppSegment({required this.label, required this.value, this.icon});
}

/// macOS Sonoma 分段控件。
///
/// 玻璃容器（glassFillL1 + radiusMd + padding 3）内等宽排列各段。
/// 选中段：primaryContainer 背景 + primary 字 + radiusSm + shadow1，
/// 用 [AnimatedContainer] 切换（durationHover curveHover）。
/// 未选中段：透明背景 + textSecondary 字。支持暗色模式。
class AppSegmented<T> extends StatefulWidget {
  /// 所有段。
  final List<AppSegment<T>> segments;

  /// 当前选中值。
  final T value;

  /// 选中变化回调。
  final ValueChanged<T> onChanged;

  const AppSegmented({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  @override
  State<AppSegmented<T>> createState() => _AppSegmentedState<T>();
}

class _AppSegmentedState<T> extends State<AppSegmented<T>> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final containerColor = isDark
        ? AppColors.glassFillL1Dark
        : AppColors.glassFillL1;
    final borderColor = isDark
        ? AppColors.glassBorderDarkMode
        : AppColors.glassBorder;

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(AppColors.radiusMd),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Row(
        children: widget.segments
            .map((seg) {
              final selected = seg.value == widget.value;
              return Expanded(
                child: _SegmentTile(
                  segment: seg,
                  selected: selected,
                  isDark: isDark,
                  onTap: () => widget.onChanged(seg.value),
                ),
              );
            })
            .toList(growable: false),
      ),
    );
  }
}

/// 单个段。
class _SegmentTile extends StatelessWidget {
  final AppSegment<dynamic> segment;
  final bool selected;
  final bool isDark;
  final VoidCallback onTap;

  const _SegmentTile({
    required this.segment,
    required this.selected,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // 选中段背景：亮色 primaryContainer；暗色 primary 20%
    final selectedBg = isDark
        ? AppColors.primary.withValues(alpha: 0.2)
        : AppColors.primaryContainer;
    final selectedFg = AppColors.primary;
    final unselectedFg = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    if (GlassButtonsTheme.enabledOf(context)) {
      return Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        child: AppGlassButton(
          label: segment.label,
          icon: segment.icon,
          onPressed: onTap,
          compact: true,
          variant: selected
              ? AppGlassButtonVariant.primary
              : AppGlassButtonVariant.quiet,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          minimumSize: const Size(0, 28),
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
        ),
      );
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: AppMotion.duration(context, AppCurves.durationHover),
        curve: AppCurves.curveHover,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? selectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(AppColors.radiusSm),
          boxShadow: selected ? AppColors.shadow1 : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppColors.radiusSm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (segment.icon != null) ...[
                  IconTheme(
                    data: IconThemeData(
                      size: 14,
                      color: selected ? selectedFg : unselectedFg,
                    ),
                    child: segment.icon!,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  segment.label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? selectedFg : unselectedFg,
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
