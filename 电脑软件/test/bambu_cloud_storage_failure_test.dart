import 'dart:io';

import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_cloud_session_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('consumable_tracker/security');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('凭据保护失败只报告一次，释放写锁后下一次保存可成功', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    await expectLater(
      BambuCloudSessionStore.setActiveAccount(
        'test@example.com',
        BambuRegion.china,
      ),
      throwsA(isA<PlatformException>()),
    );
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    // Reversible stand-in for DPAPI: this test verifies error/lock handling,
    // while the native implementation remains responsible for encryption.
    messenger.setMockMethodCallHandler(channel, (call) async => call.arguments);
    await BambuCloudSessionStore.setActiveAccount(
      'test@example.com',
      BambuRegion.china,
    );
    expect(
      await BambuCloudSessionStore.loadActiveAccountKey(),
      'test@example.com|China',
    );
  }, skip: !Platform.isWindows);
}
