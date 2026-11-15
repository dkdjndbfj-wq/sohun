import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The approved Mifu lettering, drawn as paths so it stays crisp at header size.
///
/// The rounded, slightly slanted letters and the sage dot follow the light/dark
/// wordmark design. There is no font dependency or opaque image background.
class MifuWordmark extends StatelessWidget {
  const MifuWordmark({
    super.key,
    this.width = 112,
    this.color,
    this.accentColor,
  }) : assert(width > 0 && width < double.infinity);

  final double width;
  final Color? color;
  final Color? accentColor;

  static const designSize = Size(580, 252);
  static const aspectRatio = 580 / 252;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      label: 'Mifu',
      image: true,
      child: RepaintBoundary(
        child: SizedBox(
          key: const ValueKey('mifu-wordmark'),
          width: width,
          height: width / aspectRatio,
          child: CustomPaint(
            painter: MifuWordmarkPainter(
              color:
                  color ??
                  (dark ? const Color(0xFFEEF2EF) : const Color(0xFF202623)),
              accentColor:
                  accentColor ??
                  (dark ? const Color(0xFF9FBE82) : const Color(0xFF94B274)),
            ),
          ),
        ),
      ),
    );
  }
}

class MifuWordmarkPainter extends CustomPainter {
  const MifuWordmarkPainter({required this.color, required this.accentColor});

  final Color color;
  final Color accentColor;

  // Outlined letterforms retain the approved rounded shoulders and compact f
  // descender without relying on a platform's italic font rendering.
  static final _letters = <Path>[
    Path()
      ..moveTo(23, 211)
      ..cubicTo(10, 209, 4, 200, 9, 187)
      ..lineTo(59, 49)
      ..cubicTo(66, 29, 79, 22, 94, 27)
      ..cubicTo(105, 30, 112, 39, 117, 54)
      ..lineTo(146, 106)
      ..lineTo(194, 44)
      ..cubicTo(205, 29, 218, 23, 232, 28)
      ..cubicTo(247, 32, 254, 44, 252, 62)
      ..lineTo(238, 192)
      ..cubicTo(236, 207, 225, 215, 211, 212)
      ..cubicTo(198, 211, 191, 203, 193, 190)
      ..lineTo(204, 89)
      ..lineTo(157, 150)
      ..cubicTo(150, 160, 142, 164, 132, 162)
      ..cubicTo(122, 161, 116, 155, 112, 145)
      ..lineTo(94, 88)
      ..lineTo(50, 195)
      ..cubicTo(45, 207, 35, 214, 23, 211)
      ..close(),
    Path()
      ..moveTo(294, 80)
      ..cubicTo(280, 78, 271, 85, 268, 99)
      ..lineTo(253, 190)
      ..cubicTo(251, 204, 259, 212, 271, 213)
      ..cubicTo(285, 214, 295, 207, 297, 193)
      ..lineTo(312, 104)
      ..cubicTo(315, 90, 308, 81, 294, 80)
      ..close(),
    Path()
      ..moveTo(441, 8)
      ..cubicTo(412, 3, 389, 11, 373, 28)
      ..cubicTo(359, 43, 352, 61, 349, 80)
      ..lineTo(340, 80)
      ..cubicTo(330, 80, 324, 85, 323, 95)
      ..cubicTo(321, 105, 326, 111, 335, 111)
      ..lineTo(343, 111)
      ..lineTo(328, 188)
      ..cubicTo(323, 215, 311, 225, 294, 228)
      ..cubicTo(283, 229, 278, 235, 282, 242)
      ..cubicTo(286, 249, 303, 251, 318, 247)
      ..cubicTo(349, 239, 366, 220, 372, 192)
      ..lineTo(388, 111)
      ..lineTo(410, 111)
      ..cubicTo(420, 111, 425, 105, 426, 95)
      ..cubicTo(428, 86, 423, 80, 413, 80)
      ..lineTo(394, 80)
      ..cubicTo(398, 59, 405, 44, 420, 39)
      ..cubicTo(431, 35, 441, 38, 451, 36)
      ..cubicTo(461, 34, 466, 26, 462, 18)
      ..cubicTo(459, 12, 450, 9, 441, 8)
      ..close(),
    Path()
      ..moveTo(456, 80)
      ..cubicTo(443, 78, 435, 85, 432, 99)
      ..lineTo(422, 160)
      ..cubicTo(416, 198, 436, 218, 471, 219)
      ..cubicTo(513, 221, 544, 204, 552, 168)
      ..lineTo(568, 103)
      ..cubicTo(571, 89, 565, 81, 553, 80)
      ..cubicTo(541, 79, 532, 85, 530, 99)
      ..lineTo(519, 152)
      ..cubicTo(515, 173, 506, 181, 492, 180)
      ..cubicTo(476, 180, 467, 171, 470, 154)
      ..lineTo(479, 105)
      ..cubicTo(481, 91, 472, 82, 456, 80)
      ..close(),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final scale = math.min(
      size.width / MifuWordmark.designSize.width,
      size.height / MifuWordmark.designSize.height,
    );
    canvas
      ..save()
      ..translate(
        (size.width - MifuWordmark.designSize.width * scale) / 2,
        (size.height - MifuWordmark.designSize.height * scale) / 2,
      )
      ..scale(scale);
    final paint = Paint()..color = color;
    for (final letter in _letters) {
      canvas.drawPath(letter, paint);
    }
    canvas.drawOval(
      const Rect.fromLTWH(283, 23, 47, 45),
      Paint()..color = accentColor,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(MifuWordmarkPainter oldDelegate) =>
      color != oldDelegate.color || accentColor != oldDelegate.accentColor;
}
