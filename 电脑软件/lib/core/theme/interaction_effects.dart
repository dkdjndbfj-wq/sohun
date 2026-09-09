import 'package:flutter/material.dart';

import 'app_curves.dart';

/// Propagates the effective non-essential motion preference to shared widgets.
///
/// The value supplied by the app has already combined the persisted user
/// preference with the operating system accessibility setting.
class InteractionEffectsScope extends InheritedWidget {
  const InteractionEffectsScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  static bool enabledOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<InteractionEffectsScope>()
            ?.enabled ??
        true;
  }

  @override
  bool updateShouldNotify(InteractionEffectsScope oldWidget) {
    return enabled != oldWidget.enabled;
  }
}

abstract final class AppMotion {
  static bool enabled(BuildContext context) =>
      InteractionEffectsScope.enabledOf(context);

  static Duration duration(BuildContext context, Duration normal) {
    return enabled(context) ? normal : Duration.zero;
  }
}

/// Shared desktop hover and press feedback for existing interactive controls.
///
/// This only observes pointer state; the wrapped control remains responsible
/// for gestures, semantics, focus, and keyboard activation.
class AppInteractionSurface extends StatefulWidget {
  const AppInteractionSurface({
    super.key,
    required this.child,
    this.enabled = true,
    this.hoverScale = 1.012,
    this.pressedScale = 0.975,
    this.hoverOffset = const Offset(0, -0.018),
  });

  final Widget child;
  final bool enabled;
  final double hoverScale;
  final double pressedScale;
  final Offset hoverOffset;

  @override
  State<AppInteractionSurface> createState() => _AppInteractionSurfaceState();
}

class _AppInteractionSurfaceState extends State<AppInteractionSurface> {
  bool _hovering = false;
  bool _pressed = false;

  void _setHovering(bool value) {
    if (_hovering == value) return;
    setState(() => _hovering = value);
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  void didUpdateWidget(covariant AppInteractionSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && (_hovering || _pressed)) {
      _hovering = false;
      _pressed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && AppMotion.enabled(context);
    final hovering = active && _hovering;
    final pressed = active && _pressed;
    final scale = pressed
        ? widget.pressedScale
        : hovering
            ? widget.hoverScale
            : 1.0;
    final offset = hovering && !pressed ? widget.hoverOffset : Offset.zero;
    final duration = AppMotion.duration(
      context,
      pressed ? AppCurves.durationTap : AppCurves.durationHover,
    );

    return MouseRegion(
      onEnter: active ? (_) => _setHovering(true) : null,
      onExit: active
          ? (_) {
              _setHovering(false);
              _setPressed(false);
            }
          : null,
      child: Listener(
        onPointerDown: active ? (_) => _setPressed(true) : null,
        onPointerUp: active ? (_) => _setPressed(false) : null,
        onPointerCancel: active ? (_) => _setPressed(false) : null,
        child: AnimatedSlide(
          duration: duration,
          curve: AppCurves.curveHover,
          offset: offset,
          child: AnimatedScale(
            duration: duration,
            curve: pressed ? AppCurves.curveTap : AppCurves.curveHover,
            scale: scale,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
