import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 几何单线艺术字标。
///
/// 五个字母都由圆头路径绘制，线条语言来自一根连续耗材丝：有品牌感，但不
/// 使用装饰下划线、随机字形或运行时字体切换。启动页和工作台共享这个组件，
/// 因而可以在窗口展开时精确归位。
class SohunWordmark extends StatelessWidget {
  const SohunWordmark({
    super.key,
    this.progress = 1,
    this.startColor,
    this.endColor,
    this.glow = false,
    this.glowStrength,
  });

  final double progress;
  final Color? startColor;
  final Color? endColor;
  final bool glow;
  final double? glowStrength;

  static const aspectRatio = 3.2;
  static const designSize = Size(320, 100);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Sohun',
      value: '${(progress.clamp(0, 1) * 100).round()}%',
      child: RepaintBoundary(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            key: const ValueKey('sohun-wordmark'),
            width: designSize.width,
            height: designSize.height,
            child: CustomPaint(
              painter: SohunWordmarkPainter(
                progress: progress.clamp(0, 1),
                startColor: startColor ?? scheme.primary,
                endColor: endColor ?? scheme.secondary,
                glowStrength: (glowStrength ?? (glow ? 1.0 : 0.0)).clamp(0, 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 标题栏使用的普通字标。
///
/// 主视觉使用艺术字，窗口左上角保持安静的系统字体，避免品牌元素在一个
/// 画面里重复争抢注意力。颜色仍复用同一主题渐变。
class SohunTitleWordmark extends StatelessWidget {
  const SohunTitleWordmark({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Sohun',
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        child: ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            colors: [scheme.primary, scheme.secondary],
          ).createShader(bounds),
          child: const Text(
            'Sohun',
            style: TextStyle(
              color: Colors.white,
              fontFamily: 'Segoe UI Variable Display',
              fontSize: 15,
              height: 1,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.45,
            ),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class SohunWordmarkPainter extends CustomPainter {
  const SohunWordmarkPainter({
    required this.progress,
    required this.startColor,
    required this.endColor,
    required this.glowStrength,
  });

  static const _letterStarts = <double>[0, 0.14, 0.29, 0.44, 0.59];
  static const _letterDuration = 0.31;
  static const _strokeWidth = 13.0;

  final double progress;
  final Color startColor;
  final Color endColor;
  final double glowStrength;

  @visibleForTesting
  int get revealedLetterCount => [
        for (var index = 0; index < _letterStarts.length; index++)
          if (letterProgress(index) > 0) index,
      ].length;

  @visibleForTesting
  double letterProgress(int index) {
    return Curves.easeOutCubic.transform(
      ((progress - _letterStarts[index]) / _letterDuration).clamp(0, 1),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || progress <= 0) return;
    final scale = math.min(
      size.width / SohunWordmark.designSize.width,
      size.height / SohunWordmark.designSize.height,
    );
    final origin = Offset(
      (size.width - SohunWordmark.designSize.width * scale) / 2,
      (size.height - SohunWordmark.designSize.height * scale) / 2,
    );
    canvas
      ..save()
      ..translate(origin.dx, origin.dy)
      ..scale(scale);

    final paths = _letterPaths();
    const markBounds = Rect.fromLTWH(12, 16, 294, 70);
    final gradient = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        startColor,
        Color.lerp(startColor, endColor, 0.54)!,
        endColor,
      ],
      stops: const [0, 0.56, 1],
    ).createShader(markBounds);

    // 极轻的落影只用于从复杂背景中分离字标，不制造霓虹感。
    canvas
      ..save()
      ..translate(0, 2);
    _paintPaths(
      canvas,
      paths,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = _strokeWidth + 1.5
        ..color = const Color(0xFF07130E).withValues(alpha: 0.15),
    );
    canvas.restore();

    if (glowStrength > 0) {
      _paintPaths(
        canvas,
        paths,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..strokeWidth = _strokeWidth + 5
          ..color = startColor.withValues(alpha: 0.16 * glowStrength)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }

    _paintPaths(
      canvas,
      paths,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = _strokeWidth
        ..shader = gradient,
    );

    // 一条克制的内侧高光让单线字标像半透明耗材，而不是纯色粗线。
    _paintPaths(
      canvas,
      paths,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 2.2
        ..color = Colors.white.withValues(alpha: 0.24),
    );
    canvas.restore();
  }

  List<Path> _letterPaths() {
    return [
      Path()
        ..moveTo(56, 30)
        ..cubicTo(48, 20, 24, 21, 17, 33)
        ..cubicTo(10, 46, 20, 51, 36, 53)
        ..cubicTo(52, 55, 58, 62, 52, 71)
        ..cubicTo(44, 82, 21, 81, 13, 72),
      Path()
        ..moveTo(116, 52)
        ..cubicTo(116, 70, 106, 79, 91, 79)
        ..cubicTo(76, 79, 66, 69, 66, 52)
        ..cubicTo(66, 35, 76, 25, 91, 25)
        ..cubicTo(106, 25, 116, 35, 116, 52)
        ..close(),
      Path()
        ..moveTo(136, 20)
        ..lineTo(136, 78)
        ..moveTo(136, 51)
        ..cubicTo(143, 34, 169, 34, 174, 51)
        ..cubicTo(176, 57, 175, 67, 175, 78),
      Path()
        ..moveTo(197, 38)
        ..lineTo(197, 61)
        ..cubicTo(197, 74, 204, 80, 216, 80)
        ..cubicTo(228, 80, 235, 73, 235, 60)
        ..lineTo(235, 38),
      Path()
        ..moveTo(257, 78)
        ..lineTo(257, 39)
        ..moveTo(257, 51)
        ..cubicTo(264, 34, 290, 34, 296, 51)
        ..cubicTo(298, 57, 297, 68, 297, 78),
    ];
  }

  void _paintPaths(Canvas canvas, List<Path> paths, Paint paint) {
    for (var index = 0; index < paths.length; index++) {
      final localProgress = letterProgress(index);
      if (localProgress <= 0) continue;
      if (localProgress >= 1) {
        canvas.drawPath(paths[index], paint);
      } else {
        canvas.drawPath(
          _extractPartialPath(paths[index], localProgress),
          paint,
        );
      }
    }
  }

  Path _extractPartialPath(Path source, double fraction) {
    final metrics = source.computeMetrics().toList(growable: false);
    final totalLength = metrics.fold<double>(
      0,
      (sum, metric) => sum + metric.length,
    );
    var remaining = totalLength * fraction.clamp(0, 1);
    final result = Path();
    for (final metric in metrics) {
      if (remaining <= 0) break;
      final length = math.min(metric.length, remaining);
      result.addPath(metric.extractPath(0, length), Offset.zero);
      remaining -= length;
    }
    return result;
  }

  @override
  bool shouldRepaint(SohunWordmarkPainter oldDelegate) {
    return progress != oldDelegate.progress ||
        startColor != oldDelegate.startColor ||
        endColor != oldDelegate.endColor ||
        glowStrength != oldDelegate.glowStrength;
  }
}
