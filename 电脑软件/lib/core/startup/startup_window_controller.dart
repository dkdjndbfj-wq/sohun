import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../app_identity.dart';

/// Startup and the workspace share one native surface. Animating only Flutter
/// opacity avoids resize messages, swap-chain reallocations and clipped frames.
class StartupWindowController {
  StartupWindowController._();

  /// Comfortable desktop size on a normal 1080p-or-larger work area.
  static const mainSize = Size(1280, 800);
  static const splashSize = mainSize;
  static const failureSize = Size(680, 440);
  static const mainMinimumSize = Size(960, 620);
  static const _workAreaInset = 32.0;
  static const transitionDuration = Duration(milliseconds: 180);
  static Size _activeMinimumSize = mainMinimumSize;

  /// Fits the first window inside the usable desktop while keeping a stable
  /// preferred size on ordinary screens. [visibleSize] uses logical pixels.
  static Size initialSizeFor(Size visibleSize) {
    if (!visibleSize.width.isFinite ||
        !visibleSize.height.isFinite ||
        visibleSize.isEmpty) {
      return mainSize;
    }
    final availableWidth = math.max(320.0, visibleSize.width - _workAreaInset);
    final availableHeight = math.max(
      320.0,
      visibleSize.height - _workAreaInset,
    );
    return Size(
      math.min(mainSize.width, availableWidth),
      math.min(mainSize.height, availableHeight),
    );
  }

  static Size minimumSizeFor(Size initialSize) => Size(
    math.min(mainMinimumSize.width, initialSize.width),
    math.min(mainMinimumSize.height, initialSize.height),
  );

  static Future<void> prepareSplashWindow({
    Color backgroundColor = const Color(0xFFF4F6F5),
  }) async {
    try {
      var initialSize = mainSize;
      try {
        final display = await screenRetriever.getPrimaryDisplay();
        initialSize = initialSizeFor(display.visibleSize ?? display.size);
      } catch (error) {
        debugPrint('Failed to read the primary display work area: $error');
      }
      _activeMinimumSize = minimumSizeFor(initialSize);
      await windowManager.setBackgroundColor(backgroundColor);
      await windowManager.setTitle(AppIdentity.name);
      await windowManager.setMinimumSize(_activeMinimumSize);
      await windowManager.setResizable(false);
      await windowManager.setMinimizable(true);
      await windowManager.setMaximizable(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      // setTitleBarStyle clears the frameless flag in window_manager 0.4.x.
      // Call setAsFrameless afterwards so Windows native caption never returns.
      await windowManager.setAsFrameless();
      await windowManager.setHasShadow(true);
      await windowManager.setSize(initialSize);
      await windowManager.center();
    } catch (error) {
      debugPrint('Failed to prepare startup window: $error');
    }
  }

  static Future<void> prepareFailureWindow() async {
    try {
      await windowManager.setMinimumSize(failureSize);
      await windowManager.setResizable(true);
      await windowManager.show();
    } catch (error) {
      debugPrint('Failed to prepare startup failure window: $error');
    }
  }

  static Future<void> prepareMainWindowTransition({
    required Color backgroundColor,
  }) async {
    try {
      await windowManager.setBackgroundColor(backgroundColor);
    } catch (error) {
      debugPrint('Failed to prepare main window transition: $error');
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  /// Intentionally no native work per frame; Flutter owns the short fade.
  static void updateMainWindowTransition(double progress) {}

  static Future<void> finishMainWindowTransition() async {
    try {
      await windowManager.setMinimumSize(_activeMinimumSize);
      await windowManager.setMinimizable(true);
      await windowManager.setMaximizable(true);
      await windowManager.setResizable(true);
      await windowManager.show();
    } catch (error) {
      debugPrint('Failed to finish startup transition: $error');
    }
  }

  static Future<void> prepareMainWindow() async {
    await prepareMainWindowTransition(backgroundColor: const Color(0xFFF4F6F5));
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
