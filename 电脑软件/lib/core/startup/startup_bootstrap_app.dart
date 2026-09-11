import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../app.dart';
import '../../data/prefs/app_prefs.dart';
import '../../providers/database_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/theme_provider.dart';
import '../app_identity.dart';
import '../theme/app_theme.dart';
import '../theme/interaction_effects.dart';
import 'startup_coordinator.dart';
import 'startup_handoff.dart';
import 'startup_window_controller.dart';

typedef StartupTask =
    Future<StartupResult> Function(StartupProgressCallback onProgress);

class StartupBootstrapApp extends ConsumerStatefulWidget {
  const StartupBootstrapApp({
    super.key,
    this.startupTask,
    this.appBuilder,
    this.minimumSplashDuration = Duration.zero,
    this.prepareMainWindow,
    this.updateMainWindowTransition,
    this.showMainWindow,
  });

  final StartupTask? startupTask;
  final Widget Function(StartupResult result)? appBuilder;
  final Duration minimumSplashDuration;
  final Future<void> Function()? prepareMainWindow;
  final ValueChanged<double>? updateMainWindowTransition;
  final Future<void> Function()? showMainWindow;

  @override
  ConsumerState<StartupBootstrapApp> createState() =>
      _StartupBootstrapAppState();
}

class _StartupBootstrapAppState extends ConsumerState<StartupBootstrapApp> {
  static const _initialProgress = StartupProgress(
    phase: StartupPhase.preparing,
    value: 0.02,
    label: '正在启动 sohun…',
  );

  StartupProgress _progress = _initialProgress;
  StartupResult? _result;
  StartupFailure? _failure;
  bool _started = false;
  bool _motionEnabled = true;
  bool _handoffReady = false;
  bool _transitionComplete = false;
  Widget? _applicationWidget;
  Timer? _minimumTimer;
  Completer<void>? _minimumDelayCompleter;
  late final StartupHandoffController _startupHandoff;

  @override
  void initState() {
    super.initState();
    _startupHandoff = StartupHandoffController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_start());
    });
  }

  Future<void> _start() async {
    if (_started || !mounted) return;
    _started = true;
    unawaited(windowManager.show().catchError((_) {}));
    final platformDisablesAnimations = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    final effectsEnabled =
        ref.read(interactionEffectsEnabledProvider) &&
        !platformDisablesAnimations;
    _motionEnabled = effectsEnabled;
    final minimumDelay = _createMinimumDelay(effectsEnabled);

    try {
      void onProgress(StartupProgress progress) {
        if (mounted) setState(() => _progress = progress);
      }

      final customTask = widget.startupTask;
      final result = customTask != null
          ? await customTask(onProgress)
          : await StartupCoordinator().initialize(
              onProgress: onProgress,
              database: ref.read(databaseProvider),
            );

      if (!mounted) {
        await result.database.close();
        return;
      }
      setState(() {
        _result = result;
        _applicationWidget =
            widget.appBuilder?.call(result) ?? const ConsumableTrackerApp();
      });

      // Mount the complete application behind the opaque startup layer first.
      // Its local providers, first layout, icons and cached preferences are
      // therefore ready before the native window starts changing size.
      await Future.wait<void>([minimumDelay, _prewarmApplication()]);
      if (!mounted) {
        await result.database.close();
        return;
      }
      setState(() => _handoffReady = true);
    } on StartupFailure catch (failure) {
      _cancelMinimumDelay();
      if (mounted) {
        setState(() => _failure = failure);
        unawaited(StartupWindowController.prepareFailureWindow());
      }
    } catch (error) {
      _cancelMinimumDelay();
      if (mounted) {
        setState(() {
          _failure = StartupFailure(
            title: '启动未完成',
            message: '应用初始化时遇到意外错误。\n\n$error',
          );
        });
        unawaited(StartupWindowController.prepareFailureWindow());
      }
    }
  }

  Future<void> _prewarmApplication() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    try {
      // The mounted title bar already starts decoding the brand asset. Keep an
      // explicit warm-up too, but do not make a decoder callback the gate for
      // the native window animation.
      unawaited(
        precacheImage(
          const AssetImage(AppIdentity.iconAsset),
          context,
        ).catchError((_) {}),
      );
      await ref.read(onboardingCompletedProvider.future);
    } catch (error) {
      debugPrint(
        'Startup prewarm continued after a non-critical error: $error',
      );
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  bool get _usesCustomWindowTransition =>
      widget.prepareMainWindow != null ||
      widget.updateMainWindowTransition != null ||
      widget.showMainWindow != null;

  Future<void> _beginWindowHandoff(Color backgroundColor) async {
    _startupHandoff.updateProgress(0);
    if (_usesCustomWindowTransition) {
      await widget.prepareMainWindow?.call();
      return;
    }
    await StartupWindowController.prepareMainWindowTransition(
      backgroundColor: backgroundColor,
    );
  }

  void _updateWindowHandoff(double progress) {
    _startupHandoff.updateProgress(progress);
    if (_usesCustomWindowTransition) {
      widget.updateMainWindowTransition?.call(progress);
      return;
    }
    StartupWindowController.updateMainWindowTransition(progress);
  }

  Future<void> _completeWindowHandoff() async {
    if (_usesCustomWindowTransition) {
      await widget.showMainWindow?.call();
    } else {
      await StartupWindowController.finishMainWindowTransition();
    }
    _startupHandoff.complete();
    if (mounted) setState(() => _transitionComplete = true);
  }

  Future<void> _createMinimumDelay(bool enabled) {
    if (!enabled || widget.minimumSplashDuration == Duration.zero) {
      return Future<void>.value();
    }
    final completer = Completer<void>();
    _minimumDelayCompleter = completer;
    _minimumTimer = Timer(widget.minimumSplashDuration, () {
      if (!completer.isCompleted) completer.complete();
      _minimumTimer = null;
      _minimumDelayCompleter = null;
    });
    return completer.future;
  }

  void _cancelMinimumDelay() {
    _minimumTimer?.cancel();
    _minimumTimer = null;
    final completer = _minimumDelayCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    _minimumDelayCompleter = null;
  }

  @override
  void dispose() {
    _cancelMinimumDelay();
    _startupHandoff.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final application = _applicationWidget;
    final themeMode = ref.watch(themeModeProvider);
    final themeColor = ref.watch(themeColorProvider);
    final platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final useDark =
        themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            platformBrightness == Brightness.dark);
    final transitionTheme = useDark
        ? AppTheme.darkFrom(themeColor.seed, themeColor.accent)
        : AppTheme.lightFrom(themeColor.seed, themeColor.accent);
    final transitionScheme = transitionTheme.colorScheme;
    final transitionBackground = Color.lerp(
      transitionScheme.surface,
      transitionScheme.primary,
      useDark ? 0.025 : 0.012,
    )!;

    return StartupHandoffScope(
      controller: _startupHandoff,
      child: ColoredBox(
        key: const ValueKey('startup-native-backing'),
        color: transitionBackground,
        child: Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          alignment: Alignment.topLeft,
          children: [
            if (result != null && application != null)
              _ApplicationStage(
                interactive: _transitionComplete,
                child: KeyedSubtree(
                  key: const ValueKey('application'),
                  child: application,
                ),
              ),
            if (!_transitionComplete)
              _StartupMaterialApp(
                key: const ValueKey('startup'),
                progress: _progress,
                failure: _failure,
                ready: _handoffReady,
                animate: _motionEnabled,
                onHandoffStarted: () =>
                    _beginWindowHandoff(transitionBackground),
                onHandoffProgress: _updateWindowHandoff,
                onHandoffCompleted: _completeWindowHandoff,
              ),
          ],
        ),
      ),
    );
  }
}

class _ApplicationStage extends StatelessWidget {
  const _ApplicationStage({required this.interactive, required this.child});

  final bool interactive;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TickerMode(
      enabled: interactive,
      child: IgnorePointer(
        ignoring: !interactive,
        child: ExcludeSemantics(
          excluding: !interactive,
          child: RepaintBoundary(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = interactive
                    ? constraints.biggest
                    : StartupWindowController.mainSize;
                return OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: size.width,
                  maxWidth: size.width,
                  minHeight: size.height,
                  maxHeight: size.height,
                  child: SizedBox.fromSize(size: size, child: child),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _StartupMaterialApp extends ConsumerWidget {
  const _StartupMaterialApp({
    super.key,
    required this.progress,
    required this.failure,
    required this.ready,
    required this.animate,
    required this.onHandoffStarted,
    required this.onHandoffProgress,
    required this.onHandoffCompleted,
  });

  final StartupProgress progress;
  final StartupFailure? failure;
  final bool ready;
  final bool animate;
  final Future<void> Function() onHandoffStarted;
  final ValueChanged<double> onHandoffProgress;
  final Future<void> Function() onHandoffCompleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final themeColor = ref.watch(themeColorProvider);
    final effectsEnabled = ref.watch(interactionEffectsEnabledProvider);
    return MaterialApp(
      title: AppIdentity.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightFrom(themeColor.seed, themeColor.accent),
      darkTheme: AppTheme.darkFrom(themeColor.seed, themeColor.accent),
      themeMode: themeMode,
      builder: (context, child) {
        final systemDisablesAnimations =
            MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        return InteractionEffectsScope(
          enabled: effectsEnabled && !systemDisablesAnimations,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: _StartupScreen(
        progress: progress,
        failure: failure,
        ready: ready,
        animate: animate,
        onHandoffStarted: onHandoffStarted,
        onHandoffProgress: onHandoffProgress,
        onHandoffCompleted: onHandoffCompleted,
      ),
    );
  }
}

class _StartupScreen extends StatelessWidget {
  const _StartupScreen({
    required this.progress,
    required this.failure,
    required this.ready,
    required this.animate,
    required this.onHandoffStarted,
    required this.onHandoffProgress,
    required this.onHandoffCompleted,
  });

  final StartupProgress progress;
  final StartupFailure? failure;
  final bool ready;
  final bool animate;
  final Future<void> Function() onHandoffStarted;
  final ValueChanged<double> onHandoffProgress;
  final Future<void> Function() onHandoffCompleted;

  @override
  Widget build(BuildContext context) {
    if (failure != null) {
      return Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Center(child: _StartupFailurePanel(failure: failure!)),
      );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _StartupReveal(
        progress: progress,
        ready: ready,
        animate: animate && AppMotion.enabled(context),
        onHandoffStarted: onHandoffStarted,
        onHandoffProgress: onHandoffProgress,
        onHandoffCompleted: onHandoffCompleted,
      ),
    );
  }
}

class _StartupReveal extends StatefulWidget {
  const _StartupReveal({
    required this.progress,
    required this.ready,
    required this.animate,
    required this.onHandoffStarted,
    required this.onHandoffProgress,
    required this.onHandoffCompleted,
  });

  final StartupProgress progress;
  final bool ready;
  final bool animate;
  final Future<void> Function() onHandoffStarted;
  final ValueChanged<double> onHandoffProgress;
  final Future<void> Function() onHandoffCompleted;

  @override
  State<_StartupReveal> createState() => _StartupRevealState();
}

class _StartupRevealState extends State<_StartupReveal>
    with TickerProviderStateMixin {
  late final AnimationController _introController;
  late final AnimationController _handoffController;
  bool _handoffScheduled = false;

  @override
  void initState() {
    super.initState();
    _introController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: widget.animate ? 0 : 1,
    );
    _handoffController = AnimationController(
      vsync: this,
      duration: StartupWindowController.transitionDuration,
    )..addListener(_reportHandoffProgress);
    if (widget.animate) _introController.forward();
    if (widget.ready) _scheduleHandoff();
  }

  @override
  void didUpdateWidget(covariant _StartupReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate && !widget.animate) {
      _introController.value = 1;
    }
    if (!oldWidget.ready && widget.ready) _scheduleHandoff();
  }

  void _reportHandoffProgress() {
    widget.onHandoffProgress(_handoffController.value);
  }

  void _scheduleHandoff() {
    if (_handoffScheduled) return;
    _handoffScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        // Initialization can finish before the intro; it must not wait for art.
        _introController.stop();
        _introController.value = 1;
        if (!mounted) return;
        await widget.onHandoffStarted();
        if (!mounted) return;
        if (widget.animate) {
          await _handoffController.forward().orCancel;
        } else {
          _handoffController.value = 1;
        }
        if (!mounted) return;
        widget.onHandoffProgress(1);
        await widget.onHandoffCompleted();
      } on TickerCanceled {
        // A forced shutdown can dispose the startup layer mid-handoff.
      }
    });
  }

  @override
  void dispose() {
    _handoffController.removeListener(_reportHandoffProgress);
    _introController.dispose();
    _handoffController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final value = widget.progress.value.clamp(0.0, 1.0);
    return Semantics(
      key: const ValueKey('startup-progress-semantics'),
      label: widget.progress.label,
      value: (value * 100).round().toString() + '%',
      liveRegion: true,
      child: FadeTransition(
        opacity: ReverseAnimation(_handoffController),
        child: ColoredBox(
          key: const ValueKey('startup-backdrop'),
          color: scheme.surface,
          child: Center(
            child: FadeTransition(
              opacity: _introController,
              child: SlideTransition(
                position:
                    Tween<Offset>(
                          begin: const Offset(0, 0.04),
                          end: Offset.zero,
                        )
                        .chain(CurveTween(curve: Curves.easeOutCubic))
                        .animate(_introController),
                child: SizedBox(
                  width: 280,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RepaintBoundary(
                        child: Column(
                          children: [
                            Container(
                              width: 72,
                              height: 72,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer.withValues(
                                  alpha: 0.45,
                                ),
                                borderRadius: BorderRadius.circular(22),
                                border: Border.all(
                                  color: scheme.primary.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Image.asset(
                                AppIdentity.iconAsset,
                                cacheWidth: 144,
                                cacheHeight: 144,
                                filterQuality: FilterQuality.medium,
                                errorBuilder: (_, error, stack) => Icon(
                                  Icons.layers_rounded,
                                  color: scheme.primary,
                                  size: 40,
                                ),
                              ),
                            ),
                            const SizedBox(height: 22),
                            Text(
                              'sohun',
                              key: const ValueKey('startup-brand'),
                              style: TextStyle(
                                fontSize: 36,
                                height: 1.1,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -1.2,
                                color: scheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 9),
                            Text(
                              '让耗材与打印，轻松归位',
                              style: TextStyle(
                                fontSize: 13,
                                letterSpacing: 0.8,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 42),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          key: const ValueKey('startup-progress-bar'),
                          value: value,
                          minHeight: 3,
                          backgroundColor: scheme.primary.withValues(
                            alpha: 0.08,
                          ),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            scheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              widget.progress.label,
                              maxLines: 2,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            (value * 100).round().toString() + '%',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
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

class _StartupFailurePanel extends StatelessWidget {
  const _StartupFailurePanel({required this.failure});

  final StartupFailure failure;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 580),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 34,
              color: colorScheme.error,
            ),
            const SizedBox(height: 18),
            Text(
              failure.title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            SelectableText(
              failure.message,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
