import 'dart:async';

import 'package:flutter/material.dart';

/// Coordinates the visual handoff between the compact startup surface and the
/// already-laid-out application underneath it.
///
/// The controller deliberately contains presentation geometry only. It does
/// not own startup tasks, navigation state, or application data.
class StartupHandoffController extends ChangeNotifier {
  final Completer<void> _completion = Completer<void>();
  Rect? _landingRect;
  Object? _landingOwner;
  double _progress = 0;
  bool _active = true;

  Rect? get landingRect => _landingRect;
  double get progress => _progress;
  bool get isActive => _active;
  bool get hasLandingTarget => _landingRect != null;
  Future<void> get completed => _completion.future;

  double get landingOpacity {
    if (!_active) return 1;
    return const Interval(
      0.90,
      0.96,
      curve: Curves.easeOutCubic,
    ).transform(_progress);
  }

  double get deferredChromeOpacity {
    if (!_active) return 1;
    return const Interval(
      0.86,
      0.98,
      curve: Curves.easeOutCubic,
    ).transform(_progress);
  }

  void reportLandingRect(Object owner, Rect rect) {
    if (rect.isEmpty || !rect.isFinite) return;
    if (identical(_landingOwner, owner) &&
        _rectsNearlyEqual(_landingRect, rect)) {
      return;
    }
    _landingOwner = owner;
    _landingRect = rect;
    notifyListeners();
  }

  void unregisterLandingTarget(Object owner) {
    if (!identical(_landingOwner, owner)) return;
    _landingOwner = null;
    _landingRect = null;
    notifyListeners();
  }

  void updateProgress(double value) {
    final next = value.clamp(0.0, 1.0);
    if ((_progress - next).abs() < 0.0001) return;
    _progress = next;
    notifyListeners();
  }

  void complete() {
    if (!_active && _progress == 1) return;
    _progress = 1;
    _active = false;
    if (!_completion.isCompleted) _completion.complete();
    notifyListeners();
  }

  @override
  void dispose() {
    if (!_completion.isCompleted) _completion.complete();
    super.dispose();
  }

  /// Waits until the preferred target has held the same bounds for two frames.
  ///
  /// The application is mounted at its final 1440x900 layout before this is
  /// called. Waiting for stable geometry avoids landing on an intermediate
  /// sidebar or font-layout position without adding an arbitrary splash delay.
  Future<Rect?> waitForStableLandingRect({
    int stableFrameCount = 2,
    int maximumFrameCount = 10,
  }) async {
    Rect? previous;
    var stableFrames = 0;
    for (var frame = 0; frame < maximumFrameCount; frame++) {
      WidgetsBinding.instance.scheduleFrame();
      await WidgetsBinding.instance.endOfFrame;
      final current = _landingRect;
      if (current != null && _rectsNearlyEqual(previous, current)) {
        stableFrames++;
        if (stableFrames >= stableFrameCount) return current;
      } else {
        stableFrames = current == null ? 0 : 1;
      }
      previous = current;
    }
    return _landingRect;
  }

  static bool _rectsNearlyEqual(Rect? a, Rect? b) {
    if (a == null || b == null) return a == b;
    const tolerance = 0.1;
    return (a.left - b.left).abs() < tolerance &&
        (a.top - b.top).abs() < tolerance &&
        (a.width - b.width).abs() < tolerance &&
        (a.height - b.height).abs() < tolerance;
  }
}

/// Makes a single startup handoff controller available to both nested
/// [MaterialApp] trees without rebuilding the application on every tick.
class StartupHandoffScope extends InheritedWidget {
  const StartupHandoffScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final StartupHandoffController controller;

  static StartupHandoffController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<StartupHandoffScope>()
        ?.controller;
  }

  static StartupHandoffController? maybeRead(BuildContext context) {
    final element =
        context.getElementForInheritedWidgetOfExactType<StartupHandoffScope>();
    return (element?.widget as StartupHandoffScope?)?.controller;
  }

  @override
  bool updateShouldNotify(StartupHandoffScope oldWidget) {
    return !identical(controller, oldWidget.controller);
  }
}

/// Marks the main-workspace wordmark as the preferred startup landing point.
///
/// The child keeps its full layout while hidden, so its exact global rectangle
/// can be measured before the native window begins expanding.
class StartupLandingTarget extends StatefulWidget {
  const StartupLandingTarget({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  State<StartupLandingTarget> createState() => _StartupLandingTargetState();
}

class _StartupLandingTargetState extends State<StartupLandingTarget> {
  final GlobalKey _measurementKey = GlobalKey();
  final Object _owner = Object();
  StartupHandoffController? _controller;
  bool _measurementScheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = StartupHandoffScope.maybeOf(context);
    if (!identical(next, _controller)) {
      _controller?.unregisterLandingTarget(_owner);
      _controller = next;
    }
    _scheduleMeasurement();
  }

  void _scheduleMeasurement() {
    if (_measurementScheduled || _controller == null) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;
      final renderObject =
          _measurementKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderObject == null || !renderObject.hasSize) return;
      _controller?.reportLandingRect(
        _owner,
        renderObject.localToGlobal(Offset.zero) & renderObject.size,
      );
    });
  }

  @override
  void dispose() {
    _controller?.unregisterLandingTarget(_owner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasurement();
    final controller = _controller;
    final child = SizedBox(key: _measurementKey, child: widget.child);
    if (controller == null) return child;
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) {
        return Opacity(
          key: const ValueKey('startup-landing-target-opacity'),
          opacity: controller.landingOpacity,
          child: child,
        );
      },
    );
  }
}

/// Delays secondary brand chrome until the moving wordmark is nearly home.
class StartupDeferredVisibility extends StatelessWidget {
  const StartupDeferredVisibility({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final controller = StartupHandoffScope.maybeOf(context);
    if (controller == null) return child;
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) => Opacity(
        key: const ValueKey('startup-deferred-chrome-opacity'),
        opacity: controller.deferredChromeOpacity,
        child: child,
      ),
    );
  }
}
