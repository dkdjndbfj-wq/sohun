import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/services/app_update_service.dart';
import '../../core/services/remote_config_service.dart'
    show isValidAppReleaseVersion;
import '../../core/startup/startup_handoff.dart';
import '../../core/theme/interaction_effects.dart';
import '../../data/prefs/app_prefs.dart';
import 'app_update_dialog.dart';

String _normalizedVersion(String value) =>
    value.trim().replaceFirst(RegExp(r'^[vV]'), '');

/// A skipped release belongs to one installed platform, never to the account.
/// Mandatory policy deliberately does not consult this preference.
class AppUpdateSkippedVersionNotifier
    extends StateNotifier<AsyncValue<String?>> {
  AppUpdateSkippedVersionNotifier({String? platform})
    : platform = platform ?? Platform.operatingSystem,
      super(const AsyncLoading()) {
    ready = _load();
  }

  final String platform;
  late final Future<void> ready;

  String get preferenceKey => 'app_update_skipped_version_v1_$platform';

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final version = preferences.getString(preferenceKey);
      if (mounted) {
        state = AsyncData(version == null ? null : _normalizedVersion(version));
      }
    } catch (_) {
      if (mounted) state = const AsyncData(null);
    }
  }

  Future<void> skipVersion(String version) async {
    await ready;
    final normalized = _normalizedVersion(version);
    if (normalized.isEmpty || !mounted) return;
    // Keep this session quiet even if local preference storage is unavailable.
    state = AsyncData(normalized);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(preferenceKey, normalized);
    } catch (_) {
      // The update center remains available; a later launch can remind again.
    }
  }

  Future<void> clearSkippedVersion() async {
    await ready;
    if (!mounted) return;
    state = const AsyncData(null);
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(preferenceKey);
    } catch (_) {
      // Preference storage must never become an update-screen dead end.
    }
  }
}

final appUpdateSkippedVersionProvider =
    StateNotifierProvider<AppUpdateSkippedVersionNotifier, AsyncValue<String?>>(
      (ref) => AppUpdateSkippedVersionNotifier(),
    );

/// Endpoint initialization may replace the service with an idle instance. Keep
/// the confirmed policy until a verified result explicitly releases it.
class AppUpdateGatePolicyNotifier extends StateNotifier<AppUpdateState?> {
  AppUpdateGatePolicyNotifier() : super(null);

  void accept(AppUpdateState next) {
    final required = state;
    if (next.hasUpdate && next.isMandatory) {
      if (required == null ||
          compareAppVersions(next.latestVersion!, required.latestVersion!) >=
              0) {
        state = next;
        return;
      }
    }
    if (required == null) return;
    final confirmed =
        (next.phase == AppUpdatePhase.available ||
            next.phase == AppUpdatePhase.upToDate) &&
        !next.isChecking &&
        !next.isMandatory &&
        next.mandatoryPolicyResolved &&
        next.checkedAt != null &&
        next.latestVersion != null &&
        isValidAppReleaseVersion(next.latestVersion!) &&
        compareAppVersions(next.latestVersion!, required.latestVersion!) >= 0;
    if (confirmed) {
      state = null;
    } else {
      state = required.copyWith(
        phase: next.phase,
        isChecking: next.isChecking,
        message: next.message,
      );
    }
  }
}

final appUpdateGatePolicyProvider =
    StateNotifierProvider<AppUpdateGatePolicyNotifier, AppUpdateState?>((ref) {
      final policy = AppUpdateGatePolicyNotifier();
      ref.listen<AppUpdateState>(
        appUpdateServiceProvider,
        (_, next) => policy.accept(next),
        fireImmediately: true,
      );
      return policy;
    });

/// Hardware-facing surfaces use the same latched policy as the root layer.
final appUpdateRequiredProvider = Provider<bool>(
  (ref) => ref.watch(appUpdateGatePolicyProvider) != null,
);

class _UpdateGatePopEntry extends PopEntry<Object?> {
  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier(true);

  VoidCallback? onBlockedPop;

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop) onBlockedPop?.call();
  }
}

/// Install once on the same MaterialApp whose builder contains [AppUpdateGate].
/// PopEntry covers system/predictive back; the root Stack also survives direct
/// programmatic route pushes and pops, which cannot dismiss a required update.
class AppUpdateNavigationObserver extends NavigatorObserver
    with ChangeNotifier {
  final Set<ModalRoute<dynamic>> _routes = {};
  final _popEntry = _UpdateGatePopEntry();
  bool _notificationScheduled = false;
  bool _disposed = false;

  bool get hasCoveringRoute => navigator?.canPop() ?? false;

  void setGateVisible(bool visible, {VoidCallback? onDismiss}) {
    _popEntry.onBlockedPop = onDismiss;
    _popEntry.canPopNotifier.value = !visible;
  }

  void _added(Route<dynamic>? route) {
    if (route is ModalRoute<dynamic> && _routes.add(route)) {
      route.registerPopEntry(_popEntry);
    }
    _routeChanged();
  }

  void _removed(Route<dynamic>? route) {
    if (route is ModalRoute<dynamic> && _routes.remove(route)) {
      route.unregisterPopEntry(_popEntry);
    }
    _routeChanged();
  }

  void _routeChanged() {
    if (_notificationScheduled || _disposed) return;
    _notificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _added(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _removed(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _removed(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _removed(oldRoute);
    _added(newRoute);
  }

  @override
  void dispose() {
    _disposed = true;
    _popEntry.onBlockedPop = null;
    for (final route in _routes) {
      route.unregisterPopEntry(_popEntry);
    }
    _routes.clear();
    _popEntry.canPopNotifier.dispose();
    super.dispose();
  }
}

/// An app-owned update surface above the Navigator, including login and dialogs.
/// The child keeps its element/state throughout the gate so inventory commits
/// and background reconciliation can finish while user interaction is blocked.
class AppUpdateGate extends ConsumerStatefulWidget {
  const AppUpdateGate({
    super.key,
    required this.child,
    required this.navigationObserver,
    this.initialCheckReady,
    this.optionalPromptsReady,
    this.allowOptionalPrompts = true,
    this.optionalPromptDelay = Duration.zero,
  });

  final Widget child;
  final AppUpdateNavigationObserver navigationObserver;
  final Future<void> Function()? initialCheckReady;
  final Future<void>? optionalPromptsReady;
  final bool allowOptionalPrompts;
  final Duration optionalPromptDelay;

  @override
  ConsumerState<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends ConsumerState<AppUpdateGate>
    with WidgetsBindingObserver {
  final _focusScope = FocusScopeNode(
    debugLabel: 'App update gate',
    traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
  );
  final Set<String> _dismissedVersions = {};
  Timer? _optionalDelay;
  DateTime? _lastCheckStartedAt;
  bool _checking = false;
  bool _optionalReady = false;
  bool _delayElapsed = false;
  bool _handoffReady = false;
  bool _handoffObserved = false;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.navigationObserver.addListener(_routeChanged);
    // Start loading reminder preferences before reading their default value.
    ref.read(autoCheckUpdatesProvider);
    unawaited(_prepareOptionalPrompt());
    _delayElapsed = widget.optionalPromptDelay == Duration.zero;
    if (!_delayElapsed) {
      _optionalDelay = Timer(widget.optionalPromptDelay, () {
        if (mounted) setState(() => _delayElapsed = true);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_check());
    });
  }

  Future<void> _prepareOptionalPrompt() async {
    await ref.read(appUpdateSkippedVersionProvider.notifier).ready;
    await widget.optionalPromptsReady;
    if (mounted) setState(() => _optionalReady = true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_handoffObserved) return;
    _handoffObserved = true;
    final handoff = StartupHandoffScope.maybeRead(context);
    if (handoff == null || !handoff.isActive) {
      _handoffReady = true;
    } else {
      unawaited(
        handoff.completed.then((_) {
          if (mounted) setState(() => _handoffReady = true);
        }),
      );
    }
  }

  @override
  void didUpdateWidget(covariant AppUpdateGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationObserver != widget.navigationObserver) {
      oldWidget.navigationObserver
        ..removeListener(_routeChanged)
        ..setGateVisible(false);
      widget.navigationObserver.addListener(_routeChanged);
    }
  }

  void _routeChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _check({bool force = false}) async {
    if (!mounted || _checking) return;
    final now = DateTime.now();
    final last = _lastCheckStartedAt;
    if (!force && last != null && now.difference(last).inSeconds < 30) return;
    _checking = true;
    _lastCheckStartedAt = now;
    try {
      await widget.initialCheckReady?.call();
      if (!mounted) return;
      await ref.read(appUpdateServiceProvider.notifier).checkForUpdates();
    } catch (error) {
      // Initialization/network errors cannot dismiss a previously required
      // update or become an unhandled Future in an otherwise usable app.
      debugPrint('更新检查暂未完成：$error');
    } finally {
      _checking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  void _dismissOptional() {
    if (ref.read(appUpdateRequiredProvider)) return;
    final update = ref.read(appUpdateServiceProvider);
    if (update.isMandatory) return;
    final version = update.latestVersion;
    if (version == null || !mounted) return;
    setState(() => _dismissedVersions.add(_normalizedVersion(version)));
  }

  void _skipVersion() {
    if (ref.read(appUpdateRequiredProvider)) return;
    final update = ref.read(appUpdateServiceProvider);
    if (update.isMandatory || update.latestVersion == null) return;
    _dismissOptional();
    unawaited(
      ref
          .read(appUpdateSkippedVersionProvider.notifier)
          .skipVersion(update.latestVersion!),
    );
  }

  @override
  Future<bool> didPopRoute() async {
    if (!_visible) return false;
    _dismissOptional();
    return true;
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => _visible;

  @override
  void handleCommitBackGesture() => _dismissOptional();

  @override
  void dispose() {
    _optionalDelay?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.navigationObserver
      ..removeListener(_routeChanged)
      ..setGateVisible(false);
    _focusScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final serviceUpdate = ref.watch(appUpdateServiceProvider);
    final requiredUpdate = ref.watch(appUpdateGatePolicyProvider);
    final update = requiredUpdate ?? serviceUpdate;
    final skipped = ref.watch(appUpdateSkippedVersionProvider);
    final remindersEnabled = ref.watch(autoCheckUpdatesProvider);
    final mandatory = ref.watch(appUpdateRequiredProvider);
    final version = _normalizedVersion(update.latestVersion ?? '');
    final optional =
        update.hasUpdate &&
        !mandatory &&
        remindersEnabled &&
        widget.allowOptionalPrompts &&
        _optionalReady &&
        _delayElapsed &&
        _handoffReady &&
        skipped.hasValue &&
        skipped.valueOrNull != version &&
        !_dismissedVersions.contains(version) &&
        !widget.navigationObserver.hasCoveringRoute;
    final visible = mandatory || optional;
    widget.navigationObserver.setGateVisible(
      visible,
      onDismiss: visible && !mandatory ? _dismissOptional : null,
    );
    if (visible && !_visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _visible) _focusScope.requestFocus();
      });
    }
    _visible = visible;

    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: visible,
          child: ExcludeFocus(
            excluding: visible,
            child: AbsorbPointer(absorbing: visible, child: widget.child),
          ),
        ),
        if (visible)
          Positioned.fill(
            key: const ValueKey('app-update-gate-overlay'),
            child: Overlay.wrap(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ModalBarrier(
                    color: Colors.black.withValues(alpha: .38),
                    dismissible: !mandatory,
                    onDismiss: mandatory ? null : _dismissOptional,
                    barrierSemanticsDismissible: !mandatory,
                    semanticsLabel: mandatory ? null : '稍后提醒',
                  ),
                  SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey('update-entry-$version-$mandatory'),
                          tween: Tween(begin: 0, end: 1),
                          duration: AppMotion.duration(
                            context,
                            const Duration(milliseconds: 200),
                          ),
                          curve: Curves.easeOutCubic,
                          builder: (context, value, child) => Opacity(
                            opacity: value,
                            child: Transform.scale(
                              scale: .97 + .03 * value,
                              child: child,
                            ),
                          ),
                          child: FocusScope(
                            node: _focusScope,
                            autofocus: true,
                            onKeyEvent: (node, event) {
                              if (event.logicalKey !=
                                  LogicalKeyboardKey.escape) {
                                return KeyEventResult.ignored;
                              }
                              if (event is KeyDownEvent) _dismissOptional();
                              return KeyEventResult.handled;
                            },
                            child: Semantics(
                              scopesRoute: true,
                              namesRoute: true,
                              explicitChildNodes: true,
                              liveRegion: true,
                              label: mandatory ? '需要更新' : '发现新版本',
                              child: AppUpdatePanel(
                                key: ValueKey('update-$version-$mandatory'),
                                update: update,
                                onDownload: () => ref
                                    .read(appUpdateServiceProvider.notifier)
                                    .openDownloadPage(
                                      verifiedDownloadUri: update.downloadUri,
                                    ),
                                onRetry: () => _check(force: true),
                                onLater: mandatory ? null : _dismissOptional,
                                onSkipVersion: mandatory ? null : _skipVersion,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
