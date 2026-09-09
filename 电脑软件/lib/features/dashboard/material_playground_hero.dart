import 'dart:math' as math;
import '../../core/theme/glass_button_theme.dart';
import '../../widgets/app_glass_button.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/interaction_effects.dart';
import '../../core/startup/startup_handoff.dart';
import '../../core/utils/color_utils.dart';
import '../../core/utils/gram_utils.dart';
import '../../data/database/database.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../providers/consumable_provider.dart';
import '../../providers/printer_connection_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/stock_alert_provider.dart';
import '../../widgets/filament_spool_icon.dart';
import '../../widgets/sohun_wordmark.dart';

/// Narrow status projection used by the hero. Keeping this separate from the
/// connection notifier makes the visual independently testable and prevents
/// unrelated connection fields from rebuilding the scene.
final materialHeroPrinterStatusProvider = Provider<BambuPrinterStatus?>((ref) {
  return ref.watch(
    activePrinterConnectionProvider.select((state) => state.status),
  );
});

/// The dashboard's playful, data-driven entry point.
///
/// This deliberately behaves more like an immersive web hero than a passive
/// dashboard banner: the light field responds gently to the pointer and the
/// spool uses the leading real in-stock color without introducing a hidden
/// carousel or gesture vocabulary.
class MaterialPlaygroundHero extends ConsumerStatefulWidget {
  const MaterialPlaygroundHero({
    super.key,
    required this.onEnterWorkspace,
    this.height = 224,
  });

  final VoidCallback onEnterWorkspace;
  final double height;

  @override
  ConsumerState<MaterialPlaygroundHero> createState() =>
      _MaterialPlaygroundHeroState();
}

class _MaterialPlaygroundHeroState extends ConsumerState<MaterialPlaygroundHero>
    with SingleTickerProviderStateMixin {
  static final Set<String> _sessionReminderKeys = <String>{};

  final ValueNotifier<Offset> _pointer = ValueNotifier(Offset.zero);
  late final AnimationController _entranceController;
  final List<_HeroReminder> _activeReminders = <_HeroReminder>[];
  final Set<String> _scheduledReminderKeys = <String>{};
  Duration? _lastPointerUpdate;
  bool _entranceStarted = false;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 760),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final enabled = AppMotion.enabled(context) && tickerEnabled;
    if (!enabled) {
      _entranceController.value = 1;
      _pointer.value = Offset.zero;
      // Startup prewarms the complete hero under a disabled TickerMode. Mark
      // that static final frame as the entrance so enabling interaction after
      // the handoff cannot restart the hero and make the landing word jump.
      if (!tickerEnabled &&
          (StartupHandoffScope.maybeRead(context)?.isActive ?? false)) {
        _entranceStarted = true;
      }
      return;
    }
    if (!_entranceStarted) {
      _entranceStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _entranceController.forward(from: 0);
      });
    }
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _pointer.dispose();
    super.dispose();
  }

  void _movePointerTo(Offset target, {bool immediate = false}) {
    _pointer.value = immediate
        ? target
        : Offset.lerp(_pointer.value, target, 0.28) ?? target;
  }

  void _scheduleReminders(List<_HeroReminder> candidates) {
    final fresh = candidates
        .where(
          (item) =>
              !_sessionReminderKeys.contains(item.key) &&
              !_scheduledReminderKeys.contains(item.key),
        )
        .toList(growable: false);
    if (fresh.isEmpty) return;
    _scheduledReminderKeys.addAll(fresh.map((item) => item.key));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final available = math.max(0, 2 - _activeReminders.length);
      _sessionReminderKeys.addAll(fresh.map((item) => item.key));
      _scheduledReminderKeys.removeAll(fresh.map((item) => item.key));
      if (available == 0) return;
      setState(() {
        _activeReminders.addAll(fresh.take(available));
      });
    });
  }

  void _removeReminder(String key) {
    if (!mounted) return;
    setState(() {
      _activeReminders.removeWhere((item) => item.key == key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final consumables = ref
        .watch(consumablesProvider)
        .maybeWhen(data: (items) => items, orElse: () => const <Consumable>[]);
    final printers = ref
        .watch(printersWithChannelsProvider)
        .maybeWhen(data: (items) => items.length, orElse: () => 0);
    final activeAlerts = ref
        .watch(stockAlertsProvider)
        .maybeWhen(
          data: (items) => items
              .where((item) => item.level != StockLevel.healthy)
              .toList(growable: false),
          orElse: () => const <StockAlertItem>[],
        );
    final printerStatus = ref.watch(materialHeroPrinterStatusProvider);
    final alertByKey = <String, StockAlertItem>{
      for (final alert in activeAlerts) alert.key: alert,
    };
    final inStock =
        consumables
            .where((item) => item.remainingGrams > 0)
            .toList(growable: false)
          ..sort((a, b) => b.remainingGrams.compareTo(a.remainingGrams));
    final totalGrams = inStock.fold<double>(
      0,
      (total, item) => total + item.remainingGrams,
    );
    final selected = inStock.isEmpty
        ? null
        : _MaterialDatum.fromConsumable(inStock.first);
    final selectedAlert = selected == null
        ? null
        : alertByKey[selected.specKey];
    final activeColor = selected?.color ?? scheme.primary;
    _scheduleReminders(_buildHeroReminders(activeAlerts, printerStatus));

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 820;
        final height = widget.height;
        final expansive = height >= 420;
        final verticalLayout = expansive;
        final size = Size(constraints.maxWidth, height);
        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          onHover: (event) {
            if (!AppMotion.enabled(context)) return;
            final lastUpdate = _lastPointerUpdate;
            if (lastUpdate != null &&
                event.timeStamp - lastUpdate <
                    const Duration(milliseconds: 32)) {
              return;
            }
            _lastPointerUpdate = event.timeStamp;
            _movePointerTo(
              Offset(
                ((event.localPosition.dx / size.width) * 2 - 1).clamp(
                  -1.0,
                  1.0,
                ),
                ((event.localPosition.dy / size.height) * 2 - 1).clamp(
                  -1.0,
                  1.0,
                ),
              ),
            );
          },
          onExit: (_) {
            _lastPointerUpdate = null;
            _movePointerTo(Offset.zero, immediate: true);
          },
          child: SizedBox(
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: dark
                      ? const Color(0xFF1D2420)
                      : const Color(0xFFF8FBF9),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: activeColor.withValues(alpha: dark ? 0.25 : 0.16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: activeColor.withValues(alpha: dark ? 0.08 : 0.07),
                      blurRadius: 32,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _MaterialFieldPainter(
                          pointer: _pointer,
                          primary: scheme.primary,
                          activeColor: activeColor,
                          dark: dark,
                          verticalLayout: verticalLayout,
                        ),
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _entranceController,
                      builder: (context, child) {
                        final value = Curves.easeOutCubic.transform(
                          _entranceController.value,
                        );
                        return Opacity(
                          opacity: value,
                          child: Transform.translate(
                            offset: verticalLayout
                                ? Offset(0, 18 * (1 - value))
                                : Offset(-18 * (1 - value), 0),
                            child: child,
                          ),
                        );
                      },
                      child: Align(
                        alignment: verticalLayout
                            ? Alignment.bottomCenter
                            : Alignment.centerLeft,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            compact ? 22 : 42,
                            22,
                            compact ? 22 : 42,
                            verticalLayout ? (compact ? 28 : 42) : 22,
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: verticalLayout
                                  ? (compact ? constraints.maxWidth - 44 : 640)
                                  : (compact
                                        ? constraints.maxWidth * 0.66
                                        : 500),
                            ),
                            child: _HeroCopy(
                              materialCount: inStock.length,
                              totalGrams: totalGrams,
                              printerCount: printers,
                              selected: selected,
                              selectedAlert: selectedAlert,
                              primary: scheme.primary,
                              compact: compact,
                              expansive: expansive,
                              centered: verticalLayout,
                              onEnterWorkspace: widget.onEnterWorkspace,
                            ),
                          ),
                        ),
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _entranceController,
                      builder: (context, _) {
                        return Stack(
                          children: [
                            _positionedSpool(
                              size: size,
                              color: activeColor,
                              verticalLayout: verticalLayout,
                            ),
                          ],
                        );
                      },
                    ),
                    ...List.generate(_activeReminders.length, (index) {
                      final reminder = _activeReminders[index];
                      return Positioned(
                        right: (compact ? 14.0 : 22.0) + index * 12,
                        bottom: (verticalLayout ? 58.0 : 16.0) + index * 54,
                        width: compact ? 194 : 232,
                        child: _FloatingReminderBubble(
                          key: ValueKey('hero-reminder-${reminder.key}'),
                          reminder: reminder,
                          delay: Duration(milliseconds: index * 850),
                          travelDistance: verticalLayout
                              ? math.min(height * 0.34, 220)
                              : math.min(height * 0.30, 78),
                          onRemoved: () => _removeReminder(reminder.key),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _positionedSpool({
    required Size size,
    required Color color,
    required bool verticalLayout,
  }) {
    final spoolWidth = _spoolWidthFor(size, verticalLayout);
    final spoolHeight = spoolWidth * 4 / 3;
    final center = _spoolCenterFor(size, Offset.zero, verticalLayout);
    final entrance = const Interval(
      0.18,
      0.62,
      curve: Curves.easeOutBack,
    ).transform(_entranceController.value);

    return Positioned(
      left: center.dx - spoolWidth / 2,
      top: center.dy - spoolHeight / 2,
      width: spoolWidth,
      height: spoolHeight,
      child: Transform.scale(
        scale: entrance,
        child: RepaintBoundary(
          child: FilamentSpoolIcon(
            color: color,
            size: spoolWidth,
            dimensional: true,
          ),
        ),
      ),
    );
  }
}

enum _HeroReminderTone { warning, critical, moisture }

class _HeroReminder {
  const _HeroReminder({
    required this.key,
    required this.message,
    required this.icon,
    required this.tone,
  });

  final String key;
  final String message;
  final IconData icon;
  final _HeroReminderTone tone;
}

/// A single-use, compositor-only reminder. The body is isolated in a
/// RepaintBoundary so the 15-second rise only changes transform and opacity;
/// the surrounding hero and its large spool never repaint on each tick.
class _FloatingReminderBubble extends StatefulWidget {
  const _FloatingReminderBubble({
    super.key,
    required this.reminder,
    required this.delay,
    required this.travelDistance,
    required this.onRemoved,
  });

  final _HeroReminder reminder;
  final Duration delay;
  final double travelDistance;
  final VoidCallback onRemoved;

  @override
  State<_FloatingReminderBubble> createState() =>
      _FloatingReminderBubbleState();
}

class _FloatingReminderBubbleState extends State<_FloatingReminderBubble>
    with TickerProviderStateMixin {
  late final AnimationController _riseController;
  late final AnimationController _popController;
  late final Listenable _animation;
  bool _startScheduled = false;
  bool _pausedForHover = false;
  bool _removing = false;

  @override
  void initState() {
    super.initState();
    _riseController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 15000),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed && !_removing) {
            _removing = true;
            widget.onRemoved();
          }
        });
    _popController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _animation = Listenable.merge([_riseController, _popController]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_startScheduled ||
        !AppMotion.enabled(context) ||
        !TickerMode.valuesOf(context).enabled) {
      return;
    }
    _startScheduled = true;
    Future<void>.delayed(widget.delay, () {
      if (!mounted || _removing) return;
      if (!AppMotion.enabled(context) ||
          !TickerMode.valuesOf(context).enabled) {
        _startScheduled = false;
        return;
      }
      _riseController.forward();
    });
  }

  @override
  void dispose() {
    _riseController.dispose();
    _popController.dispose();
    super.dispose();
  }

  void _pause() {
    if (_removing || !_riseController.isAnimating) return;
    _pausedForHover = true;
    _riseController.stop();
  }

  void _resume() {
    if (!_pausedForHover || _removing) return;
    _pausedForHover = false;
    if (AppMotion.enabled(context) && TickerMode.valuesOf(context).enabled) {
      _riseController.forward();
    }
  }

  Future<void> _pop() async {
    if (_removing) return;
    _removing = true;
    _riseController.stop();
    if (!AppMotion.enabled(context)) {
      widget.onRemoved();
      return;
    }
    await _popController.forward(from: 0);
    if (mounted) widget.onRemoved();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = switch (widget.reminder.tone) {
      _HeroReminderTone.critical => scheme.error,
      _HeroReminderTone.warning =>
        dark ? const Color(0xFFFFB75E) : const Color(0xFFB86100),
      _HeroReminderTone.moisture =>
        dark ? const Color(0xFF65D9D0) : const Color(0xFF147E78),
    };
    final fill =
        Color.lerp(scheme.surface, accent, dark ? 0.13 : 0.055) ??
        scheme.surface;

    final body = RepaintBoundary(
      child: CustomPaint(
        key: ValueKey('hero-reminder-bubble-${widget.reminder.key}'),
        painter: _ChatBubblePainter(
          fill: fill,
          outline: accent.withValues(alpha: dark ? 0.48 : 0.32),
          shadow: Colors.black.withValues(alpha: dark ? 0.25 : 0.11),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(13, 10, 14, 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 29,
                height: 29,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: dark ? 0.18 : 0.11),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(widget.reminder.icon, size: 16, color: accent),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.reminder.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurface,
                    fontSize: 11,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      label: '${widget.reminder.message}，点击忽略',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _pause(),
        onExit: (_) => _resume(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _pop,
          child: AnimatedBuilder(
            animation: _animation,
            child: body,
            builder: (context, child) {
              final motionEnabled = AppMotion.enabled(context);
              final rise = _riseController.value;
              final pop = _popController.value;
              final enterOpacity = motionEnabled
                  ? Curves.easeOutCubic.transform((rise / 0.07).clamp(0.0, 1.0))
                  : 1.0;
              final exitOpacity = motionEnabled
                  ? 1 -
                        Curves.easeInCubic.transform(
                          ((rise - 0.84) / 0.16).clamp(0.0, 1.0),
                        )
                  : 1.0;
              final popOpacity = 1 - Curves.easeInCubic.transform(pop);
              final sway =
                  math.sin(
                    rise * math.pi * 2 +
                        (widget.reminder.key.hashCode % 9) * 0.31,
                  ) *
                  5;
              final bodyScale = pop <= 0.26
                  ? 1 + Curves.easeOut.transform(pop / 0.26) * 0.065
                  : 1.065 *
                        (1 -
                            Curves.easeInCubic.transform(
                              ((pop - 0.26) / 0.74).clamp(0.0, 1.0),
                            ));
              return Transform.translate(
                offset: Offset(sway, -rise * widget.travelDistance),
                child: Opacity(
                  opacity: (enterOpacity * exitOpacity * popOpacity).clamp(
                    0.0,
                    1.0,
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (pop > 0)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _BubblePopPainter(
                                color: accent,
                                progress: pop,
                              ),
                            ),
                          ),
                        ),
                      Transform.scale(scale: bodyScale, child: child),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ChatBubblePainter extends CustomPainter {
  const _ChatBubblePainter({
    required this.fill,
    required this.outline,
    required this.shadow,
  });

  final Color fill;
  final Color outline;
  final Color shadow;

  Path _path(Size size) {
    final bodyBottom = size.height - 8;
    return Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(0, 0, size.width, bodyBottom),
          const Radius.circular(17),
        ),
      )
      ..moveTo(size.width - 43, bodyBottom - 1)
      ..lineTo(size.width - 28, size.height)
      ..lineTo(size.width - 24, bodyBottom - 1)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _path(size);
    canvas.drawShadow(path, shadow, 8, false);
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant _ChatBubblePainter oldDelegate) {
    return oldDelegate.fill != fill ||
        oldDelegate.outline != outline ||
        oldDelegate.shadow != shadow;
  }
}

class _BubblePopPainter extends CustomPainter {
  const _BubblePopPainter({required this.color, required this.progress});

  final Color color;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final eased = Curves.easeOutCubic.transform(progress);
    final opacity = (1 - progress).clamp(0.0, 1.0);
    final center = size.center(Offset.zero);
    final ringRect = Rect.fromCenter(
      center: center,
      width: size.width + eased * 18,
      height: size.height + eased * 16,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(ringRect, Radius.circular(17 + eased * 7)),
      Paint()
        ..color = color.withValues(alpha: opacity * 0.42)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    final dotPaint = Paint()..color = color.withValues(alpha: opacity * 0.62);
    for (var index = 0; index < 6; index++) {
      final angle = -math.pi * 0.92 + index * math.pi * 0.37;
      final radius = 8 + eased * 24;
      final edge = Offset(
        center.dx + math.cos(angle) * (size.width / 2 + radius),
        center.dy + math.sin(angle) * (size.height / 2 + radius * 0.56),
      );
      canvas.drawCircle(edge, 1.7 * opacity, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _BubblePopPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.progress != progress;
  }
}

class _HeroCopy extends StatelessWidget {
  const _HeroCopy({
    required this.materialCount,
    required this.totalGrams,
    required this.printerCount,
    required this.selected,
    required this.selectedAlert,
    required this.primary,
    required this.compact,
    required this.expansive,
    required this.centered,
    required this.onEnterWorkspace,
  });

  final int materialCount;
  final double totalGrams;
  final int printerCount;
  final _MaterialDatum? selected;
  final StockAlertItem? selectedAlert;
  final Color primary;
  final bool compact;
  final bool expansive;
  final bool centered;
  final VoidCallback onEnterWorkspace;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectedText = selected == null
        ? null
        : [
            selected!.name,
            selected!.material,
            GramUtils.formatGrams(selected!.grams),
            if (selectedAlert != null) _stockAlertSummary(selectedAlert!),
          ].join(' · ');
    final selectedTextColor = selectedAlert == null
        ? scheme.onSurfaceVariant
        : _stockLevelColor(context, selectedAlert!.level);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: expansive ? 164 : 124,
          height: expansive ? 52 : 39,
          child: StartupLandingTarget(child: SohunWordmark(glow: expansive)),
        ),
        SizedBox(height: expansive ? 9 : 6),
        Text(
          materialCount == 0 ? '从第一卷耗材开始' : '准备好下一次打印',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            fontFamily: AppTypography.chineseFontFamily,
            fontSize: expansive ? (compact ? 30 : 42) : (compact ? 24 : 28),
            height: 1.05,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
        ),
        SizedBox(height: expansive ? 14 : 9),
        Text(
          materialCount == 0
              ? '添加耗材后，它们会以真实颜色出现在这里。'
              : '$materialCount 种在库材料 · ${GramUtils.formatGrams(totalGrams)} 可用 · $printerCount 台设备',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: TextStyle(
            color: scheme.onSurfaceVariant,
            fontSize: expansive ? 14 : 12,
            height: 1.4,
          ),
        ),
        SizedBox(height: expansive ? 12 : 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: selected == null
              ? Text(
                  '添加耗材后，可在上方切换真实颜色',
                  key: const ValueKey('empty-material-hint'),
                  textAlign: centered ? TextAlign.center : TextAlign.start,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                )
              : Row(
                  key: ValueKey(selected!.id),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: selected!.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text(
                        selectedText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selectedTextColor,
                          fontSize: 11,
                          fontWeight: selectedAlert == null
                              ? FontWeight.w400
                              : FontWeight.w600,
                          fontFeatures: const [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        SizedBox(height: expansive ? 22 : 14),
        _EnterWorkspaceButton(
          color: primary,
          prominent: expansive,
          onPressed: onEnterWorkspace,
        ),
      ],
    );
  }
}

class _EnterWorkspaceButton extends StatefulWidget {
  const _EnterWorkspaceButton({
    required this.color,
    required this.prominent,
    required this.onPressed,
  });

  final Color color;
  final bool prominent;
  final VoidCallback onPressed;

  @override
  State<_EnterWorkspaceButton> createState() => _EnterWorkspaceButtonState();
}

class _EnterWorkspaceButtonState extends State<_EnterWorkspaceButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    if (GlassButtonsTheme.enabledOf(context)) {
      return AppGlassButton(
        label: '进入工作区',
        onPressed: widget.onPressed,
        tint: widget.color,
        compact: !widget.prominent,
        minimumSize: Size(0, widget.prominent ? 42 : 36),
        padding: EdgeInsets.symmetric(
          horizontal: widget.prominent ? 20 : 15,
          vertical: widget.prominent ? 12 : 9,
        ),
        borderRadius: BorderRadius.circular(999),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '进入工作区',
              style: TextStyle(
                fontSize: widget.prominent ? 13 : 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 7),
            const Icon(Icons.arrow_downward_rounded, size: 15),
          ],
        ),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedScale(
        scale: _hovering && AppMotion.enabled(context) ? 1.025 : 1,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: Material(
          color: widget.color,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.prominent ? 20 : 15,
                vertical: widget.prominent ? 12 : 9,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '进入工作区',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: widget.prominent ? 13 : 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 7),
                  AnimatedSlide(
                    offset: _hovering ? const Offset(0.16, 0) : Offset.zero,
                    duration: const Duration(milliseconds: 150),
                    child: const Icon(
                      Icons.arrow_downward_rounded,
                      color: Colors.white,
                      size: 15,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MaterialFieldPainter extends CustomPainter {
  _MaterialFieldPainter({
    required this.pointer,
    required this.primary,
    required this.activeColor,
    required this.dark,
    required this.verticalLayout,
  }) : super(repaint: pointer);

  final ValueNotifier<Offset> pointer;
  final Color primary;
  final Color activeColor;
  final bool dark;
  final bool verticalLayout;

  @override
  void paint(Canvas canvas, Size size) {
    final p = pointer.value;
    final cursor = Offset(
      size.width * (0.5 + p.dx * 0.5),
      size.height * (0.5 + p.dy * 0.5),
    );
    final glowPaint = Paint()
      ..shader = ui.Gradient.radial(cursor, math.min(size.width * 0.34, 360), [
        activeColor.withValues(alpha: dark ? 0.16 : 0.12),
        activeColor.withValues(alpha: 0),
      ]);
    canvas.drawRect(Offset.zero & size, glowPaint);

    // The scene has no idle ticker. Its phase comes from the user's gesture,
    // so a still pointer means a still GPU surface and effectively zero
    // animation cost while the dashboard is resting.
    final wave = (p.dx * 0.68 + p.dy * 0.32) * math.pi;
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final lineCount = verticalLayout ? 3 : 4;
    for (var index = 0; index < lineCount; index++) {
      final y = verticalLayout
          ? size.height * (0.15 + index * 0.13)
          : size.height * (0.22 + index * 0.19);
      final drift = math.sin(wave + index * 1.1) * 8;
      final path = Path()
        ..moveTo(size.width * (verticalLayout ? 0.13 : 0.43), y)
        ..cubicTo(
          size.width * (verticalLayout ? 0.32 : 0.57),
          y - (verticalLayout ? 18 : 26) + drift + p.dy * 7,
          size.width * (verticalLayout ? 0.68 : 0.69),
          y + (verticalLayout ? 22 : 30) - drift,
          size.width * (verticalLayout ? 0.87 : 1.04),
          y - 10 + p.dx * 14,
        );
      linePaint
        ..strokeWidth = index == 1 ? 1.5 : 0.8
        ..color = Color.lerp(
          primary,
          activeColor,
          index / 4,
        )!.withValues(alpha: dark ? 0.15 : 0.11);
      canvas.drawPath(path, linePaint);
    }

    final spoolWidth = _spoolWidthFor(size, verticalLayout);
    final spoolHeight = spoolWidth * 4 / 3;
    final center = _spoolCenterFor(size, Offset.zero, verticalLayout);
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: dark ? 0.24 : 0.09)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
    canvas.drawOval(
      Rect.fromCenter(
        center: center + Offset(0, spoolHeight * 0.42),
        width: spoolWidth * 1.08,
        height: spoolWidth * 0.24,
      ),
      shadowPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MaterialFieldPainter oldDelegate) {
    return oldDelegate.primary != primary ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.dark != dark ||
        oldDelegate.verticalLayout != verticalLayout;
  }
}

String _stockSpecKey(Consumable consumable) =>
    '${consumable.manufacturer}|${consumable.materialType}|'
    '${consumable.colorHex}';

Color _stockLevelColor(BuildContext context, StockLevel level) {
  if (level == StockLevel.critical) {
    return Theme.of(context).colorScheme.error;
  }
  return Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFFFFB44D)
      : const Color(0xFFB86100);
}

String _stockAlertSummary(StockAlertItem alert) {
  final label = alert.level == StockLevel.critical ? '需要补货' : '库存偏低';
  final days = alert.estimatedDaysLeft;
  return days >= 0 ? '$label · 预计 $days 天' : label;
}

List<_HeroReminder> _buildHeroReminders(
  List<StockAlertItem> alerts,
  BambuPrinterStatus? printerStatus,
) {
  StockAlertItem? critical;
  StockAlertItem? low;
  for (final alert in alerts) {
    if (alert.level == StockLevel.critical && critical == null) {
      critical = alert;
    } else if (alert.level == StockLevel.low && low == null) {
      low = alert;
    }
  }

  _HeroReminder stockReminder(StockAlertItem alert) {
    final name = alert.colorName?.trim().isNotEmpty == true
        ? alert.colorName!.trim()
        : alert.materialType;
    final amount = GramUtils.formatGrams(alert.totalRemainingGrams);
    final criticalLevel = alert.level == StockLevel.critical;
    final message = criticalLevel
        ? '$name只剩 $amount，建议及时补充'
        : alert.estimatedDaysLeft >= 0
        ? '$name库存偏低，预计可用 ${alert.estimatedDaysLeft} 天'
        : '$name库存偏低，当前剩余 $amount';
    return _HeroReminder(
      key: 'stock:${alert.key}:${alert.level.name}',
      message: message,
      icon: Icons.inventory_2_outlined,
      tone: criticalLevel
          ? _HeroReminderTone.critical
          : _HeroReminderTone.warning,
    );
  }

  final reminders = <_HeroReminder>[];
  if (critical != null) reminders.add(stockReminder(critical));

  final humidity = printerStatus?.amsHumidity;
  if (humidity != null && humidity > 60 && printerStatus?.amsDrying != true) {
    reminders.add(
      _HeroReminder(
        key: 'ams-humidity:${printerStatus!.serial}',
        message: 'AMS 湿度 $humidity%，建议开启干燥',
        icon: Icons.water_drop_outlined,
        tone: _HeroReminderTone.moisture,
      ),
    );
  }

  if (low != null) reminders.add(stockReminder(low));
  return reminders;
}

class _MaterialDatum {
  const _MaterialDatum({
    required this.id,
    required this.specKey,
    required this.color,
    required this.name,
    required this.material,
    required this.grams,
  });

  factory _MaterialDatum.fromConsumable(Consumable consumable) {
    final displayName = consumable.colorName?.trim().isNotEmpty == true
        ? consumable.colorName!.trim()
        : consumable.model.trim().isNotEmpty
        ? consumable.model.trim()
        : consumable.manufacturer.trim().isNotEmpty
        ? consumable.manufacturer.trim()
        : '未命名耗材';
    return _MaterialDatum(
      id: consumable.id,
      specKey: _stockSpecKey(consumable),
      color: ColorUtils.fromHex(
        consumable.colorHex,
        fallback: AppColors.primary,
      ),
      name: displayName,
      material: consumable.materialType,
      grams: consumable.remainingGrams,
    );
  }

  final int id;
  final String specKey;
  final Color color;
  final String name;
  final String material;
  final double grams;
}

double _spoolWidthFor(Size size, bool verticalLayout) {
  if (!verticalLayout) {
    return (size.height * 0.24).clamp(104.0, 184.0);
  }
  final preferred = (size.height * 0.29).clamp(148.0, 220.0);
  return math.min(preferred, size.width * 0.42);
}

Offset _spoolCenterFor(Size size, Offset pointer, bool verticalLayout) {
  if (!verticalLayout) {
    return Offset(
      size.width * 0.77 + pointer.dx * 8,
      size.height * 0.48 + pointer.dy * 6,
    );
  }
  return Offset(
    size.width * 0.5 + pointer.dx * 10,
    size.height * 0.285 + pointer.dy * 7,
  );
}

/// A small perspective response used by the four dashboard metric cards.
///
/// The transform is intentionally restrained: it gives the pointer a physical
/// consequence without turning everyday reading into a carnival ride.
class DashboardHoverPlane extends StatefulWidget {
  const DashboardHoverPlane({super.key, required this.child, this.tint});

  final Widget child;
  final Color? tint;

  @override
  State<DashboardHoverPlane> createState() => _DashboardHoverPlaneState();
}

class _DashboardHoverPlaneState extends State<DashboardHoverPlane> {
  Offset _tilt = Offset.zero;
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final enabled = AppMotion.enabled(context);
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0012)
      ..rotateX(enabled ? -_tilt.dy * 0.035 : 0)
      ..rotateY(enabled ? _tilt.dx * 0.045 : 0)
      ..translateByDouble(0, _hovering && enabled ? -2 : 0, 0, 1);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onHover: (event) {
        if (!enabled) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        setState(() {
          _tilt = Offset(
            (event.localPosition.dx / box.size.width) * 2 - 1,
            (event.localPosition.dy / box.size.height) * 2 - 1,
          );
        });
      },
      onExit: (_) => setState(() {
        _hovering = false;
        _tilt = Offset.zero;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOutCubic,
        transform: matrix,
        transformAlignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppColors.radiusLg),
          boxShadow: _hovering
              ? [
                  BoxShadow(
                    color:
                        (widget.tint ?? Theme.of(context).colorScheme.primary)
                            .withValues(alpha: 0.10),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ]
              : const [],
        ),
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}
