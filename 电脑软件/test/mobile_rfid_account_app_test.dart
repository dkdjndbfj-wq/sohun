import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/community/app_auth_session_store.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/prefs/community_server_settings.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_account_app.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('隐藏 NFC 工具可打开返回，浏览页面不检测 NFC', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final auth = AppAuthNotifier(
      serverSettings: CommunityServerSettings(
        store: _EmptyOverrideStore(),
        compileTimeBaseUrl: '',
      ),
      sessionStore: _EmptySessionStore(),
      apiFactory: (_) => throw UnimplementedError(),
    );
    await auth.ready;
    final nfcCalls = <String>[];
    const channel = MethodChannel('top.sohun/consumable_rfid');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      nfcCalls.add(call.method);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          appAuthProvider.overrideWith((ref) => auth),
          communityApiProvider.overrideWithValue(null),
        ],
        child: const MobileRfidAccountApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('登录 sohun').first);
    await tester.pumpAndSettle();
    expect(find.text('NFC 标签工具'), findsNothing);
    expect(nfcCalls, isEmpty);
    expect(find.text('我的').hitTestable(), findsWidgets);
    await tester.tap(find.byType(NavigationDestination).first);
    await tester.pumpAndSettle();
    expect(find.text('耗材标签登记'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(nfcCalls.where((method) => method != 'cancelScan'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
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
