import 'package:flutter/material.dart';

/// 拓竹风格耗材卷侧视图图标。
///
/// **精确复刻** BambuStudio `resources/images/filament_green.svg` 的设计，
/// 直接使用原版 SVG 的 path 数据，确保与拓竹切片软件"发送打印任务"
/// 对话框里的耗材丝图标完全一致。
///
/// 原版 SVG 由 6 个元素组成（viewBox 30x40）：
/// 1. 右侧卷轴外圈填充（path，fill=#F2F2F2 浅灰）
/// 2. 右侧卷轴外圈描边（path，stroke=#5C5C5C 灰色）
/// 3. 中间耗材丝缠绕区填充（path，fill=动态颜色）
/// 4. 中间耗材丝缠绕区描边（path，stroke=#5C5C5C 灰色）
/// 5. 左侧卷轴外圈（ellipse cx=6.514 cy=19.786 rx=3.927 ry=17.727，fill+#5C5C5C stroke）
/// 6. 左侧卷轴中心孔（ellipse cx=6.212 cy=20.081 rx=0.604 ry=2.659，fill=#5C5C5C）
///
/// 耗材颜色通过 [color] 参数动态设置，对应切片时选择的耗材颜色。
///
/// **尺寸**：原始 viewBox 为 30x40，宽高比 3:4。使用时通过 [size] 参数
/// 指定宽度，高度按比例自动计算（size × 4/3）。
class FilamentSpoolIcon extends StatelessWidget {
  /// 耗材颜色（切片时选择的颜色）。
  /// null 时显示灰色占位（未知颜色）。
  final Color? color;

  /// 图标宽度（像素）。高度自动按 4/3 比例计算。
  /// 默认 30，与拓竹原始 SVG 尺寸一致。
  final double size;

  /// 是否显示卷轴中心孔。
  /// 默认 true。小尺寸（<16）时可关闭避免糊成一团。
  final bool showCenterHole;

  /// Adds restrained depth and winding lines for large illustrative previews.
  /// It does not infer or imitate a material finish.
  final bool dimensional;

  const FilamentSpoolIcon({
    super.key,
    required this.color,
    this.size = 30,
    this.showCenterHole = true,
    this.dimensional = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 灰色调色板（与拓竹 SVG 一致：#5C5C5C 边框 + #F2F2F2 填充）
    final strokeColor =
        isDark ? const Color(0xFF8A8A8A) : const Color(0xFF5C5C5C);
    final reelFillColor =
        isDark ? const Color(0xFF3A3A3A) : const Color(0xFFF2F2F2);
    final filamentColor =
        color ?? (isDark ? const Color(0xFF555555) : const Color(0xFFCCCCCC));

    final height = size * 40 / 30;
    return SizedBox(
      width: size,
      height: height,
      child: CustomPaint(
        painter: _FilamentSpoolPainter(
          filamentColor: filamentColor,
          strokeColor: strokeColor,
          reelFillColor: reelFillColor,
          showCenterHole: showCenterHole,
          dimensional: dimensional,
        ),
      ),
    );
  }
}

class _FilamentSpoolPainter extends CustomPainter {
  final Color filamentColor;
  final Color strokeColor;
  final Color reelFillColor;
  final bool showCenterHole;
  final bool dimensional;

  _FilamentSpoolPainter({
    required this.filamentColor,
    required this.strokeColor,
    required this.reelFillColor,
    required this.showCenterHole,
    required this.dimensional,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 原始 SVG viewBox: 30 x 40，按比例缩放到当前 size
    final s = size.width / 30;
    canvas.save();
    canvas.scale(s);

    const strokeWidth = 2.0;

    // === 1. 右侧卷轴外圈填充 ===
    // 原版 path: M23.2596 37.5131 C25.5229 37.5131 27.3577 29.5764 27.3577 19.7859
    //   C27.3577 9.99536 25.5229 2.05859 23.2596 2.05859
    //   C22.3784 2.05859 21.3802 3.55703 20.7119 5.60405
    //   H22.2969 C22.7771 6.93611 23.7442 11.4734 23.7442 20.5097
    //   C23.7442 29.546 22.4689 33.0115 22.2969 34.0043
    //   H20.8278 C21.5273 36.4088 22.2967 37.5131 23.2596 37.5131 Z
    final rightReelFillPath = Path()
      ..moveTo(23.2596, 37.5131)
      ..cubicTo(25.5229, 37.5131, 27.3577, 29.5764, 27.3577, 19.7859)
      ..cubicTo(27.3577, 9.99536, 25.5229, 2.05859, 23.2596, 2.05859)
      ..cubicTo(22.3784, 2.05859, 21.3802, 3.55703, 20.7119, 5.60405)
      ..lineTo(22.2969, 5.60405)
      ..cubicTo(22.7771, 6.93611, 23.7442, 11.4734, 23.7442, 20.5097)
      ..cubicTo(23.7442, 29.546, 22.4689, 33.0115, 22.2969, 34.0043)
      ..lineTo(20.8278, 34.0043)
      ..cubicTo(21.5273, 36.4088, 22.2967, 37.5131, 23.2596, 37.5131)
      ..close();

    canvas.drawPath(
      rightReelFillPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = reelFillColor,
    );

    // === 2. 右侧卷轴外圈描边 ===
    // 原版 path: M20.7119 5.60405 C21.3802 3.55703 22.3784 2.05859 23.2596 2.05859
    //   C25.5229 2.05859 27.3577 9.99536 27.3577 19.7859
    //   C27.3577 29.5764 25.5229 37.5131 23.2596 37.5131
    //   C22.2967 37.5131 21.4114 36.0767 20.7119 33.6722
    final rightReelStrokePath = Path()
      ..moveTo(20.7119, 5.60405)
      ..cubicTo(21.3802, 3.55703, 22.3784, 2.05859, 23.2596, 2.05859)
      ..cubicTo(25.5229, 2.05859, 27.3577, 9.99536, 27.3577, 19.7859)
      ..cubicTo(27.3577, 29.5764, 25.5229, 37.5131, 23.2596, 37.5131)
      ..cubicTo(22.2967, 37.5131, 21.4114, 36.0767, 20.7119, 33.6722);

    canvas.drawPath(
      rightReelStrokePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = strokeColor
        ..strokeWidth = strokeWidth,
    );

    // === 3. 中间耗材丝缠绕区填充（动态颜色）===
    // 原版 path: M22.3311 5.60352 L8.93066 5.60352 L9.23275 6.78533
    //   L10.139 12.399 L10.4411 24.5126 L9.83691 30.4217 L8.93066 33.9672
    //   H22.3311 C23.1389 30.7196 23.7327 25.7062 23.7327 20.0808
    //   C23.7327 14.1019 23.2274 8.8144 22.3311 5.60352 Z
    final filamentFillPath = Path()
      ..moveTo(22.3311, 5.60352)
      ..lineTo(8.93066, 5.60352)
      ..lineTo(9.23275, 6.78533)
      ..lineTo(10.139, 12.399)
      ..lineTo(10.4411, 24.5126)
      ..lineTo(9.83691, 30.4217)
      ..lineTo(8.93066, 33.9672)
      ..lineTo(22.3311, 33.9672)
      ..cubicTo(23.1389, 30.7196, 23.7327, 25.7062, 23.7327, 20.0808)
      ..cubicTo(23.7327, 14.1019, 23.2274, 8.8144, 22.3311, 5.60352)
      ..close();

    canvas.drawPath(
      filamentFillPath,
      _filamentPaint(filamentFillPath.getBounds()),
    );
    _paintWinding(canvas, filamentFillPath);

    // === 4. 中间耗材丝缠绕区描边 ===
    // 原版 path: M8.62891 5.60352 L22.3115 5.60352
    //   C23.2206 8.8144 23.7331 14.1019 23.7331 20.0808
    //   C23.7331 25.7062 23.1308 30.7196 22.3115 33.9672 H8.62891
    final filamentStrokePath = Path()
      ..moveTo(8.62891, 5.60352)
      ..lineTo(22.3115, 5.60352)
      ..cubicTo(23.2206, 8.8144, 23.7331, 14.1019, 23.7331, 20.0808)
      ..cubicTo(23.7331, 25.7062, 23.1308, 30.7196, 22.3115, 33.9672)
      ..lineTo(8.62891, 33.9672);

    canvas.drawPath(
      filamentStrokePath,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = strokeColor
        ..strokeWidth = strokeWidth
        ..strokeJoin = StrokeJoin.round,
    );

    // === 5. 左侧卷轴外圈（椭圆）===
    // 原版: ellipse cx=6.514 cy=19.7859 rx=3.92708 ry=17.7273
    final leftReelRect = Rect.fromCenter(
      center: const Offset(6.514, 19.7859),
      width: 3.92708 * 2,
      height: 17.7273 * 2,
    );
    canvas.drawOval(
      leftReelRect,
      Paint()
        ..style = PaintingStyle.fill
        ..color = reelFillColor,
    );
    canvas.drawOval(
      leftReelRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = strokeColor
        ..strokeWidth = strokeWidth,
    );

    // === 6. 左侧卷轴中心孔（椭圆，实心灰色）===
    // 原版: ellipse cx=6.21159 cy=20.081 rx=0.604167 ry=2.65909
    if (showCenterHole) {
      final centerHoleRect = Rect.fromCenter(
        center: const Offset(6.21159, 20.081),
        width: 0.604167 * 2,
        height: 2.65909 * 2,
      );
      canvas.drawOval(
        centerHoleRect,
        Paint()..color = strokeColor,
      );
    }

    canvas.restore();
  }

  Paint _filamentPaint(Rect bounds) {
    if (!dimensional) {
      return Paint()
        ..style = PaintingStyle.fill
        ..color = filamentColor;
    }

    final light = Color.lerp(filamentColor, Colors.white, 0.20)!;
    final dark = Color.lerp(filamentColor, Colors.black, 0.24)!;
    return Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [dark, filamentColor, light, filamentColor, dark],
        stops: const [0.0, 0.24, 0.5, 0.72, 1.0],
      ).createShader(bounds);
  }

  void _paintWinding(Canvas canvas, Path filamentPath) {
    if (!dimensional) return;
    canvas
      ..save()
      ..clipPath(filamentPath);

    final ridgeColor =
        filamentColor.computeLuminance() < 0.34 ? Colors.white : Colors.black;
    final ridge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.28
      ..color = ridgeColor.withValues(alpha: 0.075);
    for (var y = 7.2; y < 34; y += 2.35) {
      final winding = Path()
        ..moveTo(8.7, y)
        ..quadraticBezierTo(16.0, y + 0.32, 23.4, y - 0.12);
      canvas.drawPath(winding, ridge);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FilamentSpoolPainter oldDelegate) {
    return oldDelegate.filamentColor != filamentColor ||
        oldDelegate.strokeColor != strokeColor ||
        oldDelegate.reelFillColor != reelFillColor ||
        oldDelegate.showCenterHole != showCenterHole ||
        oldDelegate.dimensional != dimensional;
  }
}
