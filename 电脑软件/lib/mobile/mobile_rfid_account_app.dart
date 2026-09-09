import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/interaction_effects.dart';
import '../core/theme/theme_color.dart';
import '../core/services/personal_inventory_sync_service.dart';
import '../data/external/community/community_api_client.dart';
import '../data/external/slicer/material_catalog_service.dart';
import '../data/models/app_auth.dart';
import '../data/prefs/app_prefs.dart';
import '../data/prefs/theme_prefs.dart';
import '../features/updates/app_update_gate.dart';
import 'mobile_account_page.dart';
import 'mobile_auth_page.dart';
import 'mobile_brand_launch.dart';
import 'mobile_visual_theme.dart';
import '../providers/app_auth_provider.dart';
import '../providers/database_provider.dart';
import 'mobile_inventory_sync.dart';
import 'mobile_inventory_page.dart';
import 'mobile_rfid_writer_page.dart';
import 'mobile_rfid_tag_repository.dart';
import 'rfid_native_bridge.dart';
import 'mobile_printer_faults.dart';
import 'device_tag_nfc.dart';
import 'mobile_device_workbench.dart';
import '../providers/device_workbench_provider.dart';

/// Android entry surface for the desktop inventory extension.
///
/// The page itself stays deliberately small. This shell supplies the same
/// theme, account session and local database that the desktop application
/// uses, then selects local-only or account-backed inventory sync at runtime.
class MobileRfidAccountApp extends ConsumerStatefulWidget {
  const MobileRfidAccountApp({
    super.key,
    this.themeMode = ThemeMode.system,
    this.themeColor = ThemeColorDef.auroraGreen,
    this.interactionEffectsEnabled = true,
    this.loadMaterials,
  });

  final ThemeMode themeMode;
  final ThemeColorDef themeColor;
  final bool interactionEffectsEnabled;

  /// Optional catalog source for embedders and deterministic UI tests.
  final Future<List<String>> Function()? loadMaterials;

  @override
  ConsumerState<MobileRfidAccountApp> createState() =>
      _MobileRfidAccountAppState();
}

class _MobileRfidAccountAppState extends ConsumerState<MobileRfidAccountApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _updateNavigationObserver = AppUpdateNavigationObserver();
  StreamSubscription<String>? _deviceUriSubscription;
  bool _devicePageOpen = false;
  bool _deviceNavigationScheduled = false;
  late ThemeMode _themeMode = widget.themeMode;
  late bool _interactionEffectsEnabled = widget.interactionEffectsEnabled;

  Future<void> _setTheme(ThemeMode mode) async {
    await ThemePrefs.setMode(mode);
    if (mounted) setState(() => _themeMode = mode);
  }

  Future<void> _setEffects(bool enabled) async {
    await AppPrefs.setInteractionEffectsEnabled(enabled);
    if (mounted) setState(() => _interactionEffectsEnabled = enabled);
  }

  // A MethodChannel exposes one Flutter method-call handler. Reuse a single
  // bridge across the CUID/FUID writer and batch scanner so a second surface
  // cannot overwrite an in-flight operation's event handler.
  final MethodChannelRfidNativeBridge _nfcBridge =
      MethodChannelRfidNativeBridge();

  @override
  void initState() {
    super.initState();
    ref.listenManual<AppAuthState>(
      appAuthProvider,
      _onAuthChanged,
      fireImmediately: true,
    );
    final deviceNfc = ref.read(deviceTagNfcProvider);
    _deviceUriSubscription = deviceNfc.deviceUris.listen(_receiveDeviceUri);
    unawaited(
      deviceNfc.takePendingDeviceUri().then((uri) {
        if (uri != null && mounted) _receiveDeviceUri(uri);
      }),
    );
    ref.listenManual(appUpdateRequiredProvider, (_, required) {
      if (!required && ref.read(deviceTagOpenRequestProvider) != null) {
        _scheduleDeviceWorkbench();
      }
    });
  }

  void _receiveDeviceUri(String uri) {
    final tag = DeviceTagUri.parse(uri);
    if (!mounted || tag == null) return;
    ref.read(deviceTagOpenRequestProvider.notifier).state = tag.token;
    _scheduleDeviceWorkbench();
  }

  void _scheduleDeviceWorkbench() {
    if (!mounted || _devicePageOpen || _deviceNavigationScheduled) return;
    _deviceNavigationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _deviceNavigationScheduled = false;
      if (mounted && !ref.read(appUpdateRequiredProvider))
        unawaited(_openDeviceWorkbench());
    });
  }

  Future<void> _openDeviceWorkbench() async {
    final navigator = _navigatorKey.currentState;
    if (!mounted ||
        _devicePageOpen ||
        navigator == null ||
        ref.read(appUpdateRequiredProvider))
      return;
    setState(() => _devicePageOpen = true);
    try {
      await navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => MobileDeviceWorkbenchPage(
            onAccountTap: () => navigator.push<bool>(
              MaterialPageRoute(builder: (_) => const MobileAuthPage()),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        ref.read(deviceTagOpenRequestProvider.notifier).state = null;
        setState(() => _devicePageOpen = false);
      }
    }
  }

  void _onAuthChanged(AppAuthState? previous, AppAuthState next) {
    final previousKey = _personalSessionKey(previous);
    final nextKey = _personalSessionKey(next);
    final session = next.session;
    if (nextKey == null || nextKey == previousKey || session == null) return;
    final api = ref.read(communityApiProvider);
    if (api is! PersonalInventoryApi) return;
    final personalApi = api as PersonalInventoryApi;
    // Login should not surface an unhandled asynchronous error when the
    // server is offline.  Keep the local inventory usable and let the next
    // explicit write/refresh retry the same account-scoped merge.
    unawaited(_synchronizeAfterLogin(session, personalApi));
  }

  @override
  void dispose() {
    unawaited(_deviceUriSubscription?.cancel());
    _updateNavigationObserver.dispose();
    super.dispose();
  }

  Future<void> _synchronizeAfterLogin(
    AppAuthSession session,
    PersonalInventoryApi api,
  ) async {
    try {
      await AccountMobileInventorySync(
        dao: ref.read(consumableDaoProvider),
        api: api,
        session: session,
        ensureSession: () =>
            ref.read(appAuthProvider.notifier).ensureValidSession(),
      ).synchronizeExisting();
    } catch (error, stackTrace) {
      // This is a background reconciliation.  It must never become an
      // unhandled Future error or block the NFC workflow; the account sync
      // adapter will retry on the next write.
      debugPrint('手机登录后个人库存同步失败：$error\n$stackTrace');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(mobilePrinterFaultProvider);
    final auth = ref.watch(appAuthProvider);
    final dao = ref.watch(consumableDaoProvider);
    final api = ref.watch(communityApiProvider);
    final session = auth.session;
    final ownerAccount = session != null && session.authRealm == 'personal'
        ? PersonalInventorySyncService.ownerAccountFor(session)
        : '';
    final tagRepository = ref.watch(mobileRfidTagRepositoryProvider);

    final MobileInventorySync sync;
    if (session != null &&
        session.authRealm == 'personal' &&
        api is PersonalInventoryApi) {
      sync = AccountMobileInventorySync(
        dao: dao,
        api: api as PersonalInventoryApi,
        session: session,
        ensureSession: () =>
            ref.read(appAuthProvider.notifier).ensureValidSession(),
      );
    } else {
      sync = LocalMobileInventorySync(dao);
    }

    final accountLabel = session?.user.displayName ?? session?.user.email;
    return MaterialApp(
      navigatorKey: _navigatorKey,
      navigatorObservers: [_updateNavigationObserver],
      debugShowCheckedModeBanner: false,
      theme: _mobileTheme(
        AppTheme.lightFrom(widget.themeColor.seed, widget.themeColor.accent),
      ),
      darkTheme: _mobileTheme(
        AppTheme.darkFrom(widget.themeColor.seed, widget.themeColor.accent),
      ),
      themeMode: _themeMode,
      themeAnimationDuration: _interactionEffectsEnabled
          ? const Duration(milliseconds: 220)
          : Duration.zero,
      builder: (context, child) {
        final systemDisablesAnimations =
            MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        return InteractionEffectsScope(
          enabled: _interactionEffectsEnabled && !systemDisablesAnimations,
          child: AppUpdateGate(
            navigationObserver: _updateNavigationObserver,
            initialCheckReady: () => ref.read(appAuthProvider.notifier).ready,
            optionalPromptDelay: const Duration(milliseconds: 800),
            child: MobileBrandLaunch(child: child ?? const SizedBox.shrink()),
          ),
        );
      },
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: _MobileAppShell(
        nfc: _nfcBridge,
        allowNfcWriter: !_devicePageOpen,
        onOpenDevices: _openDeviceWorkbench,
        sync: sync,
        loadMaterials: widget.loadMaterials ?? _loadDesktopMaterials,
        accountLabel: accountLabel,
        accountIdentity: _personalSessionIdentity(session),
        ownerAccount: ownerAccount,
        tagRepository: tagRepository,
        themeMode: _themeMode,
        interactionEffectsEnabled: _interactionEffectsEnabled,
        onThemeChanged: _setTheme,
        onEffectsChanged: _setEffects,
        onScanCuidFuid: _scanCuidFuid,
        onRefreshInventory: _refreshInventory,
      ),
    );
  }

  /// Scans only safe MIFARE metadata. Blank CUID/FUID media does not contain
  /// brand/model/color, so the batch sheet keeps those fields editable and
  /// uses this result solely to bind the physical UID.
  Future<MobileInventoryTagScan?> _scanCuidFuid() async {
    final result = await _nfcBridge.scanMifareClassic();
    if (result is RfidScanFailure) {
      if (result.code == 'scan_cancelled') return null;
      throw StateError(result.message);
    }
    if (result is! RfidMifareScanSuccess) {
      throw StateError('无法识别 CUID/FUID 标签');
    }
    final tagId = result.tagId?.trim();
    if (tagId == null || tagId.isEmpty) {
      throw StateError('标签未返回 UID');
    }
    final session = ref.read(appAuthProvider).session;
    final owner = session != null && session.authRealm == 'personal'
        ? PersonalInventorySyncService.ownerAccountFor(session)
        : null;
    try {
      await ref
          .read(mobileRfidTagRepositoryProvider)
          .recordScan(
            tagUid: tagId,
            tagType: result.tagType,
            technology: result.technology,
            profile: 'ams',
            ownerAccount: owner,
            verified: false,
            message: 'CUID/FUID UID 扫描；仅记录安全元数据',
          );
    } catch (_) {
      // A scan can still be used for this batch if the local audit table is
      // unavailable during a migration; inventory sync remains authoritative.
    }
    return MobileInventoryTagScan(tagId: tagId, tagType: result.tagType);
  }

  /// Pull the account snapshot on an explicit inventory refresh.  Signed-out
  /// users remain local-only, so merely opening or viewing the inventory does
  /// not trigger a network request.
  Future<void> _refreshInventory() async {
    final session = ref.read(appAuthProvider).session;
    final sync = _syncFor(session);
    if (sync is AccountMobileInventorySync) {
      await sync.synchronizeExisting();
    }
  }

  MobileInventorySync _syncFor(AppAuthSession? session) {
    final dao = ref.read(consumableDaoProvider);
    final api = ref.read(communityApiProvider);
    if (session != null &&
        session.authRealm == 'personal' &&
        api is PersonalInventoryApi) {
      return AccountMobileInventorySync(
        dao: dao,
        api: api as PersonalInventoryApi,
        session: session,
        ensureSession: () =>
            ref.read(appAuthProvider.notifier).ensureValidSession(),
      );
    }
    return LocalMobileInventorySync(dao);
  }

  Future<List<String>> _loadDesktopMaterials() async {
    final additional = <String>{};
    try {
      final auth = ref.read(appAuthProvider);
      final session = auth.session;
      final localRows = session != null && session.authRealm == 'personal'
          ? await ref
                .read(consumableDaoProvider)
                .getPersonalForOwnerAccount(
                  PersonalInventorySyncService.ownerAccountFor(session),
                )
          // A signed-out phone may still have legacy local rows, but must not
          // expose another sohun account's private model names in the picker.
          : await ref
                .read(consumableDaoProvider)
                .getPersonalForOwnerAccount('');
      for (final row in localRows) {
        if (row.model.trim().isNotEmpty) additional.add(row.model.trim());
        if (row.materialType.trim().isNotEmpty) {
          additional.add(row.materialType.trim());
        }
      }
    } catch (_) {
      // The packaged catalog still keeps the writer usable if SQLite is busy.
    }

    final session = ref.read(appAuthProvider).session;
    if (session != null && session.authRealm == 'personal') {
      try {
        final currentSession = await ref
            .read(appAuthProvider.notifier)
            .ensureValidSession();
        final currentApi = ref.read(communityApiProvider);
        if (currentSession.authRealm == 'personal' &&
            currentApi is PersonalInventoryApi) {
          final snapshot = await (currentApi as PersonalInventoryApi)
              .fetchPersonalInventory(accessToken: currentSession.accessToken);
          additional.addAll(snapshot.materialCatalog);
          for (final record in snapshot.records) {
            if (record.model.trim().isNotEmpty) {
              additional.add(record.model);
            }
            if (record.materialType.trim().isNotEmpty) {
              additional.add(record.materialType);
            }
          }
        }
      } catch (_) {
        // Offline mobile sessions use the same packaged desktop-compatible
        // catalog and keep the local model names already collected above.
      }
    }
    return MaterialCatalogService.load(additional: additional);
  }
}

ThemeData _mobileTheme(ThemeData theme) => buildMobileTheme(theme);

/// Mobile navigation shell. The writer remains the primary landing surface,
/// while inventory gets its own full-height tab so the two workflows never
/// compete for one crowded page.
class _MobileAppShell extends ConsumerStatefulWidget {
  const _MobileAppShell({
    required this.nfc,
    required this.allowNfcWriter,
    required this.onOpenDevices,
    required this.sync,
    required this.loadMaterials,
    required this.accountLabel,
    required this.accountIdentity,
    required this.ownerAccount,
    required this.tagRepository,
    required this.onScanCuidFuid,
    required this.onRefreshInventory,
    required this.themeMode,
    required this.interactionEffectsEnabled,
    required this.onThemeChanged,
    required this.onEffectsChanged,
  });

  final RfidNativeBridge nfc;
  final bool allowNfcWriter;
  final VoidCallback onOpenDevices;
  final MobileInventorySync sync;
  final Future<List<String>> Function() loadMaterials;
  final String? accountLabel;
  final String? accountIdentity;
  final String? ownerAccount;
  final MobileRfidTagRepository? tagRepository;
  final MobileInventoryTagScanner? onScanCuidFuid;
  final Future<void> Function() onRefreshInventory;
  final ThemeMode themeMode;
  final bool interactionEffectsEnabled;
  final Future<void> Function(ThemeMode) onThemeChanged;
  final Future<void> Function(bool) onEffectsChanged;

  @override
  ConsumerState<_MobileAppShell> createState() => _MobileAppShellState();
}

class _MobileAppShellState extends ConsumerState<_MobileAppShell> {
  int _index = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(mobileFaultOpenRequestProvider) > 0) {
        _selectPage(2);
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _selectPage(int index) {
    if (index == _index || !_pageController.hasClients) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final duration = AppMotion.duration(
      context,
      const Duration(milliseconds: 260),
    );
    if (duration == Duration.zero) {
      _pageController.jumpToPage(index);
    } else {
      _pageController.animateToPage(
        index,
        duration: duration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(mobileFaultOpenRequestProvider, (_, next) {
      if (next > 0) _selectPage(2);
    });
    final updateRequired = ref.watch(appUpdateRequiredProvider);
    return MobileScaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          FocusManager.instance.primaryFocus?.unfocus();
          setState(() => _index = index);
        },
        children: [
          _MobileTab(
            active: _index == 0,
            child: MobileRfidWriterPage(
              nfc: widget.nfc,
              isActive: _index == 0 && !updateRequired && widget.allowNfcWriter,
              sync: widget.sync,
              loadMaterials: widget.loadMaterials,
              accountLabel: widget.accountLabel,
              accountIdentity: widget.accountIdentity,
              ownerAccount: widget.ownerAccount,
              tagRepository: widget.tagRepository,
              onAccountTap: (_) => _selectPage(3),
              pageTitle: '耗材标签登记',
            ),
          ),
          _MobileTab(
            active: _index == 1,
            child: MobileInventoryPage(
              sync: widget.sync,
              loadMaterials: widget.loadMaterials,
              accountLabel: widget.accountLabel,
              accountIdentity: widget.accountIdentity,
              ownerAccount: widget.ownerAccount,
              tagRepository: widget.tagRepository,
              onAccountTap: (_) => _selectPage(3),
              onOpenWriter: () => _selectPage(0),
              onScanCuidFuid: widget.onScanCuidFuid,
              onCancelTagScan: widget.nfc.cancel,
              onRefreshInventory: widget.onRefreshInventory,
            ),
          ),
          _MobileTab(
            active: _index == 2,
            child: MobilePrinterFaultPage(onAccountTap: () => _selectPage(3)),
          ),
          _MobileTab(
            active: _index == 3,
            child: MobileAccountPage(
              themeMode: widget.themeMode,
              interactionEffectsEnabled: widget.interactionEffectsEnabled,
              onThemeChanged: widget.onThemeChanged,
              onEffectsChanged: widget.onEffectsChanged,
              onOpenInventory: () => _selectPage(1),
              onOpenDevices: widget.onOpenDevices,
            ),
          ),
        ],
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: MobileGlassSurface(
          radius: 22,
          opacity: 0.64,
          elevated: true,
          child: NavigationBar(
            height: 64,
            animationDuration: AppMotion.duration(
              context,
              const Duration(milliseconds: 260),
            ),
            selectedIndex: _index,
            onDestinationSelected: _selectPage,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.nfc_outlined),
                selectedIcon: Icon(Icons.nfc_rounded),
                label: '标签登记',
              ),
              NavigationDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2_rounded),
                label: '耗材库存',
              ),
              NavigationDestination(
                icon: Icon(Icons.notifications_none_rounded),
                selectedIcon: Icon(Icons.notifications_rounded),
                label: '打印提醒',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline_rounded),
                selectedIcon: Icon(Icons.person_rounded),
                label: '我的',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PageView otherwise disposes off-screen forms. Retain input and scroll
/// position, but pause decorative tickers and focus in the hidden tab.
class _MobileTab extends StatefulWidget {
  const _MobileTab({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<_MobileTab> createState() => _MobileTabState();
}

class _MobileTabState extends State<_MobileTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return TickerMode(
      enabled: widget.active,
      child: ExcludeFocus(excluding: !widget.active, child: widget.child),
    );
  }
}

String? _personalSessionKey(AppAuthState? state) {
  return _personalSessionIdentity(state?.session);
}

String? _personalSessionIdentity(AppAuthSession? session) {
  if (session == null || session.authRealm != 'personal') return null;
  return '${session.serverBaseUrl}|${session.user.id}|${session.user.email.toLowerCase()}';
}
