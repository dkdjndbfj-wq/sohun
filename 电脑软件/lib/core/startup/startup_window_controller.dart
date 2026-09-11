import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app_identity.dart';

/// Startup and the workspace share one native surface. Animating only Flutter
/// opacity avoids resize messages, swap-chain reallocations and clipped frames.
class StartupWindowController {
  StartupWindowController._();

  static const mainSize = Size(1440, 900);
  static const splashSize = mainSize;
  static const failureSize = Size(680, 440);
  static const mainMinimumSize = Size(1100, 700);
  static const transitionDuration = Duration(milliseconds: 180);

  static Future<void> prepareSplashWindow({
    Color backgroundColor = const Color(0xFFF4F6F5),
  }) async {
    try {
      await windowManager.setBackgroundColor(backgroundColor);
      await windowManager.setTitle(AppIdentity.name);
      await windowManager.setMinimumSize(mainMinimumSize);
      await windowManager.setResizable(false);
      await windowManager.setMinimizable(true);
      await windowManager.setMaximizable(false);
      await windowManager.setSkipTaskbar(false);
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await windowManager.setHasShadow(true);
      await windowManager.setSize(mainSize);
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
      await windowManager.setMinimumSize(mainMinimumSize);
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
