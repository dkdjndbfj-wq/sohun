import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import '../core/theme/glass_button_theme.dart';

import '../core/theme/app_colors.dart';
import 'bambu_icon.dart';

/// 顶部通知的语义类型。
enum AppNoticeTone { success, error, warning, info }

OverlayEntry? _activeTopNotice;

/// 普通用户界面统一使用的顶部悬浮通知。
///
/// 通知显示在 38px 自定义标题栏下方，宽度随内容收缩且最大 440px，
/// 不再使用贴底、横跨窗口的原生 SnackBar。
void showSnack(
  BuildContext context,
  String message, {
  bool error = false,
  AppNoticeTone tone = AppNoticeTone.success,
  Duration? duration,
  String? actionLabel,
  VoidCallback? onAction,
  String? iconName,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  if (_activeTopNotice?.mounted ?? false) _activeTopNotice!.remove();
  _activeTopNotice = null;

  final resolvedTone = error ? AppNoticeTone.error : tone;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) => _TopNotice(
      message: message,
      tone: resolvedTone,
      duration:
          duration ??
          Duration(
            milliseconds: resolvedTone == AppNoticeTone.error ? 4500 : 1800,
          ),
      actionLabel: actionLabel,
      onAction: onAction,
      iconName: iconName,
      onDismissed: () {
        if (entry.mounted) entry.remove();
        if (identical(_activeTopNotice, entry)) _activeTopNotice = null;
      },
    ),
  );
  _activeTopNotice = entry;
  overlay.insert(entry);
}

class _TopNotice extends StatefulWidget {
  const _TopNotice({
    required this.message,
    required this.tone,
    required this.duration,
    required this.onDismissed,
    this.actionLabel,
    this.onAction,
    this.iconName,
  });

  final String message;
  final AppNoticeTone tone;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? iconName;
  final VoidCallback onDismissed;

  @override
  State<_TopNotice> createState() => _TopNoticeState();
}

class _TopNoticeState extends State<_TopNotice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  Timer? _timer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.28),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
    _timer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _timer?.cancel();
    await _controller.reverse();
    widget.onDismissed();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = switch (widget.tone) {
      AppNoticeTone.success => AppColors.success,
      AppNoticeTone.error => AppColors.danger,
      AppNoticeTone.warning => AppColors.warning,
      AppNoticeTone.info => AppColors.primary,
    };
    final icon =
        widget.iconName ??
        switch (widget.tone) {
          AppNoticeTone.success => 'completed',
          AppNoticeTone.error => 'error',
          AppNoticeTone.warning => 'warning',
          AppNoticeTone.info => 'info',
        };
    final surface = isDark
        ? AppColors.glassFillL2Dark.withValues(alpha: 0.96)
        : Colors.white.withValues(alpha: 0.94);
    final border = isDark
        ? AppColors.glassBorderDarkMode
        : AppColors.glassBorderDark;

    return Positioned(
      top: MediaQuery.paddingOf(context).top + 54,
      left: 16,
      right: 16,
      child: SafeArea(
        bottom: false,
        child: Center(
          child: FadeTransition(
            opacity: _opacity,
            child: SlideTransition(
              position: _slide,
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppColors.radiusLg),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        key: const ValueKey('app-top-notice'),
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                        decoration: BoxDecoration(
                          color: surface,
                          borderRadius: BorderRadius.circular(
                            AppColors.radiusLg,
                          ),
                          border: Border.all(
                            color: border.withValues(alpha: isDark ? 0.72 : 1),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: isDark ? 0.28 : 0.12,
                              ),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                            BoxShadow(
                              color: accent.withValues(alpha: 0.08),
                              blurRadius: 16,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              alignment: Alignment.center,
                              child: BambuIcon(
                                name: icon,
                                size: 16,
                                applyColorFilter: true,
                                color: accent,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                widget.message,
                                maxLines: widget.tone == AppNoticeTone.error
                                    ? 3
                                    : 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: isDark
                                      ? AppColors.textPrimaryDark
                                      : AppColors.textPrimary,
                                  fontSize: 13,
                                  height: 1.35,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (widget.actionLabel != null &&
                                widget.onAction != null) ...[
                              const SizedBox(width: 10),
                              TextButton(
                                onPressed: () {
                                  widget.onAction!();
                                  _dismiss();
                                },
                                style: glassButtonStyle(
                                  context,
                                  TextButton.styleFrom(
                                    foregroundColor: accent,
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 6,
                                    ),
                                  ),
                                  variant: AppGlassButtonVariant.quiet,
                                ),
                                child: Text(widget.actionLabel!),
                              ),
                            ],
                            const SizedBox(width: 2),
                            IconButton(
                              tooltip: '关闭提示',
                              onPressed: _dismiss,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              icon: Icon(
                                Icons.close_rounded,
                                size: 16,
                                color: isDark
                                    ? AppColors.textTertiaryDark
                                    : AppColors.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 短时间内连续点击时，将耗材卷增减合并成一条顶部通知。
class RollSnackCounter {
  static final RollSnackCounter instance = RollSnackCounter._();
  RollSnackCounter._();

  /// 由应用入口提供当前根导航上下文，不长期持有页面 context。
  static BuildContext? Function()? contextProvider;

  Timer? _timer;
  int _delta = 0;
  String _label = '';

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void add(int delta, String label) {
    if (_timer == null || !_timer!.isActive || _label != label) {
      _delta = delta;
      _label = label;
    } else {
      _delta += delta;
    }
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 450), _flush);
  }

  void _flush() {
    final context = contextProvider?.call();
    if (context == null || !context.mounted) {
      _reset();
      return;
    }
    final isAdd = _delta > 0;
    final count = _delta.abs();
    final message = isAdd ? '已补充 $count 卷「$_label」' : '已减少 $count 卷「$_label」';
    showSnack(
      context,
      message,
      tone: isAdd ? AppNoticeTone.success : AppNoticeTone.info,
      iconName: isAdd ? 'add_filament' : 'delete_filament',
      duration: const Duration(milliseconds: 1600),
    );
    _reset();
  }

  void _reset() {
    _delta = 0;
    _label = '';
    _timer = null;
  }
}
