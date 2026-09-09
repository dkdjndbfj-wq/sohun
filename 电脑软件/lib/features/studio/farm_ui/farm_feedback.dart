import 'dart:async';

import 'package:flutter/material.dart';

import 'farm_theme.dart';

enum AppNoticeTone { success, error, warning, info }

OverlayEntry? _activeFarmNotice;

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
  if (_activeFarmNotice?.mounted ?? false) _activeFarmNotice!.remove();
  _activeFarmNotice = null;
  final resolvedTone = error ? AppNoticeTone.error : tone;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _FarmTopNotice(
      message: message,
      tone: resolvedTone,
      duration: duration ??
          Duration(
              milliseconds: resolvedTone == AppNoticeTone.error ? 4500 : 2000),
      actionLabel: actionLabel,
      onAction: onAction,
      onDismissed: () {
        if (entry.mounted) entry.remove();
        if (identical(_activeFarmNotice, entry)) _activeFarmNotice = null;
      },
    ),
  );
  _activeFarmNotice = entry;
  overlay.insert(entry);
}

class _FarmTopNotice extends StatefulWidget {
  const _FarmTopNotice({
    required this.message,
    required this.tone,
    required this.duration,
    required this.onDismissed,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final AppNoticeTone tone;
  final Duration duration;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismissed;

  @override
  State<_FarmTopNotice> createState() => _FarmTopNoticeState();
}

class _FarmTopNoticeState extends State<_FarmTopNotice>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _timer;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 130),
    )..forward();
    _timer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_closing) return;
    _closing = true;
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
    final scheme = Theme.of(context).colorScheme;
    final color = switch (widget.tone) {
      AppNoticeTone.success => FarmPalette.success,
      AppNoticeTone.error => FarmPalette.danger,
      AppNoticeTone.warning => FarmPalette.warning,
      AppNoticeTone.info => FarmPalette.info,
    };
    final icon = switch (widget.tone) {
      AppNoticeTone.success => Icons.check_circle_outline,
      AppNoticeTone.error => Icons.error_outline,
      AppNoticeTone.warning => Icons.warning_amber_rounded,
      AppNoticeTone.info => Icons.info_outline,
    };
    final curved = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 54,
      left: 16,
      right: 16,
      child: Center(
        child: FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, -0.18),
              end: Offset.zero,
            ).animate(curved),
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Container(
                  key: const ValueKey('farm-top-notice'),
                  padding: const EdgeInsets.fromLTRB(12, 9, 7, 9),
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(FarmPalette.radius),
                    border: Border.all(color: scheme.outlineVariant),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.14),
                        blurRadius: 18,
                        offset: const Offset(0, 7),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Icon(icon, size: 17, color: color),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.message,
                          maxLines: widget.tone == AppNoticeTone.error ? 3 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.35,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (widget.actionLabel != null &&
                          widget.onAction != null) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () {
                            widget.onAction!();
                            _dismiss();
                          },
                          child: Text(widget.actionLabel!),
                        ),
                      ],
                      const SizedBox(width: 3),
                      IconButton(
                        tooltip: '关闭提示',
                        onPressed: _dismiss,
                        icon: const Icon(Icons.close_rounded, size: 16),
                      ),
                    ],
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
