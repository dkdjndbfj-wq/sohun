import 'dart:async';

import 'package:consumable_tracker_desktop/core/services/app_update_service.dart';
import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/features/updates/app_update_dialog.dart';
import 'package:consumable_tracker_desktop/features/updates/app_update_gate.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_account_app.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_writer_page.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('跳过版本按平台持久化，重新创建偏好后仍有效', () async {
    final windows = AppUpdateSkippedVersionNotifier(platform: 'windows');
    final android = AppUpdateSkippedVersionNotifier(platform: 'android');
    await Future.wait([windows.ready, android.ready]);
    await windows.skipVersion('v9.0.0+7');
    expect(windows.state.valueOrNull, '9.0.0+7');
    expect(android.state.valueOrNull, isNull);
    windows.dispose();
    final restored = AppUpdateSkippedVersionNotifier(platform: 'windows');
    await restored.ready;
    expect(restored.state.valueOrNull, '9.0.0+7');
    await restored.clearSkippedVersion();
    expect(
      (await SharedPreferences.getInstance()).containsKey(
        restored.preferenceKey,
      ),
      isFalse,
    );
    restored.dispose();
    android.dispose();
  });

  testWidgets('强制页覆盖后续路由、隔离输入与语义，返回和Esc不能绕过', (tester) async {
    final fixture = await _mount(tester);
    final semantics = tester.ensureSemantics();
    try {
      await tester.enterText(find.byType(TextField), '尚未提交的库存备注');
      expect(_semanticsTree(tester), contains('后台库存按钮'));
      fixture.updates.emit(_update(mandatory: true));
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdatePanel), findsOneWidget);
      expect(find.byKey(const ValueKey('update-later')), findsNothing);
      expect(find.byKey(const ValueKey('update-skip')), findsNothing);
      expect(find.byKey(const ValueKey('update-close')), findsNothing);
      expect(_semanticsTree(tester), isNot(contains('后台库存按钮')));
      fixture.business.currentState!.focus.requestFocus();
      await tester.pump();
      expect(fixture.business.currentState!.focus.hasFocus, isFalse);
      await tester.tapAt(const Offset(15, 15));
      await tester.tap(find.text('后台库存按钮'), warnIfMissed: false);
      expect(fixture.business.currentState!.taps, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdatePanel), findsOneWidget);

      unawaited(
        fixture.navigator.currentState!.push<void>(
          MaterialPageRoute(
            settings: const RouteSettings(name: '/login'),
            builder: (_) => const Scaffold(body: Text('后台登录页面')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdatePanel), findsOneWidget);
      expect(find.text('后台登录页面').hitTestable(), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(fixture.navigator.currentState!.canPop(), isTrue);
      expect(find.byType(AppUpdatePanel), findsOneWidget);

      fixture.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      fixture.updates.emit(_upToDate());
      await tester.pumpAndSettle();
      expect(find.byType(AppUpdatePanel), findsNothing);
      expect(find.text('尚未提交的库存备注'), findsOneWidget);
      await tester.tap(find.text('后台库存按钮'));
      await tester.pump();
      expect(fixture.business.currentState!.taps, 1);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('外部下载成功、服务重建idle和网络失败均不能释放强制策略', (tester) async {
    final fixture = await _mount(tester, initial: _update(mandatory: true));
    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.pumpAndSettle();
    expect(fixture.updates.downloads, 1);
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    fixture.updates.emit(const AppUpdateState(currentVersion: '1.0.0'));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    expect(fixture.container.read(appUpdateRequiredProvider), isTrue);
    await tester.tap(find.byKey(const ValueKey('update-download')));
    await tester.pumpAndSettle();
    expect(fixture.updates.downloads, 2);
    expect(fixture.updates.lastDownloadUri, _update().downloadUri);
    fixture.updates.emit(
      const AppUpdateState(
        phase: AppUpdatePhase.failed,
        currentVersion: '1.0.0',
        message: '暂时无法连接更新服务',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    fixture.updates.emit(_update(version: '2.0.0', mandatory: false));
    await tester.pumpAndSettle();
    expect(fixture.container.read(appUpdateRequiredProvider), isTrue);
    fixture.updates.emit(
      _update(mandatory: false).copyWith(mandatoryPolicyResolved: false),
    );
    await tester.pumpAndSettle();
    expect(
      fixture.container.read(appUpdateRequiredProvider),
      isTrue,
      reason: '没有显式撤回策略的元数据不能释放另一服务实例留下的强制更新',
    );
    fixture.updates.emit(_update(mandatory: false));
    await tester.pumpAndSettle();
    expect(fixture.container.read(appUpdateRequiredProvider), isFalse);
    expect(find.byKey(const ValueKey('update-later')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-later')));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsNothing);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets('关闭新版本提醒仍执行检查并展示强制更新，恢复前台合并短期检查', (tester) async {
    SharedPreferences.setMockInitialValues({
      'auto_check_updates_enabled': false,
    });
    final fixture = await _mount(tester, initial: _update());
    expect(fixture.updates.checks, 1);
    expect(find.byType(AppUpdatePanel), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fixture.updates.checks, 1);
    fixture.updates.emit(_update(mandatory: true));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-retry')));
    await tester.pumpAndSettle();
    expect(fixture.updates.checks, 2, reason: '明确点重试不受前台恢复的节流限制');
    await _unmount(tester);
  });

  testWidgets('跳过本版本压制普通自动提醒，但版本升级和强制策略仍可出现', (tester) async {
    final fixture = await _mount(tester, initial: _update());
    await tester.tap(find.byKey(const ValueKey('update-skip')));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsNothing);
    expect(
      fixture.container.read(appUpdateSkippedVersionProvider).valueOrNull,
      '9.0.0',
    );
    fixture.updates.emit(_update());
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsNothing);
    fixture.updates.emit(_update(version: '9.0.1'));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsNothing);
    fixture.updates.emit(_update(mandatory: true));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('普通提醒等待欢迎和已打开路由结束，强制更新不等待', (tester) async {
    final startup = Completer<void>();
    final fixture = await _mount(
      tester,
      initial: _update(),
      optionalPromptsReady: startup.future,
    );
    expect(find.byType(AppUpdatePanel), findsNothing);
    fixture.updates.emit(_update(mandatory: true));
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    fixture.updates.emit(_update());
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsNothing);
    unawaited(
      fixture.navigator.currentState!.push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/app-updates'),
          builder: (_) => const Scaffold(body: Text('手动更新中心')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    startup.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsNothing);
    fixture.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('手机强制页使登记页停用，解除后恢复原tab及未提交表单', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final auth = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _EmptyOverrideStore(),
        compileTimeBaseUrl: 'https://update-test.example.test',
      ),
      sessionStore: _EmptySessionStore(),
      apiFactory: (_) => throw UnimplementedError(),
    );
    await auth.ready;
    final updates = _ControlledUpdates(const AppUpdateState());
    const channel = MethodChannel('top.sohun/consumable_rfid');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUpdateServiceProvider.overrideWith((ref) => updates),
          databaseProvider.overrideWithValue(database),
          appAuthProvider.overrideWith((ref) => auth),
          communityApiProvider.overrideWithValue(null),
          personalConsumablesByOwnerProvider(
            '',
          ).overrideWith((ref) => Stream.value(const <Consumable>[])),
        ],
        child: MobileRfidAccountApp(
          interactionEffectsEnabled: false,
          loadMaterials: () async => ['PLA+'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '未提交的品牌');
    expect(
      tester
          .widget<MobileRfidWriterPage>(find.byType(MobileRfidWriterPage))
          .isActive,
      isTrue,
    );
    updates.emit(_update(mandatory: true));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MobileRfidWriterPage>(find.byType(MobileRfidWriterPage))
          .isActive,
      isFalse,
    );
    expect(find.byType(AppUpdatePanel), findsOneWidget);
    updates.emit(const AppUpdateState());
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MobileRfidWriterPage>(find.byType(MobileRfidWriterPage))
          .isActive,
      isFalse,
    );
    updates.emit(_upToDate());
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MobileRfidWriterPage>(find.byType(MobileRfidWriterPage))
          .isActive,
      isTrue,
    );
    expect(find.text('未提交的品牌'), findsOneWidget);
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      0,
    );
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });
}

AppUpdateState _update({bool mandatory = false, String version = '9.0.0'}) =>
    AppUpdateState(
      phase: AppUpdatePhase.available,
      currentVersion: '1.0.0',
      latestVersion: version,
      isMandatory: mandatory,
      mandatoryPolicyResolved: !mandatory,
      releaseNotes: '改进库存与连接体验。',
      downloadUri: Uri.parse('https://www.sohun.top/downloads'),
      checkedAt: DateTime(2026, 9, 8),
    );

AppUpdateState _upToDate() => AppUpdateState(
  phase: AppUpdatePhase.upToDate,
  currentVersion: '9.0.0',
  latestVersion: '9.0.0',
  mandatoryPolicyResolved: true,
  checkedAt: DateTime(2026, 9, 8),
);

class _ControlledUpdates extends StateNotifier<AppUpdateState>
    implements AppUpdateService {
  _ControlledUpdates(super.state);
  int checks = 0;
  int downloads = 0;
  Uri? lastDownloadUri;

  void emit(AppUpdateState update) => state = update;

  @override
  Future<AppUpdateState> checkForUpdates() async {
    checks++;
    return state;
  }

  @override
  Future<bool> openDownloadPage({Uri? verifiedDownloadUri}) async {
    downloads++;
    lastDownloadUri = verifiedDownloadUri ?? state.downloadUri;
    return true;
  }
}

class _Fixture {
  _Fixture(this.updates, this.navigator, this.business, this.container);
  final _ControlledUpdates updates;
  final GlobalKey<NavigatorState> navigator;
  final GlobalKey<_BusinessSurfaceState> business;
  final ProviderContainer container;
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  AppUpdateState initial = const AppUpdateState(),
  Future<void>? optionalPromptsReady,
}) async {
  await tester.binding.setSurfaceSize(const Size(1024, 768));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final updates = _ControlledUpdates(initial);
  final navigator = GlobalKey<NavigatorState>();
  final business = GlobalKey<_BusinessSurfaceState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appUpdateServiceProvider.overrideWith((ref) => updates)],
      child: _GateHarness(
        navigator: navigator,
        business: business,
        optionalPromptsReady: optionalPromptsReady,
      ),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(AppUpdateGate)),
  );
  return _Fixture(updates, navigator, business, container);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

String _semanticsTree(WidgetTester tester) => tester
    .binding
    .renderViews
    .single
    .owner!
    .semanticsOwner!
    .rootSemanticsNode!
    .toStringDeep();

class _GateHarness extends StatefulWidget {
  const _GateHarness({
    required this.navigator,
    required this.business,
    this.optionalPromptsReady,
  });
  final GlobalKey<NavigatorState> navigator;
  final GlobalKey<_BusinessSurfaceState> business;
  final Future<void>? optionalPromptsReady;

  @override
  State<_GateHarness> createState() => _GateHarnessState();
}

class _GateHarnessState extends State<_GateHarness> {
  final observer = AppUpdateNavigationObserver();

  @override
  void dispose() {
    observer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    navigatorKey: widget.navigator,
    navigatorObservers: [observer],
    builder: (context, child) => InteractionEffectsScope(
      enabled: false,
      child: AppUpdateGate(
        navigationObserver: observer,
        optionalPromptsReady: widget.optionalPromptsReady,
        child: child!,
      ),
    ),
    home: _BusinessSurface(key: widget.business),
  );
}

class _BusinessSurface extends StatefulWidget {
  const _BusinessSurface({super.key});

  @override
  State<_BusinessSurface> createState() => _BusinessSurfaceState();
}

class _BusinessSurfaceState extends State<_BusinessSurface> {
  final focus = FocusNode();
  int taps = 0;

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextField(focusNode: focus),
        TextButton(
          onPressed: () => setState(() => taps++),
          child: const Text('后台库存按钮'),
        ),
      ],
    ),
  );
}

class _EmptySessionStore implements AppAuthSessionStore {
  @override
  Future<void> clear() async {}
  @override
  Future<AppAuthSession?> read() async => null;
  @override
  Future<void> write(AppAuthSession session) async {}
}

class _EmptyOverrideStore implements CommunityServerOverrideStore {
  @override
  Future<void> clear() async {}
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
}
