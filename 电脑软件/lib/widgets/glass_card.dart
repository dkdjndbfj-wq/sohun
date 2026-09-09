import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/app_curves.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/personal_desktop_theme.dart';
import '../data/prefs/app_prefs.dart';

/// 苹果风格毛玻璃卡片。
///
/// 立体玻璃质感三要素：
/// 1. BackdropFilter 高斯模糊（sigmaX/Y = 30）—— 真毛玻璃。
/// 2. 顶部边缘高光 —— 模拟光源从上方照射的 1px 反光带。
/// 3. 分层阴影（ambient 环境光 + key 主光）—— 细腻光影层次。
///
/// v4 新增：
/// - [level] 三级玻璃（L1 轻 / L2 中 / L3 重），自动适配亮/暗模式
/// - [enableHover] 悬浮抬升 -3px + shadow3，easeOutCubic 220ms
/// - 暗色模式自动切换 glassFillDark / glassBorderDarkMode
///
/// 配合 [AppBackground] 的彩色 mesh 光斑使用，模糊效果最佳。
class GlassCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final BorderRadius? borderRadius;
  final VoidCallback? onTap;
  final Color? color;
  final List<BoxShadow>? boxShadow;
  final bool showBorder;
  final bool showHighlight;
  final double blur;
  final double opacity;

  /// 玻璃层级：L1 轻（列表项）/ L2 中（标准卡）/ L3 重（弹窗）。
  /// 默认 L2。仅当 [color] 为 null 时生效。
  final GlassLevel level;

  /// 是否启用悬浮抬升动效（桌面端鼠标 hover）。
  /// 仅当 [onTap] 非空时生效。默认 true。
  final bool enableHover;

  /// Overrides the default hover behavior. In [GlassHoverEffect.auto] mode,
  /// clickable cards lift while non-clickable L2 cards only deepen shadow.
  final GlassHoverEffect hoverEffect;

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius,
    this.onTap,
    this.color,
    this.boxShadow,
    this.showBorder = true,
    this.showHighlight = true,
    this.blur = 18,
    this.opacity = 0.72,
    this.level = GlassLevel.l2,
    this.enableHover = true,
    this.hoverEffect = GlassHoverEffect.auto,
  });

  @override
  State<GlassCard> createState() => _GlassCardState();
}

/// 玻璃层级。
enum GlassLevel { l1, l2, l3 }

enum GlassHoverEffect { auto, none, shadow, lift }

class _GlassCardState extends State<GlassCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final personal = PersonalDesktopTheme.of(context);
    // Explicit fills/opacities remain authoritative for status and modal cards.
    final opacity =
        personal != null && widget.color == null && widget.opacity == 0.72
        ? (widget.level == GlassLevel.l3
              ? (isDark ? 0.88 : 0.82)
              : personal.cardOpacity)
        : widget.opacity;
    final radius =
        widget.borderRadius ??
        BorderRadius.circular(personal?.radius ?? AppColors.radiusLg);

    // 按层级 + 模式选填充色
    final Color fill;
    if (widget.color != null) {
      fill = widget.color!;
    } else {
      switch (widget.level) {
        case GlassLevel.l1:
          fill = isDark ? AppColors.glassFillL1Dark : AppColors.glassFillL1;
        case GlassLevel.l2:
          fill = isDark ? AppColors.glassFillL2Dark : AppColors.glassFillL2;
        case GlassLevel.l3:
          fill = isDark ? AppColors.glassFillL3Dark : AppColors.glassFillL3;
      }
    }
    final border = isDark
        ? AppColors.glassBorderDarkMode
        : AppColors.glassBorder;
    final baseShadow =
        widget.boxShadow ??
        (personal != null
            ? (isDark ? AppColors.shadow1Dark : AppColors.shadowCard)
            : (isDark ? AppColors.shadow2Dark : AppColors.shadow2));
    final hoverShadow = personal != null
        ? (isDark ? AppColors.shadow2Dark : AppColors.shadow2)
        : (isDark ? AppColors.shadow3Dark : AppColors.shadow3);

    final motionEnabled = AppMotion.enabled(context);
    final effect = switch (widget.hoverEffect) {
      GlassHoverEffect.auto => switch (widget.level) {
        GlassLevel.l1 =>
          widget.onTap == null
              ? GlassHoverEffect.none
              : GlassHoverEffect.shadow,
        GlassLevel.l2 =>
          widget.onTap == null
              ? GlassHoverEffect.shadow
              : GlassHoverEffect.lift,
        GlassLevel.l3 => GlassHoverEffect.none,
      },
      final explicit => explicit,
    };
    final canHover =
        widget.enableHover && motionEnabled && effect != GlassHoverEffect.none;
    final hovering = canHover && _hovering;
    final shadow = hovering ? hoverShadow : baseShadow;
    final shouldLift = hovering && effect == GlassHoverEffect.lift;

    return AppInteractionSurface(
      enabled: widget.onTap != null,
      hoverScale: 1,
      pressedScale: 0.992,
      hoverOffset: Offset.zero,
      child: MouseRegion(
        onEnter: canHover ? (_) => setState(() => _hovering = true) : null,
        onExit: canHover ? (_) => setState(() => _hovering = false) : null,
        cursor: widget.onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        child: AnimatedContainer(
          duration: AppMotion.duration(context, AppCurves.durationHover),
          curve: AppCurves.curveHover,
          transform: shouldLift
              ? Matrix4.translationValues(0, -3, 0)
              : Matrix4.identity(),
          margin: widget.margin,
          decoration: BoxDecoration(borderRadius: radius, boxShadow: shadow),
          child: ClipRRect(
            borderRadius: radius,
            // Only modal L3 surfaces need live background blur. Standard cards
            // use the same translucent material without forcing an expensive
            // full backdrop pass on every repaint.
            child: widget.level != GlassLevel.l3
                ? _glassContent(fill, border, radius, isDark, opacity)
                : BackdropFilter(
                    filter: ImageFilter.blur(
                      sigmaX: widget.blur,
                      sigmaY: widget.blur,
                    ),
                    child: _glassContent(fill, border, radius, isDark, opacity),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _glassContent(
    Color fill,
    Color border,
    BorderRadius radius,
    bool isDark,
    double opacity,
  ) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            fill.withValues(alpha: (opacity + 0.08).clamp(0.0, 1.0)),
            fill.withValues(alpha: opacity),
          ],
        ),
        borderRadius: radius,
        border: widget.showBorder ? Border.all(color: border, width: 1) : null,
      ),
      child: Stack(
        children: [
          if (widget.showHighlight)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _TopEdgeHighlight(radius: radius, isDark: isDark),
            ),
          Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: radius,
              child: Padding(
                padding: widget.padding ?? const EdgeInsets.all(16),
                child: widget.child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部边缘高光：左右透明 → 中间白色高光，模拟玻璃受光反射。
/// 暗色模式下高光更弱（0.3）。
class _TopEdgeHighlight extends StatelessWidget {
  final BorderRadius radius;
  final bool isDark;
  const _TopEdgeHighlight({required this.radius, this.isDark = false});

  @override
  Widget build(BuildContext context) {
    final peak = isDark ? 0.3 : 0.85;
    return ClipRRect(
      borderRadius: BorderRadius.only(
        topLeft: radius.topLeft,
        topRight: radius.topRight,
      ),
      child: Container(
        height: 1.2,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.white.withValues(alpha: 0),
              Colors.white.withValues(alpha: peak),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
      ),
    );
  }
}

/// 安静的桌面工作区底色。可选装饰使用低对比度构建板网格，呼应 3D 打印领域。
class AppBackground extends ConsumerWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final showGrid = ref.watch(bgDecorationEnabledProvider);
    final background = isDark
        ? const Color(0xFF171A18)
        : const Color(0xFFF4F6F5);
    final gridColor = (isDark ? Colors.white : AppColors.textPrimary)
        .withValues(alpha: isDark ? 0.035 : 0.028);
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: background)),
        if (showGrid)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _BuildPlateGridPainter(gridColor)),
            ),
          ),
        Positioned.fill(child: child),
      ],
    );
  }
}

class _BuildPlateGridPainter extends CustomPainter {
  final Color color;
  const _BuildPlateGridPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const spacing = 32.0;
    for (var x = 0.5; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.5; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_BuildPlateGridPainter oldDelegate) =>
      color != oldDelegate.color;
}
