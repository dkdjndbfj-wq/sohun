import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_spacing.dart';
import '../core/theme/app_typography.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/personal_desktop_theme.dart';

/// Shared visual language for the experiential workspace screens.
///
/// These primitives intentionally favour open canvases, rails and physical
/// objects over repeated dashboard cards. They contain no business state.
abstract final class ExperienceTokens {
  static const double pageGutter = 24;
  static const double stageRadius = 28;
  static const double objectRadius = 22;
  static const Duration hoverDuration = Duration(milliseconds: 170);
  static const Duration contentDuration = Duration(milliseconds: 420);
  static const Curve motionCurve = Cubic(0.16, 1, 0.3, 1);
}

class ExperiencePageHeader extends StatelessWidget {
  const ExperiencePageHeader({
    super.key,
    required this.title,
    required this.description,
    this.actions = const [],
    this.leading,
  });

  final String title;
  final String description;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final personal = PersonalDesktopTheme.of(context) != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 700;
        final copy = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[
              Padding(padding: const EdgeInsets.only(top: 3), child: leading!),
              const SizedBox(width: AppSpacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: scheme.onSurface,
                      fontFamily: personal
                          ? null
                          : AppTypography.chineseFontFamily,
                      fontSize: personal
                          ? (compact ? 22 : 26)
                          : (compact ? 26 : 34),
                      height: personal ? 1.25 : 1.06,
                      fontWeight: personal ? FontWeight.w600 : FontWeight.w700,
                      letterSpacing: personal ? 0 : -0.7,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: Text(
                      description,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.55,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );

        if (compact || actions.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              copy,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: actions,
                ),
              ],
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: copy),
            const SizedBox(width: AppSpacing.xl),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: actions,
              ),
            ),
          ],
        );
      },
    );
  }
}

class ExperienceSectionHeading extends StatelessWidget {
  const ExperienceSectionHeading({
    super.key,
    required this.title,
    this.trailing,
    this.color,
  });

  final String title;
  final Widget? trailing;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ?? scheme.primary;
    return Row(
      children: [
        Container(
          width: 22,
          height: 3,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class OpenStage extends StatelessWidget {
  const OpenStage({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.color,
    this.borderColor,
    this.radius = ExperienceTokens.stageRadius,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? scheme.surface.withValues(alpha: dark ? 0.5 : 0.82),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color:
              borderColor ??
              scheme.outlineVariant.withValues(alpha: dark ? 0.48 : 0.62),
        ),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A restrained physical response for interactive objects.
///
/// It only animates while the pointer is inside, and isolates its raster work
/// so a spool or printer does not repaint the full page.
class TactileLift extends StatefulWidget {
  const TactileLift({
    super.key,
    required this.child,
    this.enabled = true,
    this.maxTilt = 0.018,
    this.lift = 3,
    this.onTap,
    this.cursor = SystemMouseCursors.click,
  });

  final Widget child;
  final bool enabled;
  final double maxTilt;
  final double lift;
  final VoidCallback? onTap;
  final MouseCursor cursor;

  @override
  State<TactileLift> createState() => _TactileLiftState();
}

class _TactileLiftState extends State<TactileLift> {
  Offset _pointer = Offset.zero;
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final motion = widget.enabled && AppMotion.enabled(context);
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.001)
      ..rotateX(motion ? -_pointer.dy * widget.maxTilt : 0)
      ..rotateY(motion ? _pointer.dx * widget.maxTilt : 0)
      ..translateByDouble(0, motion && _hovering ? -widget.lift : 0, 0, 1);

    return MouseRegion(
      cursor: widget.onTap == null ? MouseCursor.defer : widget.cursor,
      onEnter: motion ? (_) => setState(() => _hovering = true) : null,
      onHover: motion
          ? (event) {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null || !box.hasSize) return;
              setState(() {
                _pointer = Offset(
                  (event.localPosition.dx / box.size.width) * 2 - 1,
                  (event.localPosition.dy / box.size.height) * 2 - 1,
                );
              });
            }
          : null,
      onExit: motion
          ? (_) => setState(() {
              _hovering = false;
              _pointer = Offset.zero;
            })
          : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: RepaintBoundary(
          child: AnimatedContainer(
            duration: AppMotion.duration(
              context,
              ExperienceTokens.hoverDuration,
            ),
            curve: ExperienceTokens.motionCurve,
            transform: matrix,
            transformAlignment: Alignment.center,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class ExperienceTimeline extends StatefulWidget {
  const ExperienceTimeline({
    super.key,
    required this.values,
    required this.labels,
    this.height = 180,
    this.color,
    this.valueFormatter,
  }) : assert(values.length == labels.length);

  final List<double> values;
  final List<String> labels;
  final double height;
  final Color? color;
  final String Function(double value)? valueFormatter;

  @override
  State<ExperienceTimeline> createState() => _ExperienceTimelineState();
}

class _ExperienceTimelineState extends State<ExperienceTimeline> {
  int? _hoveredIndex;
  int? _pinnedIndex;

  int? get _activeIndex => _hoveredIndex ?? _pinnedIndex;

  int? _indexFor(Offset position) {
    if (widget.values.isEmpty) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final normalized = (position.dx / box.size.width).clamp(0.0, 1.0);
    return (normalized * (widget.values.length - 1)).round();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = widget.color ?? scheme.primary;
    final activeIndex = _activeIndex;
    return MouseRegion(
      key: const ValueKey('experience-timeline'),
      cursor: SystemMouseCursors.precise,
      onExit: (_) => setState(() => _hoveredIndex = null),
      onHover: (event) {
        final index = _indexFor(event.localPosition);
        if (index != _hoveredIndex) setState(() => _hoveredIndex = index);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (details) {
          final index = _indexFor(details.localPosition);
          if (index == null) return;
          setState(() {
            _pinnedIndex = _pinnedIndex == index ? null : index;
          });
        },
        child: SizedBox(
          height: widget.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  painter: _TimelinePainter(
                    values: widget.values,
                    color: color,
                    gridColor: scheme.outlineVariant,
                    activeIndex: activeIndex,
                  ),
                ),
              ),
              if (activeIndex != null && widget.values.isNotEmpty)
                Positioned(
                  key: const ValueKey('experience-timeline-tooltip'),
                  left: 12,
                  top: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_pinnedIndex == activeIndex) ...[
                            Icon(
                              Icons.push_pin_rounded,
                              size: 12,
                              color: color,
                            ),
                            const SizedBox(width: 5),
                          ],
                          Text(
                            '${widget.labels[activeIndex]}  '
                            '${widget.valueFormatter?.call(widget.values[activeIndex]) ?? widget.values[activeIndex].toStringAsFixed(0)}',
                            style: TextStyle(
                              color: scheme.onSurface,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  const _TimelinePainter({
    required this.values,
    required this.color,
    required this.gridColor,
    required this.activeIndex,
  });

  final List<double> values;
  final Color color;
  final Color gridColor;
  final int? activeIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final chart = Rect.fromLTWH(10, 16, size.width - 20, size.height - 30);
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.42)
      ..strokeWidth = 1;
    for (var index = 0; index < 4; index++) {
      final y = chart.top + chart.height * index / 3;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
    }
    if (values.isEmpty) return;
    final maxValue = math.max(1.0, values.reduce(math.max));
    final points = <Offset>[
      for (var index = 0; index < values.length; index++)
        Offset(
          values.length == 1
              ? chart.center.dx
              : chart.left + chart.width * index / (values.length - 1),
          chart.bottom - chart.height * values[index] / maxValue,
        ),
    ];
    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (var index = 1; index < points.length; index++) {
      final previous = points[index - 1];
      final current = points[index];
      final middle = (previous.dx + current.dx) / 2;
      linePath.cubicTo(
        middle,
        previous.dy,
        middle,
        current.dy,
        current.dx,
        current.dy,
      );
    }
    final fillPath = Path.from(linePath)
      ..lineTo(points.last.dx, chart.bottom)
      ..lineTo(points.first.dx, chart.bottom)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0)],
        ).createShader(chart),
    );
    canvas.drawPath(
      linePath,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
    if (activeIndex != null && activeIndex! < points.length) {
      final point = points[activeIndex!];
      canvas.drawLine(
        Offset(point.dx, chart.top),
        Offset(point.dx, chart.bottom),
        Paint()
          ..color = color.withValues(alpha: 0.28)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(point, 5, Paint()..color = color);
      canvas.drawCircle(
        point,
        8,
        Paint()
          ..color = color.withValues(alpha: 0.2)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.color != color ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.activeIndex != activeIndex;
  }
}
