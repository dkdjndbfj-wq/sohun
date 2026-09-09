import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/interaction_effects.dart';

/// 苹果风格开关，替换 Material Switch。
///
/// 自绘：Container 宽 36 高 20，圆角 radiusFull。
/// 关闭态背景 surfaceVariant；开启态背景 primary + 外发光（primary 40% blur 6）。
/// 旋钮：白色圆 16x16，shadow2 阴影；开启时向右移动 16px（left 2 → left 18）。
/// 切换动效：AnimatedContainer 切换背景色 + AnimatedPositioned 移动旋钮。
/// onChanged 为 null 时禁用，整体 opacity 0.5。
class AppSwitch extends StatefulWidget {
  /// 当前是否开启。
  final bool value;

  /// 切换回调；为 null 时禁用（opacity 0.5）。
  final ValueChanged<bool>? onChanged;

  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<AppSwitch> createState() => _AppSwitchState();
}

class _AppSwitchState extends State<AppSwitch> {
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDisabled = widget.onChanged == null;
    final value = widget.value;

    // 关闭态背景：暗色用 surfaceVariantDark
    final Color bgOff =
        isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant;
    final Color bgOn = AppColors.primary;
    final Color bg = value ? bgOn : bgOff;

    // 开启态外发光
    final List<BoxShadow> boxShadow = value
        ? [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.40),
              blurRadius: 6,
              offset: const Offset(0, 0),
            ),
          ]
        : const [];

    return MouseRegion(
      cursor: isDisabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: isDisabled ? null : () => widget.onChanged!(!value),
        child: AnimatedOpacity(
          duration: AppMotion.duration(context, AppCurves.durationHover),
          curve: AppCurves.curveHover,
          opacity: isDisabled ? 0.5 : 1.0,
          child: SizedBox(
            width: 36,
            height: 20,
            child: AnimatedContainer(
              duration: AppMotion.duration(context, AppCurves.durationHover),
              curve: AppCurves.curveHover,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(AppColors.radiusFull),
                boxShadow: boxShadow,
              ),
              child: Stack(
                children: [
                  // 旋钮：开启时 left 18，关闭时 left 2
                  AnimatedPositioned(
                    duration:
                        AppMotion.duration(context, AppCurves.durationHover),
                    curve: AppCurves.curveHover,
                    left: value ? 18 : 2,
                    top: 2,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: AppColors.shadow2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
