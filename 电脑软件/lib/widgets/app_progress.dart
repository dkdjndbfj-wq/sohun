import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/interaction_effects.dart';

/// 苹果风格进度条，带光流动效。
///
/// 填充使用 [AppColors.primary]→[AppColors.accent]→[AppColors.primary] 渐变，
/// 沿 x 轴循环移动（2.5s 一个周期），配合外发光（primary 40% + blur）营造流动质感。
/// 细条变体：将 [thickness] 设为 4，发光与光流相应变细。支持暗色模式。
class AppProgress extends StatefulWidget {
  /// 当前进度值，范围 0.0-1.0。
  final double value;

  /// 进度条厚度，默认 8。设为 4 得到细条变体。
  final double thickness;

  /// 是否显示外发光，默认 true。
  final bool showGlow;

  /// 是否播放渐变流动。可用于只在悬停或真实状态变化时启用，避免静止页面
  /// 持续占用合成资源。
  final bool animate;

  const AppProgress({
    super.key,
    required this.value,
    this.thickness = 8,
    this.showGlow = true,
    this.animate = true,
  });

  @override
  State<AppProgress> createState() => _AppProgressState();
}

class _AppProgressState extends State<AppProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: AppCurves.durationProgressFlow,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant AppProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _syncAnimation();
  }

  void _syncAnimation() {
    final shouldAnimate = widget.animate && AppMotion.enabled(context);
    if (shouldAnimate) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    // 释放 AnimationController，避免内存泄漏
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final value = widget.value.clamp(0.0, 1.0);
    final trackColor =
        isDark ? AppColors.surfaceVariantDark : AppColors.surfaceVariant;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: widget.thickness,
          child: Stack(
            children: [
              // 背景轨道
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: trackColor,
                    borderRadius: BorderRadius.circular(AppColors.radiusFull),
                  ),
                ),
              ),
              // 填充 + 光流
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: width * value,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) {
                    final t = _controller.value;
                    // 渐变沿 x 轴循环移动：span 200%（2 个对齐单位），
                    // 每周期移动一个周期宽度，实现无缝循环。
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment(t * 2 - 1, 0),
                          end: Alignment(t * 2 + 1, 0),
                          colors: [
                            AppColors.primary,
                            AppColors.accent,
                            AppColors.primary,
                          ],
                          tileMode: TileMode.repeated,
                        ),
                        borderRadius:
                            BorderRadius.circular(AppColors.radiusFull),
                        boxShadow: widget.showGlow
                            ? [
                                BoxShadow(
                                  color: AppColors.primary.withValues(
                                    alpha: isDark ? 0.55 : 0.4,
                                  ),
                                  blurRadius:
                                      widget.thickness * (isDark ? 1.5 : 1.0),
                                ),
                              ]
                            : null,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
