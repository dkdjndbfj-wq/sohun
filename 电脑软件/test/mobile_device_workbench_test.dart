import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:consumable_tracker_desktop/core/services/app_update_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/device_workbench_store.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_device.dart';
import 'package:consumable_tracker_desktop/mobile/device_tag_nfc.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_device_workbench.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_account_app.dart';
import 'package:consumable_tracker_desktop/providers/app_auth_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/device_workbench_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/device_workbench_fixture.dart';

const _captureKey = ValueKey('device-workbench-capture');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (await font.exists()) {
      final data = ByteData.sublistView(await font.readAsBytes());
      for (final family in ['Roboto', 'Microsoft YaHei UI', 'DeviceUiTest']) {
        await (FontLoader(family)..addFont(Future.value(data))).load();
      }
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  _deviceTest('扫描设备标签解析并打开工作台，耗材库存保持空白', (tester) async {
    final app = await _mount(tester);
    await tester.tap(find.text('扫描 NTAG213 设备标签'));
    await _until(tester, () => find.text('模型 A').evaluate().isNotEmpty);
    expect(app.nfc.reads, 1);
    expect(app.api.resolves, 1);
    expect(find.text('进度 42%'), findsOneWidget);
    expect(find.text('剩余 18 分钟'), findsOneWidget);
    expect(find.text('制作设备标签'), findsOneWidget);
    expect(
      await tester.runAsync(() => app.db.select(app.db.consumables).get()),
      isEmpty,
    );
    expect(await _tagRows(tester, app), isEmpty);
    expect(tester.takeException(), isNull);
  });

  _deviceTest('写卡只发送设备 token，完成回读前不登记，成功后记独立设备日志', (tester) async {
    final nfc = DeviceTestNfc()
      ..pendingWrite = Completer<DeviceTagWriteResult>();
    final app = await _mount(tester, nfc: nfc);
    await _selectDevice(tester);
    await _startWrite(tester, app);
    expect(nfc.writtenToken, deviceTestToken);
    expect(await _tagRows(tester, app), isEmpty);
    nfc.pendingWrite!.complete(_written());
    await _until(
      tester,
      () => find.textContaining('设备标签已写入并校验').evaluate().isNotEmpty,
    );
    final rows = await _tagRows(tester, app);
    expect(rows, hasLength(1));
    expect(rows.single['account_key'], deviceTestOwner);
    expect(rows.single['printer_key'], deviceTestKey);
    expect(rows.single['device_token'], deviceTestToken);
    expect(rows.single['tag_uid'], '04AABBCCDDEEFF');
    expect(
      await tester.runAsync(() => app.db.select(app.db.consumables).get()),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  _deviceTest('取消写卡后即使原生迟到返回成功，也不登记设备标签', (tester) async {
    final nfc = DeviceTestNfc()
      ..pendingWrite = Completer<DeviceTagWriteResult>();
    final app = await _mount(tester, nfc: nfc);
    await _selectDevice(tester);
    await _startWrite(tester, app);
    await tester.tap(find.text('取消设备标签操作'));
    await _flush(tester);
    nfc.pendingWrite!.complete(_written());
    await _flush(tester);
    expect(nfc.cancels, greaterThan(0));
    expect(await _tagRows(tester, app), isEmpty);
    expect(find.textContaining('设备标签已写入并校验'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _deviceTest('切换账号使正在写卡的迟到结果失效，不记到任一账号', (tester) async {
    final nfc = DeviceTestNfc()
      ..pendingWrite = Completer<DeviceTagWriteResult>();
    final app = await _mount(tester, nfc: nfc);
    await _selectDevice(tester);
    await _startWrite(tester, app);
    app.api.devices = [];
    app.auth.switchAccount(deviceSession(id: 'bob'));
    await _until(
      tester,
      () =>
          app.container
              .read(deviceWorkbenchProvider)
              .owner
              ?.contains('|bob|') ==
          true,
    );
    nfc.pendingWrite!.complete(_written());
    await _flush(tester);
    expect(await _tagRows(tester, app), isEmpty);
    expect(find.text('模型 A'), findsNothing);
    expect(find.textContaining('设备标签已写入并校验'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  _deviceTest('标签丢失或未完成校验不会生成制作成功日志', (tester) async {
    final nfc = DeviceTestNfc()
      ..pendingWrite = Completer<DeviceTagWriteResult>();
    final app = await _mount(tester, nfc: nfc);
    await _selectDevice(tester);
    await _startWrite(tester, app);
    nfc.pendingWrite!.complete(
      const DeviceTagWriteFailure('TAG_LOST', '标签已移开，请重试'),
    );
    await _until(
      tester,
      () => find.textContaining('标签已移开').evaluate().isNotEmpty,
    );
    expect(await _tagRows(tester, app), isEmpty);
    expect(tester.takeException(), isNull);
  });

  _deviceTest('保养表单离线保存待同步，联网重试不重复并展示到期提醒', (tester) async {
    final now = DateTime.now();
    final api = _UiDeviceApi()
      ..remote = [
        DeviceMaintenanceRecord(
          eventId: 'due-cleaning',
          printerKey: deviceTestKey,
          kind: 'cleaning',
          notes: '上次清洁',
          performedAt: now.subtract(const Duration(days: 30)),
          nextDueAt: now.subtract(const Duration(days: 1)),
        ),
      ];
    final app = await _mount(tester, api: api);
    expect(find.textContaining('有维护项目到期'), findsOneWidget);
    await _selectDevice(tester);
    await _ensureVisible(tester, find.text('记录保养 / 巡检'));
    await tester.tap(find.text('记录保养 / 巡检'));
    await tester.pumpAndSettle();
    expect(find.text('记录工作台 02的维护'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '检查完成，运行正常');
    api.offline = true;
    await tester.tap(find.text('保存维护记录'));
    await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
    await _until(
      tester,
      () => app.container
          .read(deviceWorkbenchProvider)
          .records
          .any((r) => r.pending),
    );
    await _ensureVisible(tester, find.textContaining('待同步').last);
    expect(find.textContaining('待同步'), findsWidgets);
    expect(find.text('检查完成，运行正常'), findsOneWidget);
    final pending = await tester.runAsync(
      () => DeviceWorkbenchStore(
        app.db,
      ).maintenance(deviceTestOwner, pendingOnly: true),
    );
    expect(pending, hasLength(1));
    expect(pending!.single.notes, '检查完成，运行正常');
    expect(api.saved, isEmpty);
    api.offline = false;
    await tester.tap(find.byTooltip('刷新设备'));
    await _until(
      tester,
      () =>
          !app.container.read(deviceWorkbenchProvider).busy &&
          api.saved.isNotEmpty,
    );
    expect(api.saved.keys, [pending.single.eventId]);
    expect(
      app.container
          .read(deviceWorkbenchProvider)
          .records
          .where((r) => r.pending),
      isEmpty,
    );
    await _ensureVisible(tester, find.textContaining('清洁已到期'));
    expect(find.textContaining('清洁已到期'), findsOneWidget);
    expect(
      await tester.runAsync(() => app.db.select(app.db.consumables).get()),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  _deviceTest('冷启动设备 URI 登录前保留，真实登录表单成功后回到对应设备', (tester) async {
    final nfc = DeviceTestNfc()
      ..pendingUri = 'https://sohun.top/device/$deviceTestToken';
    final app = await _mount(
      tester,
      nfc: nfc,
      signedOut: true,
      accountApp: true,
    );
    await _until(
      tester,
      () => find.byType(MobileDeviceWorkbenchPage).evaluate().isNotEmpty,
    );
    expect(app.container.read(deviceTagOpenRequestProvider), deviceTestToken);
    expect(app.api.resolves, 0);
    await _loginFromDevice(tester, app);
    await _until(
      tester,
      () => find.text('模型 A').hitTestable().evaluate().isNotEmpty,
    );
    expect(app.api.logins, 1);
    expect(find.text('工作台 02').hitTestable(), findsOneWidget);
    expect(app.api.resolves, greaterThan(0));
    expect(
      await tester.runAsync(() => app.db.select(app.db.consumables).get()),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  _deviceTest('冷启动标签登录后被拒绝时不展示设备详情或写卡入口', (tester) async {
    final nfc = DeviceTestNfc()
      ..pendingUri = 'https://sohun.top/device/$deviceTestToken';
    final api = _UiDeviceApi()
      ..devices = []
      ..denied = true;
    final app = await _mount(
      tester,
      api: api,
      nfc: nfc,
      signedOut: true,
      accountApp: true,
    );
    await _until(
      tester,
      () => find.byType(MobileDeviceWorkbenchPage).evaluate().isNotEmpty,
    );
    await _loginFromDevice(tester, app);
    await _until(
      tester,
      () => find.textContaining('当前账号无权查看').hitTestable().evaluate().isNotEmpty,
    );
    expect(find.text('模型 A'), findsNothing);
    expect(find.text('制作设备标签'), findsNothing);
    expect(await _tagRows(tester, app), isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final action in [
    (label: '摄像头设置', open: '设置可用的摄像头入口', confirm: '保存'),
    (label: '停止设备共享', open: '停止设备共享', confirm: '确认'),
    (label: '轮换设备标签', open: '使旧设备标签失效', confirm: '更新标签标识'),
  ]) {
    _deviceTest('${action.label}确认期间切账号，不修改新账号同键设备', (tester) async {
      final app = await _mount(tester);
      await _selectDevice(tester);
      await _ensureVisible(tester, find.text(action.open));
      await tester.tap(find.text(action.open));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      if (action.label == '摄像头设置') {
        await tester.enterText(
          find.byType(TextField),
          'https://camera.example/alice-only',
        );
      }
      // Bob owns a different device with the same stable printer key. An old
      // dialog must not send its changes using Bob's newly active session.
      const bobDeviceToken = 'fedcba9876543210fedcba9876543210';
      app.api.devices = [deviceFixture(token: bobDeviceToken)];
      app.auth.switchAccount(deviceSession(id: 'bob'));
      await _until(tester, () {
        final current = app.container.read(deviceWorkbenchProvider);
        return current.owner?.contains('|bob|') == true &&
            !current.busy &&
            current.devices.any(
              (d) =>
                  d.printerKey == deviceTestKey &&
                  d.deviceToken == bobDeviceToken,
            );
      });
      await tester.tap(find.widgetWithText(FilledButton, action.confirm));
      await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
      await _flush(tester);
      expect(app.api.updateCalls, 0);
      expect(app.api.rotationCalls, 0);
      expect(app.api.devices.single.cameraUrl, isNull);
      expect(app.api.devices.single.archived, isFalse);
      expect(app.api.devices.single.deviceToken, bobDeviceToken);
      expect(find.textContaining('账号已切换，请重新打开设备'), findsOneWidget);
      expect(await _tagRows(tester, app), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  _deviceTest('320x640 双倍字号的设备列表、详情和维护弹窗没有溢出', (tester) async {
    final app = await _mount(tester, size: const Size(320, 640), textScale: 2);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'device-list-320-2x');
    await _ensureVisible(tester, find.text('工作台 02'));
    await tester.tap(find.text('工作台 02'));
    await _flush(tester);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'device-details-320-2x');
    await _ensureVisible(tester, find.text('记录保养 / 巡检'));
    await tester.tap(find.text('记录保养 / 巡检'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _capture(tester, 'device-maintenance-320-2x');
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(await _tagRows(tester, app), isEmpty);
  });
}

class _UiDeviceApi extends DeviceTestApi {
  int logins = 0, updateCalls = 0, rotationCalls = 0;
  @override
  Future<AppAuthSession> login(AppLoginRequest request) async {
    logins++;
    return deviceSession();
  }

  @override
  Future<PersonalDevice> updateDevice({
    required String accessToken,
    required String printerKey,
    required Map<String, dynamic> changes,
  }) async {
    updateCalls++;
    return super.updateDevice(
      accessToken: accessToken,
      printerKey: printerKey,
      changes: changes,
    );
  }

  @override
  Future<PersonalDevice> rotateDeviceTag({
    required String accessToken,
    required String printerKey,
  }) async {
    rotationCalls++;
    return super.rotateDeviceTag(
      accessToken: accessToken,
      printerKey: printerKey,
    );
  }
}

class _NoUpdates extends StateNotifier<AppUpdateState>
    implements AppUpdateService {
  _NoUpdates()
    : super(
        const AppUpdateState(
          phase: AppUpdatePhase.upToDate,
          mandatoryPolicyResolved: true,
        ),
      );
  @override
  Future<AppUpdateState> checkForUpdates() async => state;
  @override
  Future<bool> openDownloadPage({Uri? verifiedDownloadUri}) async => false;
}

class _UiFixture {
  _UiFixture(this.db, this.api, this.nfc, this.auth, this.container);
  final AppDatabase db;
  final _UiDeviceApi api;
  final DeviceTestNfc nfc;
  final DeviceTestAuth auth;
  final ProviderContainer container;
  ProviderSubscription<DeviceWorkbenchState>? subscription;
}

_UiFixture? _activeUi;

void _deviceTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      final app = _activeUi;
      _activeUi = null;
      if (app != null) {
        try {
          final write = app.nfc.pendingWrite;
          if (write != null && !write.isCompleted) {
            write.complete(
              const DeviceTagWriteFailure('OPERATION_CANCELLED', '测试结束'),
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        } finally {
          app.subscription?.close();
          app.container.dispose();
          // Riverpod's last-listener removal schedules a zero-delay disposal
          // task even when the container is then disposed synchronously.
          await tester.pump(const Duration(milliseconds: 1));
          await tester.runAsync(() async {
            await app.db.close();
            await app.nfc.dispose();
          });
        }
      }
    }
  });
}

Future<_UiFixture> _mount(
  WidgetTester tester, {
  _UiDeviceApi? api,
  DeviceTestNfc? nfc,
  bool signedOut = false,
  bool accountApp = false,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final service = api ?? _UiDeviceApi();
  final bridge = nfc ?? DeviceTestNfc();
  final app = (await tester.runAsync(() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    final auth = DeviceTestAuth(service, signedOut: signedOut);
    await auth.ready;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appAuthProvider.overrideWith((ref) => auth),
        communityApiProvider.overrideWithValue(service),
        deviceTagNfcProvider.overrideWithValue(bridge),
        appUpdateServiceProvider.overrideWith((ref) => _NoUpdates()),
      ],
    );
    return _UiFixture(db, service, bridge, auth, container);
  }))!;
  _activeUi = app;
  app.subscription = app.container.listen(deviceWorkbenchProvider, (_, __) {});
  final child = accountApp
      ? MobileRfidAccountApp(
          interactionEffectsEnabled: false,
          loadMaterials: () async => const [],
        )
      : MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh', 'CN')],
          theme: ThemeData(useMaterial3: true, fontFamily: 'DeviceUiTest'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: MobileDeviceWorkbenchPage(onAccountTap: () {}),
        );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: app.container,
      child: RepaintBoundary(key: _captureKey, child: child),
    ),
  );
  if (!signedOut) {
    await _until(
      tester,
      () => app.container.read(deviceWorkbenchProvider).refreshedAt != null,
    );
  }
  await _flush(tester);
  return app;
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(done(), isTrue, reason: '设备工作台界面没有到达预期状态');
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _selectDevice(WidgetTester tester) async {
  await _ensureVisible(tester, find.text('工作台 02'));
  await tester.tap(find.text('工作台 02'));
  await _flush(tester);
  expect(find.text('模型 A'), findsOneWidget);
}

Future<void> _ensureVisible(WidgetTester tester, Finder target) async {
  final scrollable = find
      .descendant(
        of: find.byType(MobileDeviceWorkbenchPage),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    target,
    180,
    scrollable: scrollable,
    maxScrolls: 30,
  );
  await tester.pump();
}

Future<void> _startWrite(WidgetTester tester, _UiFixture app) async {
  await _ensureVisible(tester, find.text('制作设备标签'));
  await tester.tap(find.text('制作设备标签'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认并写入'));
  await _until(tester, () => app.nfc.writes == 1);
}

DeviceTagWriteSuccess _written() => const DeviceTagWriteSuccess(
  deviceToken: deviceTestToken,
  uri: 'https://sohun.top/device/$deviceTestToken',
  tagId: '04AABBCCDDEEFF',
  verified: true,
  bytesWritten: 102,
);

Future<List<Map<String, Object?>>> _tagRows(
  WidgetTester tester,
  _UiFixture app,
) async => (await tester.runAsync(
  () async =>
      (await app.db.customSelect('SELECT * FROM device_tag_operations').get())
          .map((r) => r.data)
          .toList(),
))!;

Future<void> _loginFromDevice(WidgetTester tester, _UiFixture app) async {
  await tester.tap(find.widgetWithText(FilledButton, '登录 sohun'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('mobile-auth-email')),
    'alice@example.com',
  );
  await tester.enterText(
    find.byKey(const ValueKey('mobile-auth-password')),
    'StrongPass123',
  );
  await tester.ensureVisible(find.byKey(const ValueKey('mobile-auth-submit')));
  await tester.tap(find.byKey(const ValueKey('mobile-auth-submit')));
  await _until(
    tester,
    () =>
        app.api.logins == 1 && app.auth.state.status == AppAuthStatus.signedIn,
  );
  await _flush(tester);
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final target = File('build/device-workbench/$name.png');
    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
