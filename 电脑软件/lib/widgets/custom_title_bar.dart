import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme/app_colors.dart';
import '../features/diagnostics/printer_fault_center.dart';
import 'app_brand_icon.dart';

/// sohun 自有窗口标题栏。
///
/// 可见区域全部由 Flutter 绘制，不恢复 Windows 原生标题栏。窗口按钮使用
/// [CustomPainter] 绘制，因此即使业务图标字体损坏，最小化、最大化和关闭仍可用。
class CustomTitleBar extends StatelessWidget {
  const CustomTitleBar({
    super.key,
    this.embedded = false,
    this.showFaults = true,
    this.showBrand = true,
    this.controlsOnly = false,
  });

  final bool embedded;
  final bool showFaults;
  final bool showBrand;
  final bool controlsOnly;

  static const double height = 46;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fill = isDark ? AppColors.glassFillL1Dark : AppColors.glassFill;
    final bar = SizedBox(
      key: controlsOnly ? null : const ValueKey('custom-window-title-bar'),
      height: height,
      child: Row(
        mainAxisSize: controlsOnly ? MainAxisSize.min : MainAxisSize.max,
        children: [
          if (!controlsOnly)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: toggleMaximize,
                child: DragToMoveArea(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 14),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: showBrand
                          ? const AppBrandIcon(size: 18, radius: 4)
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          if (showFaults) const PrinterFaultBell(),
          const SizedBox(width: 4),
          const _CaptionButton(
            key: ValueKey('window-minimize-button'),
            label: '最小化',
            glyph: _CaptionGlyph.minimize,
            onPressed: _minimize,
          ),
          const SizedBox(width: 3),
          const _CaptionButton(
            key: ValueKey('window-maximize-button'),
            label: '最大化或还原',
            glyph: _CaptionGlyph.maximize,
            onPressed: toggleMaximize,
          ),
          const SizedBox(width: 3),
          const _CaptionButton(
            key: ValueKey('window-close-button'),
            label: '关闭',
            glyph: _CaptionGlyph.close,
            destructive: true,
            onPressed: _close,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
    if (controlsOnly) {
      return bar;
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: ColoredBox(
          color: embedded
              ? colors.surface.withValues(alpha: 0.82)
              : fill.withValues(alpha: isDark ? 0.5 : 0.58),
          child: bar,
        ),
      ),
    );
  }

  static Future<void> _minimize() => windowManager.minimize();

  static Future<void> _close() => windowManager.close();

  static Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }
}

enum _CaptionGlyph { minimize, maximize, close }

class _CaptionButton extends StatelessWidget {
  const _CaptionButton({
    super.key,
    required this.label,
    required this.glyph,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final _CaptionGlyph glyph;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = destructive ? colors.error : colors.onSurfaceVariant;
    return Semantics(
      button: true,
      label: label,
      child: IconButton(
        tooltip: label,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 36, height: 30),
        style: ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          ),
          foregroundColor: WidgetStatePropertyAll(foreground),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return destructive
                  ? colors.error.withValues(alpha: 0.2)
                  : colors.primary.withValues(alpha: 0.14);
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return destructive
                  ? colors.error.withValues(alpha: 0.12)
                  : colors.primary.withValues(alpha: 0.08);
            }
            return colors.surfaceContainerHighest.withValues(alpha: 0.38);
          }),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
        icon: SizedBox.square(
          dimension: 13,
          child: CustomPaint(
            painter: _CaptionGlyphPainter(glyph, foreground),
          ),
        ),
      ),
    );
  }
}

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter(this.glyph, this.color);

  final _CaptionGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.35
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (glyph) {
      case _CaptionGlyph.minimize:
        canvas.drawLine(
          Offset(size.width * 0.2, size.height * 0.68),
          Offset(size.width * 0.8, size.height * 0.68),
          paint,
        );
      case _CaptionGlyph.maximize:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              size.width * 0.2,
              size.height * 0.2,
              size.width * 0.6,
              size.height * 0.6,
            ),
            const Radius.circular(1),
          ),
          paint,
        );
      case _CaptionGlyph.close:
        canvas
          ..drawLine(
            Offset(size.width * 0.23, size.height * 0.23),
            Offset(size.width * 0.77, size.height * 0.77),
            paint,
          )
          ..drawLine(
            Offset(size.width * 0.77, size.height * 0.23),
            Offset(size.width * 0.23, size.height * 0.77),
            paint,
          );
    }
  }

  @override
  bool shouldRepaint(covariant _CaptionGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
