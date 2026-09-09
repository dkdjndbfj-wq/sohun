import 'package:flutter/material.dart';

import '../core/theme/interaction_effects.dart';
import '../core/theme/theme_brand_assets.dart';
import '../core/theme/theme_color.dart';

/// The same themed sohun artwork shipped by the personal desktop app.
class MobileBrandMark extends StatelessWidget {
  const MobileBrandMark({super.key, this.size = 52});
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = ThemeColorDef.all.firstWhere(
      (value) => value.seed == theme.colorScheme.primary,
      orElse: () => ThemeColorDef.auroraGreen,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.25),
      child: Image.asset(
        ThemeBrandAssets.png(color, Brightness.light),
        width: size,
        height: size,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, 512),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => SizedBox.square(
          dimension: size,
          child: Center(
            child: Text(
              'S',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A short, one-shot cold-start handoff. It never waits for network/auth, and
/// keeps the navigator subtree mounted throughout the transition.
class MobileBrandLaunch extends StatefulWidget {
  const MobileBrandLaunch({super.key, required this.child});
  final Widget child;
  @override
  State<MobileBrandLaunch> createState() => _MobileBrandLaunchState();
}

class _MobileBrandLaunchState extends State<MobileBrandLaunch>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );
  late final _reveal = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.45, 1, curve: Curves.easeOutCubic),
  );
  late final _logo = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0, 0.65, curve: Curves.easeOutCubic),
  );
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_statusChanged);
  }

  void _statusChanged(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!AppMotion.enabled(context)) {
      _controller.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    _logo.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = _controller.isCompleted;
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: !done,
          child: ExcludeFocus(
            excluding: !done,
            child: IgnorePointer(
              ignoring: !done,
              child: FadeTransition(opacity: _reveal, child: widget.child),
            ),
          ),
        ),
        if (!done)
          Positioned.fill(
            child: FadeTransition(
              opacity: ReverseAnimation(_reveal),
              child: Material(
                key: const ValueKey('mobile-brand-launch'),
                color: theme.scaffoldBackgroundColor,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0.15, -0.2),
                      radius: 0.9,
                      colors: [
                        theme.colorScheme.primary.withValues(alpha: 0.09),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: SafeArea(
                    child: Stack(
                      children: [
                        Center(
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: 0.94,
                              end: 1,
                            ).animate(_logo),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const MobileBrandMark(size: 104),
                                const SizedBox(height: 22),
                                Text(
                                  'sohun',
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(
                                        fontSize: 30,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '让每一卷，都物尽其用',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 20,
                          right: 20,
                          bottom: 32,
                          child: Text(
                            '耗材管理 · 个人版',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
