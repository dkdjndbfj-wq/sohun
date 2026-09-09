import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/personal_desktop_theme.dart';

/// A quiet, opaque canvas. The light fields are static and isolated from live
/// printer updates; no permanent ticker or per-inventory-card blur is needed.
class PersonalDesktopBackground extends StatelessWidget {
  const PersonalDesktopBackground({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ColoredBox(
      color: personalDesktopCanvas(theme.brightness),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(-1, -0.9),
                      radius: 1.15,
                      colors: [
                        theme.colorScheme.primary.withValues(
                          alpha: dark ? 0.15 : 0.12,
                        ),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: RepaintBoundary(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(1, 0.8),
                      radius: 1.15,
                      colors: [
                        theme.colorScheme.secondary.withValues(
                          alpha: dark ? 0.11 : 0.09,
                        ),
                        Colors.transparent,
                      ],
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

/// Only the desktop's two navigation surfaces use a backdrop blur. Repeated
/// content cards use the same rim/fill through the opt-in GlassCard tokens.
class PersonalDesktopChrome extends StatelessWidget {
  const PersonalDesktopChrome({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 18,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderRadius = BorderRadius.circular(radius);
    final fill = personalDesktopGlassFill(theme, opacity: 0.52);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: theme.brightness == Brightness.dark
            ? AppColors.shadow1Dark
            : AppColors.shadowCard,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              border: Border.all(color: personalDesktopGlassRim(theme)),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [fill.withValues(alpha: 0.66), fill],
              ),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
