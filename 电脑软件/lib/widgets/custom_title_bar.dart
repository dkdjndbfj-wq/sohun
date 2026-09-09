import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme/app_colors.dart';
import '../core/theme/glass_button_theme.dart';
import 'glass_button_material.dart';
import 'app_brand_icon.dart';
import '../features/diagnostics/printer_fault_center.dart';

/// 自定义毛玻璃窗口标题栏。替代系统默认标题栏。
/// 含应用图标 + 最小化/最大化/关闭按钮，BackdropFilter 真毛玻璃。
/// 必须用 WindowCaptionButton（window_manager 提供）以获得原生体验。
class CustomTitleBar extends StatelessWidget {
  const CustomTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          windowManager.unmaximize();
        } else {
          windowManager.maximize();
        }
      },
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: (isDark ? AppColors.glassFillL1Dark : AppColors.glassFill)
                  .withValues(alpha: 0.75),
              border: Border(
                bottom: BorderSide(
                  color: isDark
                      ? AppColors.glassBorderDarkMode
                      : AppColors.glassBorderDark,
                  width: 1,
                ),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                // 应用图标
                const AppBrandIcon(size: 18, radius: 4),
                const Spacer(),
                const PrinterFaultBell(),
                // 窗口控制按钮
                _caption(
                  context,
                  WindowCaptionButton.minimize(
                    brightness: Theme.of(context).brightness,
                    onPressed: () => windowManager.minimize(),
                  ),
                ),
                _caption(
                  context,
                  WindowCaptionButton.maximize(
                    brightness: Theme.of(context).brightness,
                    onPressed: () async {
                      if (await windowManager.isMaximized()) {
                        windowManager.unmaximize();
                      } else {
                        windowManager.maximize();
                      }
                    },
                  ),
                ),
                _caption(
                  context,
                  WindowCaptionButton.close(
                    brightness: Theme.of(context).brightness,
                    onPressed: () => windowManager.close(),
                  ),
                  destructive: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _caption(
    BuildContext context,
    Widget child, {
    bool destructive = false,
  }) {
    if (!GlassButtonsTheme.enabledOf(context)) return child;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      child: GlassButtonMaterial(
        variant: AppGlassButtonVariant.quiet,
        tint: destructive ? Theme.of(context).colorScheme.error : null,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: child,
      ),
    );
  }
}
