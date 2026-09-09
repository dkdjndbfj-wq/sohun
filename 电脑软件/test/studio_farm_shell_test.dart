import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/external/community/studio_api_client.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connection_store.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/core/app_variant.dart';
import 'package:consumable_tracker_desktop/features/studio/studio_farm_shell.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('农场工作台未登录时提供管理员、成员和访客入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: '',
      ),
      sessionStore: _MemorySessionStore(),
      apiFactory: (_) => throw UnimplementedError(),
    );
    await notifier.ready;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appAuthProvider.overrideWith((ref) => notifier),
          printerConnectionStoreProvider.overrideWithValue(
            _EmptyPrinterConnectionStore(),
          ),
          mergedPrinterListProvider.overrideWithValue(const []),
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: const MaterialApp(home: StudioFarmWorkspace()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('使用软件账号登录'), findsOneWidget);
    expect(find.text('注册软件账号'), findsOneWidget);
    expect(find.text('开通农场管理员账号'), findsOneWidget);
    expect(find.text('农场成员登录'), findsOneWidget);
    expect(find.text('以访客身份进入'), findsOneWidget);
    expect(
      find.text('返回个人工作台'),
      AppVariant.isPersonal ? findsOneWidget : findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('访客可使用设备功能但业务数据页面保持锁定', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: '',
      ),
      sessionStore: _MemorySessionStore(),
      apiFactory: (_) => throw UnimplementedError(),
    );
    await notifier.ready;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appAuthProvider.overrideWith((ref) => notifier),
          databaseProvider.overrideWithValue(database),
          printerConnectionStoreProvider.overrideWithValue(
            _EmptyPrinterConnectionStore(),
          ),
          mergedPrinterListProvider.overrideWithValue(const []),
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: const MaterialApp(home: StudioFarmWorkspace()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('以访客身份进入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('访客设备总览'), findsOneWidget);
    expect(find.text('扫描并批量添加'), findsOneWidget);
    expect(find.text('设备矩阵'), findsNothing);
    expect(find.text('设备与耗材'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsWidgets);

    await tester.tap(find.text('项目订单'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('项目订单 需要农场账号'), findsOneWidget);
    expect(find.textContaining('访客模式不会读取这些内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('普通软件账号未开通农场时显示管理员开通入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessionStore = _MemorySessionStore()..value = _personalSession();
    final notifier = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _MemoryOverrideStore(),
        compileTimeBaseUrl: 'http://127.0.0.1:27861',
      ),
      sessionStore: sessionStore,
      apiFactory: (_) => throw UnimplementedError(),
    );
    await notifier.ready;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appAuthProvider.overrideWith((ref) => notifier),
          farmOrganizationAccessProfileProvider.overrideWith(
            (ref) => throw const StudioCloudException(
              '尚未开通农场管理员身份',
              code: 'farm_workspace_not_registered',
              statusCode: 404,
            ),
          ),
          printerConnectionStoreProvider.overrideWithValue(
            _EmptyPrinterConnectionStore(),
          ),
          mergedPrinterListProvider.overrideWithValue(const []),
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: const MaterialApp(home: StudioFarmWorkspace()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('此账号尚未开通打印农场'), findsOneWidget);
    expect(find.text('开通管理员身份'), findsOneWidget);
    expect(find.textContaining('无需重新注册账号'), findsOneWidget);
    expect(find.text('退出并切换账号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

AppAuthSession _personalSession() {
  final now = DateTime.now().toUtc();
  return AppAuthSession(
    user: AppUser(
      id: 'software-user',
      email: 'softwaretest@sohun.local',
      handle: 'sohun-software-test',
      displayName: 'Sohun Test User',
      emailVerified: true,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: 'test-access-token',
    refreshToken: 'test-refresh-token',
    expiresAt: now.add(const Duration(hours: 1)),
    refreshExpiresAt: now.add(const Duration(days: 1)),
    serverBaseUrl: 'http://127.0.0.1:27861',
  );
}

class _MemorySessionStore implements AppAuthSessionStore {
  AppAuthSession? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<AppAuthSession?> read() async => value;

  @override
  Future<void> write(AppAuthSession session) async => value = session;
}

class _MemoryOverrideStore implements CommunityServerOverrideStore {
  String? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;
}

class _EmptyPrinterConnectionStore implements PrinterConnectionStore {
  @override
  Future<List<PrinterConnectionConfig>> read() async => const [];

  @override
  Future<void> write(List<PrinterConnectionConfig> connections) async {}
}
