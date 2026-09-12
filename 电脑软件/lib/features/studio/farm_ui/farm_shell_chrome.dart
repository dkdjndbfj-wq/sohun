import 'package:flutter/material.dart';

/// Farm-only control-room surfaces. They stay crisp and opaque so dense
/// production information remains readable while the personal workspace can
/// keep its own glass treatment.
class FarmShellChrome extends StatelessWidget {
  const FarmShellChrome({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 14,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final scheme = theme.colorScheme;
    final borderRadius = BorderRadius.circular(radius);
    final fill = dark ? scheme.surface : scheme.surface.withValues(alpha: 0.96);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.26 : 0.08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            color: fill,
            border: Border.all(
              color: dark
                  ? Colors.white.withValues(alpha: 0.12)
                  : scheme.outlineVariant,
            ),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class FarmShellBackground extends StatelessWidget {
  const FarmShellBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ColoredBox(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _FarmGridPainter(
                    lineColor: theme.colorScheme.primary.withValues(
                      alpha: dark ? 0.07 : 0.055,
                    ),
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _FarmGridPainter extends CustomPainter {
  const _FarmGridPainter({required this.lineColor});

  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;
    const step = 28.0;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FarmGridPainter oldDelegate) =>
      oldDelegate.lineColor != lineColor;
}
