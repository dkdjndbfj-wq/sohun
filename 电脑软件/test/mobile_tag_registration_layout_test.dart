import 'dart:async';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/features/color_picker/color_picker_panel.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_tag_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_writer_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_visual_theme.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = 'registration-layout|personal';
const _brandKey = ValueKey('mobile-registration-brand');
const _submitKey = ValueKey('mobile-registration-submit');
const _nfcKey = ValueKey('mobile-registration-nfc');

class _NfcSpy implements RfidNativeBridge, RfidTagReader {
  int availableChecks = 0;
  int enabledChecks = 0;
  int writes = 0;
  int reads = 0;
  int cancels = 0;
  Completer<bool>? availability;

  @override
  Future<bool> isAvailable() async {
    availableChecks++;
    return availability?.future ?? true;
  }

  @override
  Future<bool> isEnabled() async {
    enabledChecks++;
    return true;
  }

  @override
  Future<RfidWriteResult> write(MobileConsumableDraft draft) async {
    writes++;
    return const RfidWriteFailure('unexpected_write', '测试不允许写卡');
  }

  @override
  Future<RfidReadResult> read() async {
    reads++;
    return const RfidReadFailure('unexpected_read', '测试不允许读卡');
  }

  @override
  Future<void> cancel() async => cancels++;
}

class _InventorySpy implements MobileInventorySync {
  int saves = 0;

  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    saves++;
    return const MobileInventorySaveResult(inventoryUid: 'test-only');
  }
}

class _RegistrationHarness {
  _RegistrationHarness(this.nfc, this.sync, this.repository);

  final _NfcSpy nfc;
  final _InventorySpy sync;
  final MobileRfidTagRepository repository;

  Future<void> expectNoCardOrInventoryOperations() async {
    expect(nfc.writes, 0);
    expect(nfc.reads, 0);
    expect(sync.saves, 0);
    expect(await repository.list(ownerAccount: _owner), isEmpty);
    expect(
      await repository.listInventoryTagBindings(ownerAccount: _owner),
      isEmpty,
    );
  }

  void expectNoNfcChecks() {
    expect(nfc.availableChecks, 0);
    expect(nfc.enabledChecks, 0);
  }
}

Future<_RegistrationHarness> _mountRegistration(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  double keyboardInset = 0,
  Brightness brightness = Brightness.light,
  _NfcSpy? nfc,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final repository = MobileRfidTagRepository(database);
  final bridge = nfc ?? _NfcSpy();
  final sync = _InventorySpy();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    repository.dispose();
    await database.close();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: buildMobileTheme(
        brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          padding: const EdgeInsets.only(top: 24, bottom: 24),
          viewPadding: const EdgeInsets.only(top: 24, bottom: 24),
          viewInsets: EdgeInsets.only(bottom: keyboardInset),
        ),
        child: InteractionEffectsScope(enabled: false, child: child!),
      ),
      // Match the real mobile shell's available height without involving
      // authentication, network providers, real NFC or the user's database.
      home: MobileScaffold(
        body: MobileRfidWriterPage(
          pageTitle: '耗材标签登记',
          nfc: bridge,
          sync: sync,
          loadMaterials: () async => ['PLA', 'PETG HF'],
          ownerAccount: _owner,
          accountIdentity: _owner,
          tagRepository: repository,
          onAccountTap: (_) {},
        ),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: MobileGlassSurface(
            radius: 22,
            opacity: 0.64,
            elevated: true,
            child: NavigationBar(
              height: 64,
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.nfc_outlined),
                  label: '标签登记',
                ),
                NavigationDestination(
                  icon: Icon(Icons.inventory_2_outlined),
                  label: '耗材库存',
                ),
                NavigationDestination(
                  icon: Icon(Icons.notifications_none_rounded),
                  label: '打印提醒',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  label: '我的',
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _RegistrationHarness(bridge, sync, repository);
}

Future<void> _openColorPanel(WidgetTester tester) async {
  final color = find.descendant(
    of: find.byKey(const ValueKey('mobile-registration-form')),
    matching: find.byIcon(Icons.tune_rounded),
  );
  await tester.ensureVisible(color);
  await tester.tap(color);
  await tester.pumpAndSettle();
  expect(find.byType(Dialog), findsOneWidget);
  expect(
    tester.widget<ColorPickerPanel>(find.byType(ColorPickerPanel)).compact,
    isTrue,
  );
  expect(find.text('HEX（自动生成）'), findsNothing);
  expect(find.text('色相'), findsNothing);
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('390 宽 ${brightness.name} 登记首屏在底部导航上方显示完整主按钮', (tester) async {
      final harness = await _mountRegistration(tester, brightness: brightness);
      final submit = find.byKey(_submitKey);
      final scrollable = find
          .descendant(
            of: find.byType(MobileRfidWriterPage),
            matching: find.byType(Scrollable),
          )
          .first;

      expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
      expect(find.byTooltip('复用耗材模板').hitTestable(), findsOneWidget);
      expect(submit.hitTestable(), findsOneWidget);
      final buttonBounds = tester.getRect(submit);
      final navigationBounds = tester.getRect(find.byType(NavigationBar));
      expect(buttonBounds.top, greaterThanOrEqualTo(0));
      expect(buttonBounds.bottom, lessThanOrEqualTo(navigationBounds.top));
      expect(buttonBounds.height, greaterThanOrEqualTo(48));
      expect(
        find.byKey(const ValueKey('mobile-registration-template')),
        findsOneWidget,
      );
      expect(find.text('CUID / FUID'), findsOneWidget);
      expect(find.text('写入资料卡，登记当前卷'), findsNothing);
      harness.expectNoNfcChecks();
      await harness.expectNoCardOrInventoryOperations();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('登记说明默认隐藏，帮助开关保留品牌且不启动 NFC 或库存操作', (tester) async {
    final harness = await _mountRegistration(tester);
    await tester.enterText(find.byKey(_brandKey), '帮助测试品牌');
    expect(find.text('先选模板，再填耗材'), findsNothing);
    expect(find.textContaining('同一张资料卡可重复使用'), findsNothing);
    harness.expectNoNfcChecks();

    await tester.tap(find.byTooltip('登记帮助'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('先选模板，再填耗材'), findsOneWidget);
    expect(find.text('每次登记当前 1 卷'), findsOneWidget);
    expect(find.textContaining('AMS 识别仍需实机验证'), findsOneWidget);
    expect(find.textContaining('取消不增加库存'), findsOneWidget);
    harness.expectNoNfcChecks();
    await harness.expectNoCardOrInventoryOperations();

    await tester.ensureVisible(find.text('知道了'));
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('先选模板，再填耗材'), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(_brandKey)).controller!.text,
      '帮助测试品牌',
    );
    harness.expectNoNfcChecks();
    await harness.expectNoCardOrInventoryOperations();
    expect(tester.takeException(), isNull);
  });

  testWidgets('320 宽双倍字号及键盘下帮助可滚动关闭，主操作仍可到达', (tester) async {
    final harness = await _mountRegistration(
      tester,
      size: const Size(320, 640),
      textScale: 2,
      keyboardInset: 240,
    );
    await tester.ensureVisible(find.byKey(_brandKey));
    await tester.enterText(find.byKey(_brandKey), '小屏测试品牌');
    await tester.tap(find.byTooltip('登记帮助'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final helpScroll = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(Scrollable),
    );
    expect(helpScroll, findsOneWidget);
    expect(
      tester.state<ScrollableState>(helpScroll).position.maxScrollExtent,
      greaterThan(0),
    );
    await tester.scrollUntilVisible(
      find.text('知道了'),
      140,
      scrollable: helpScroll,
    );
    await tester.pumpAndSettle();
    expect(find.text('知道了').hitTestable(), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(_brandKey)).controller!.text,
      '小屏测试品牌',
    );

    await tester.ensureVisible(find.byKey(_submitKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_submitKey).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(_submitKey));
    await tester.pumpAndSettle();
    expect(find.text('请选择耗材型号'), findsOneWidget);
    harness.expectNoNfcChecks();
    await harness.expectNoCardOrInventoryOperations();
    expect(tester.takeException(), isNull);
  });

  testWidgets('紧凑颜色面板确认后回填，取消新颜色保留已选颜色与品牌', (tester) async {
    final harness = await _mountRegistration(tester);
    await tester.enterText(find.byKey(_brandKey), '色板测试品牌');
    await _openColorPanel(tester);
    await tester.tap(find.byTooltip('蓝'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.byType(ColorPickerPanel), findsNothing);
    expect(find.text('蓝'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(_brandKey)).controller!.text,
      '色板测试品牌',
    );

    await _openColorPanel(tester);
    final selected = tester.widget<ColorPickerPanel>(
      find.byType(ColorPickerPanel),
    );
    expect(selected.initial, const Color(0xFF1A73E8));
    expect(selected.initialName, '蓝');
    await tester.tap(find.byTooltip('红'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义调色'));
    await tester.pumpAndSettle();
    expect(find.text('色相'), findsOneWidget);
    expect(find.text('饱和度'), findsOneWidget);
    expect(find.text('明度'), findsOneWidget);
    await tester.ensureVisible(find.text('取消'));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('蓝'), findsOneWidget);
    expect(find.text('红'), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(_brandKey)).controller!.text,
      '色板测试品牌',
    );

    await _openColorPanel(tester);
    final unchanged = tester.widget<ColorPickerPanel>(
      find.byType(ColorPickerPanel),
    );
    expect(unchanged.initial, const Color(0xFF1A73E8));
    expect(unchanged.initialName, '蓝');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    harness.expectNoNfcChecks();
    await harness.expectNoCardOrInventoryOperations();
    expect(tester.takeException(), isNull);
  });

  testWidgets('首次进入不查询 NFC，显式检查才查询且检查中不能重复启动', (tester) async {
    final bridge = _NfcSpy()..availability = Completer<bool>();
    final harness = await _mountRegistration(tester, nfc: bridge);
    harness.expectNoNfcChecks();
    expect(find.text('检查 NFC'), findsOneWidget);
    await tester.tap(find.byKey(_nfcKey));
    await tester.pump();
    expect(bridge.availableChecks, 1);
    expect(bridge.enabledChecks, 0);
    expect(find.text('检查中…'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(_nfcKey)).onPressed, isNull);
    await tester.tap(find.byKey(_nfcKey));
    await tester.pump();
    expect(bridge.availableChecks, 1);

    bridge.availability!.complete(true);
    await tester.pumpAndSettle();
    expect(bridge.enabledChecks, 1);
    expect(find.text('NFC 已就绪'), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(_nfcKey)).onPressed, isNotNull);
    await harness.expectNoCardOrInventoryOperations();
    expect(tester.takeException(), isNull);
  });
}
