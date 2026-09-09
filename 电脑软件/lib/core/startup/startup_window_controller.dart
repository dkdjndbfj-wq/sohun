import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app_identity.dart';

/// Owns the native window stages used during startup.
///
/// The app deliberately starts as a compact, frameless splash window. The
/// normal desktop window is configured only after initialization has finished,
/// so the large application frame can never appear behind the logo animation.
class StartupWindowController {
  StartupWindowController._();

  static const splashSize = Size(520, 292);
  static const failureSize = Size(680, 440);
  static const mainSize = Size(1440, 900);
  static const mainMinimumSize = Size(1100, 700);
  static const transitionDuration = Duration(milliseconds: 820);
  static const positionAnchorFraction = 0.60;
  static const _startupWindowChannel =
      MethodChannel('consumable_tracker/startup_window');

  static Rect? _transitionStartBounds;
  static Rect? _transitionTargetBounds;
  static double? _pendingProgress;
  static bool _boundsUpdateActive = false;
  static Completer<void>? _boundsIdleCompleter;
  static bool _nativeRevealActive = false;

  static Future<void> prepareSplashWindow({
    Color backgroundColor = const Color(0xFFF4F6F5),
  }) async {
    try {
      // Windows can expose the native backing surface before Flutter submits
      // its first frame. Match that surface to the startup artwork so it can
      // never flash the platform's default black clear color.
      await windowManager.setBackgroundColor(backgroundColor);
      await windowManager.setTitle(AppIdentity.name);
      await windowManager.setMinimumSize(Size.zero);
      await windowManager.setResizable(false);
      await windowManager.setMinimizable(false);
      await windowManager.setMaximizable(false);
      await windowManager.setSkipTaskbar(true);
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setAsFrameless();
      await windowManager.setHasShadow(true);
      await windowManager.setSize(splashSize);
      await windowManager.center();
    } catch (error) {
      debugPrint('Failed to prepare splash window: $error');
    }
  }

  static Future<void> prepareFailureWindow() async {
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setResizable(false);
      await windowManager.setSize(failureSize);
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
    } catch (error) {
      debugPrint('Failed to prepare startup failure window: $error');
    }
  }

  /// Prepares a live compact-to-main-window handoff.
  ///
  /// The target top-left corner is reached early, then stays anchored while the
  /// right and bottom edges continue growing. The Flutter wordmark is driven by
  /// the same progress value, so both parts finish on the same frame.
  static Future<void> prepareMainWindowTransition({
    required Color backgroundColor,
  }) async {
    try {
      // A live resize creates newly exposed swap-chain pixels. Give those
      // pixels the same solid color as the Flutter startup layer until the
      // already-mounted application has painted the enlarged frame.
      await windowManager.setBackgroundColor(backgroundColor);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setMinimumSize(Size.zero);
      await windowManager.setResizable(false);
      await windowManager.setMinimizable(false);
      await windowManager.setMaximizable(false);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      final startBounds = await windowManager.getBounds();
      final targetPosition = await calcWindowPosition(
        mainSize,
        Alignment.center,
      );
      _transitionStartBounds = startBounds;
      _transitionTargetBounds = targetPosition & mainSize;
      _pendingProgress = null;

      // Keep Flutter at one stable viewport for the whole animation. The
      // Windows runner clips that already-full-size surface with a native
      // region and expands only the region. This avoids doing 60 expensive
      // platform-channel resizes and 60 full application relayouts.
      try {
        await _startupWindowChannel.invokeMethod<void>(
          'prepareReveal',
          const {'cornerRadius': 14},
        );
        await windowManager.setBounds(startBounds.topLeft & mainSize);
        await WidgetsBinding.instance.endOfFrame;
        await _startupWindowChannel.invokeMethod<void>(
          'startReveal',
          {'durationMs': transitionDuration.inMilliseconds},
        );
        _nativeRevealActive = true;
      } on PlatformException catch (error) {
        debugPrint('Native startup reveal unavailable: $error');
        await _restoreFallbackBounds(startBounds);
      } on MissingPluginException catch (error) {
        debugPrint('Native startup reveal unavailable: $error');
        await _restoreFallbackBounds(startBounds);
      }
    } catch (error) {
      debugPrint('Failed to prepare main window transition: $error');
    }
  }

  static Future<void> _restoreFallbackBounds(Rect startBounds) async {
    _nativeRevealActive = false;
    try {
      await _startupWindowChannel.invokeMethod<void>('finishReveal');
    } catch (_) {
      // The channel itself is optional outside the Windows runner.
    }
    await windowManager.setBounds(startBounds);
  }

  /// Queues the newest animation value and coalesces stale native resize calls.
  ///
  /// This prevents a slow platform-channel frame from building up a resize
  /// backlog, which is what makes a window appear to stutter after the visual
  /// animation has already advanced.
  static void updateMainWindowTransition(double progress) {
    if (_transitionStartBounds == null || _transitionTargetBounds == null) {
      return;
    }
    if (_nativeRevealActive) return;
    _pendingProgress = progress.clamp(0, 1);
    if (_boundsUpdateActive) return;
    _boundsIdleCompleter = Completer<void>();
    unawaited(_drainBoundsUpdates());
  }

  static Future<void> _drainBoundsUpdates() async {
    _boundsUpdateActive = true;
    try {
      while (_pendingProgress != null) {
        final progress = _pendingProgress!;
        _pendingProgress = null;
        await windowManager.setBounds(
          boundsForProgress(
            _transitionStartBounds!,
            _transitionTargetBounds!,
            progress,
          ),
        );
      }
    } catch (error) {
      debugPrint('Failed to resize startup window: $error');
    } finally {
      _boundsUpdateActive = false;
      final idleCompleter = _boundsIdleCompleter;
      if (idleCompleter != null && !idleCompleter.isCompleted) {
        idleCompleter.complete();
      }
      _boundsIdleCompleter = null;
    }
  }

  @visibleForTesting
  static Rect boundsForProgress(Rect start, Rect target, double progress) {
    final value = progress.clamp(0.0, 1.0);
    final anchorValue = Curves.easeInOutCubic.transform(
      (value / positionAnchorFraction).clamp(0.0, 1.0),
    );
    final sizeValue = Curves.easeInOutCubic.transform(value);
    final position = Offset.lerp(start.topLeft, target.topLeft, anchorValue)!;
    final size = Size.lerp(start.size, target.size, sizeValue)!;
    return position & size;
  }

  static Size revealSizeForProgress(
    Size start,
    Size target,
    double progress,
  ) {
    final sizeValue = Curves.easeInOutCubic.transform(
      progress.clamp(0.0, 1.0),
    );
    return Size.lerp(start, target, sizeValue)!;
  }

  static Future<void> finishMainWindowTransition() async {
    if (_nativeRevealActive) {
      try {
        await _startupWindowChannel.invokeMethod<void>('finishReveal');
      } catch (error) {
        debugPrint('Failed to finish native startup reveal: $error');
      }
    } else {
      updateMainWindowTransition(1);
      await _boundsIdleCompleter?.future;
    }
    try {
      final targetBounds = _transitionTargetBounds;
      if (targetBounds != null) {
        await windowManager.setBounds(targetBounds);
      }
      await windowManager.setMinimumSize(mainMinimumSize);
      await windowManager.setMinimizable(true);
      await windowManager.setMaximizable(true);
      await windowManager.setResizable(true);
      await windowManager.show();
      await windowManager.focus();
    } catch (error) {
      debugPrint('Failed to finish main window transition: $error');
    } finally {
      _transitionStartBounds = null;
      _transitionTargetBounds = null;
      _pendingProgress = null;
      _nativeRevealActive = false;
    }
  }

  /// Compatibility helper for callers that need an immediate handoff.
  static Future<void> prepareMainWindow() async {
    await prepareMainWindowTransition(
      backgroundColor: const Color(0xFFF4F6F5),
    );
    updateMainWindowTransition(1);
    await finishMainWindowTransition();
  }

  static Future<void> showMainWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (error) {
      debugPrint('Failed to show main window: $error');
    }
  }
}
