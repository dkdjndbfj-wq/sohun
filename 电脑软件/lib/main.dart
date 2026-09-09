import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/services/error_logger.dart';
import 'core/startup/startup_bootstrap_app.dart';
import 'core/startup/startup_window_controller.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_color.dart';
import 'data/prefs/app_prefs.dart';
import 'data/prefs/theme_prefs.dart';
import 'providers/theme_provider.dart';
import 'widgets/confirm_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Desktop assets include many high-resolution printer and brand images. Keep
  // Flutter's decoded-image cache bounded so browsing several pages does not
  // retain hundreds of megabytes of pixel buffers.
  PaintingBinding.instance.imageCache
    ..maximumSize = 350
    ..maximumSizeBytes = 64 << 20;
  // 数据库打开前先安装处理器；早期异常暂存在内存，ErrorLogger.init 后落库。
  ErrorLogger.installGlobalHandler();
  RollSnackCounter.contextProvider = () => navigatorKey.currentContext;

  await windowManager.ensureInitialized();
  // Initializes the Windows taskbar COM bridge before splash/main stage calls
  // toggle taskbar visibility. Calling setSkipTaskbar before this crashes
  // window_manager 0.4.x on Windows because its native taskbar pointer is null.
  await windowManager.waitUntilReadyToShow();
  // 统一由应用处理关闭按钮：用户可以在设置中选择隐藏到托盘或完全退出。
  await windowManager.setPreventClose(true);
  final appearance = await _loadStartupAppearance();
  await StartupWindowController.prepareSplashWindow(
    backgroundColor: _startupBackgroundFor(appearance),
  );

  runApp(
    ProviderScope(
      overrides: [
        themeModeProvider.overrideWith((ref) {
          return ThemeModeNotifier(
            initialMode: appearance.themeMode,
            loadPersisted: false,
          );
        }),
        themeColorProvider.overrideWith((ref) {
          return ThemeColorNotifier(
            initialColor: appearance.themeColor,
            loadPersisted: false,
          );
        }),
        interactionEffectsEnabledProvider.overrideWith((ref) {
          return InteractionEffectsEnabledNotifier(
            initialValue: appearance.interactionEffectsEnabled,
            loadPersisted: false,
          );
        }),
      ],
      child: const StartupBootstrapApp(),
    ),
  );
}

Color _startupBackgroundFor(_StartupAppearance appearance) {
  final platformBrightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;
  final useDark = appearance.themeMode == ThemeMode.dark ||
      (appearance.themeMode == ThemeMode.system &&
          platformBrightness == Brightness.dark);
  final theme = useDark
      ? AppTheme.darkFrom(
          appearance.themeColor.seed,
          appearance.themeColor.accent,
        )
      : AppTheme.lightFrom(
          appearance.themeColor.seed,
          appearance.themeColor.accent,
        );
  return Color.lerp(
    theme.colorScheme.surface,
    theme.colorScheme.primary,
    useDark ? 0.025 : 0.012,
  )!;
}

Future<_StartupAppearance> _loadStartupAppearance() async {
  try {
    final themeMode = await ThemePrefs.getMode();
    final colorName = await ThemePrefs.getColorName();
    final effectsEnabled = await AppPrefs.getInteractionEffectsEnabled();
    return _StartupAppearance(
      themeMode: themeMode,
      themeColor: ThemeColorDef.byName(colorName),
      interactionEffectsEnabled: effectsEnabled,
    );
  } catch (error) {
    debugPrint('加载启动外观偏好失败: $error');
    return const _StartupAppearance(
      themeMode: ThemeMode.system,
      themeColor: ThemeColorDef.auroraGreen,
      interactionEffectsEnabled: true,
    );
  }
}

class _StartupAppearance {
  const _StartupAppearance({
    required this.themeMode,
    required this.themeColor,
    required this.interactionEffectsEnabled,
  });

  final ThemeMode themeMode;
  final ThemeColorDef themeColor;
  final bool interactionEffectsEnabled;
}
