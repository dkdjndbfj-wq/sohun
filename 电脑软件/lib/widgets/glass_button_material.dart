import 'dart:ui';
import 'package:flutter/material.dart';

enum AppGlassButtonVariant { primary, secondary, quiet, danger }

/// The material approved for the update buttons, shared by all action controls.
class GlassButtonPalette {
  const GlassButtonPalette({
    required this.fill,
    required this.foreground,
    required this.rim,
    required this.shadow,
  });
  final List<Color> fill;
  final Color foreground;
  final Color rim;
  final Color shadow;

  factory GlassButtonPalette.resolve(
    ThemeData theme, {
    AppGlassButtonVariant variant = AppGlassButtonVariant.primary,
    bool enabled = true,
    bool selected = false,
    Color? tint,
  }) {
    final dark = theme.brightness == Brightness.dark;
    final primary =
        selected ||
        variant == AppGlassButtonVariant.primary ||
        variant == AppGlassButtonVariant.danger;
    final quiet = variant == AppGlassButtonVariant.quiet && !selected;
    final accent =
        (tint ??
                (variant == AppGlassButtonVariant.danger
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary))
            .withValues(alpha: 1);
    final foreground = !enabled
        ? theme.colorScheme.onSurface.withValues(alpha: .42)
        : primary || tint != null
        ? Color.lerp(
            accent,
            dark ? Colors.white : Colors.black,
            dark ? .55 : .50,
          )!
        : theme.colorScheme.onSurface;
    final List<Color> fill;
    if (!enabled) {
      fill = [
        Colors.white.withValues(alpha: dark ? .07 : .28),
        Colors.white.withValues(alpha: dark ? .02 : .10),
      ];
    } else if (primary) {
      fill = dark
          ? [
              Colors.white.withValues(alpha: .17),
              accent.withValues(alpha: .19),
              accent.withValues(alpha: .08),
            ]
          : [
              Colors.white.withValues(alpha: .56),
              Color.lerp(accent, Colors.white, .56)!.withValues(alpha: .40),
              accent.withValues(alpha: .18),
            ];
    } else {
      fill = [
        Colors.white.withValues(
          alpha: dark ? (quiet ? .07 : .13) : (quiet ? .35 : .62),
        ),
        Colors.white.withValues(alpha: dark ? .025 : (quiet ? .09 : .20)),
      ];
    }
    return GlassButtonPalette(
      fill: fill,
      foreground: foreground,
      rim: Colors.white.withValues(
        alpha: dark ? (primary ? .27 : .15) : (quiet ? .56 : .88),
      ),
      shadow:
          (dark
                  ? Colors.black
                  : primary
                  ? accent
                  : Colors.black)
              .withValues(alpha: dark ? .18 : (primary ? .09 : .035)),
    );
  }
}

/// Clipping bounds the real blur to the control. It adds no gesture recognizer.
class GlassButtonMaterial extends StatelessWidget {
  const GlassButtonMaterial({
    super.key,
    required this.child,
    this.variant = AppGlassButtonVariant.primary,
    this.enabled = true,
    this.selected = false,
    this.tint,
    this.shape,
    this.showShadow = true,
  });
  final Widget child;
  final AppGlassButtonVariant variant;
  final bool enabled;
  final bool selected;
  final Color? tint;
  final OutlinedBorder? shape;
  final bool showShadow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final palette = GlassButtonPalette.resolve(
      theme,
      variant: variant,
      enabled: enabled,
      selected: selected,
      tint: tint,
    );
    final quiet = variant == AppGlassButtonVariant.quiet && !selected;
    final outline =
        shape ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(quiet ? 12 : 15),
        );
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: outline,
        shadows: [
          if (showShadow && !quiet && enabled)
            BoxShadow(
              color: palette.shadow,
              blurRadius: variant == AppGlassButtonVariant.secondary ? 8 : 12,
              offset: const Offset(0, 3),
            ),
        ],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: outline),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: outline.copyWith(side: BorderSide(color: palette.rim)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: palette.fill,
              ),
            ),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                Positioned(
                  top: 0,
                  left: 8,
                  right: 8,
                  height: 1,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0),
                            Colors.white.withValues(alpha: dark ? .48 : .95),
                            Colors.white.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
