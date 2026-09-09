import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';

/// 剩余量进度条（v5 升级：渐变光流风格 + 圆角 + 按比例变色）。
///
/// 替代原版 LinearProgressIndicator，用 Container + AnimatedContainer
/// 实现与 AppProgress 一致的渐变光流风格，适配亮色模式。
class StockBar extends StatelessWidget {
  final double remaining;
  final double total;
  final double height;

  /// 是否启用渐变光流效果。默认 true。
  final bool enableGradient;

  const StockBar({
    super.key,
    required this.remaining,
    required this.total,
    this.height = 8,
    this.enableGradient = true,
  });

  double get _ratio => total <= 0 ? 0 : (remaining / total).clamp(0.0, 1.0);

  Color get _color {
    if (remaining <= 0) return AppColors.stockEmpty;
    if (_ratio > 0.5) return AppColors.stockFull;
    if (_ratio > 0.2) return AppColors.stockMid;
    return AppColors.stockLow;
  }

  /// 渐变副色（比主色更亮）。
  Color get _accentColor {
    final base = _color;
    return Color.lerp(base, Colors.white, 0.35) ?? base;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark
        ? AppColors.surfaceVariantDark
        : AppColors.surfaceContainerHighest;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            // 背景
            Positioned.fill(
              child: Container(color: bgColor),
            ),
            // 前景进度
            FractionallySizedBox(
              widthFactor: _ratio,
              child: Container(
                decoration: enableGradient
                    ? BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [_color, _accentColor],
                        ),
                      )
                    : BoxDecoration(color: _color),
              ),
            ),
            // 高光条（顶部 1px 反光，模拟玻璃质感）
            if (_ratio > 0.05)
              FractionallySizedBox(
                widthFactor: _ratio,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Colors.white.withValues(alpha: 0),
                          Colors.white.withValues(alpha: 0.5),
                          Colors.white.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
