import 'dart:io';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/core/theme/personal_desktop_theme.dart';
import 'package:consumable_tracker_desktop/features/color_picker/color_picker_panel.dart';
import 'package:consumable_tracker_desktop/features/rfid/desktop_rfid_bridge.dart';
import 'package:consumable_tracker_desktop/features/rfid/desktop_rfid_controller.dart';
import 'package:consumable_tracker_desktop/features/rfid/desktop_rfid_workbench.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ams_template_fixture.dart';
import 'support/desktop_rfid_fixture.dart';

void main() {
  late FakeDesktopSerial serial;
  late DesktopRfidBridge bridge;
  late DesktopRfidController c;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    serial = FakeDesktopSerial();
    bridge = DesktopRfidBridge(transport: serial);
    c = DesktopRfidController(
      bridge: bridge,
      sync: const NoopMobileInventorySync(),
      journal: MemoryRfidJournal(),
      owner: 'test',
      isCurrent: () => true,
    );
  });
  tearDown(() async {
    c.dispose();
    bridge.dispose();
    await serial.controller.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1280, 900),
    Brightness brightness = Brightness.light,
    double scale = 1,
    bool motion = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildPersonalDesktopTheme(
          brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
          personalProduct: true,
          studioMode: false,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: InteractionEffectsScope(enabled: motion, child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('库存')),
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Align(
                alignment: Alignment.topRight,
                child: FilledButton(
                  onPressed: () => openDesktopRfidWorkbench(
                    context,
                    workbenchBuilder: (_) => DesktopRfidWorkbench(
                      controller: c,
                      repository: MemoryDesktopTemplates(),
                      accountLabel: '离线演示账号',
                      templateOwner: 'test',
                    ),
                  ),
                  child: const Text('CUID / FUID 读写'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('CUID / FUID 读写'));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await bridge.disconnect();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  testWidgets(
    'inventory opens a bounded dialog and closing preserves its route',
    (tester) async {
      await mount(tester);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('库存'), findsOneWidget);
      final bounds = tester.getSize(
        find.byKey(const ValueKey('rfid-workbench-dialog')),
      );
      expect(bounds, const Size(840, 580));
      final dialogRect = tester.getRect(find.byType(DesktopRfidWorkbench));
      expect(dialogRect.center, const Offset(640, 450));
      expect(
        dialogRect.contains(
          tester.getBottomRight(find.byType(CheckboxListTile)),
        ),
        isTrue,
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.byTooltip('关闭工作台'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopRfidWorkbench), findsNothing);
      expect(find.text('库存'), findsOneWidget);
      expect(find.text('CUID / FUID 读写'), findsOneWidget);
      expect(serial.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets('opening discovers candidate but does not connect or write', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('标签工作台'), findsOneWidget);
    expect(find.text('USB-SERIAL CH340 (COM7)'), findsOneWidget);
    expect(serial.openCount, 0);
    expect(serial.requests, isEmpty);
    expect(find.byType(BackdropFilter), findsWidgets);
    await tester.tap(find.text('连接套件'));
    await tester.pumpAndSettle();
    expect(bridge.readerReady, true);
    expect(serial.requests.map((r) => r['cmd']), ['hello']);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  testWidgets(
    'amount mode uses fixed full rolls or one remaining spool, never arbitrary net weight',
    (tester) async {
      await mount(tester);
      expect(find.text('每卷净重（g）'), findsNothing);
      expect(find.text('卷数'), findsOneWidget);
      await tester.tap(find.text('按余量'));
      await tester.pumpAndSettle();
      expect(find.text('余量（g）'), findsOneWidget);
      await tester.tap(find.text('按卷数'));
      await tester.pumpAndSettle();
      expect(find.text('卷数'), findsOneWidget);
      expect(find.text('余量（g）'), findsNothing);
      expect(serial.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );
  testWidgets('main view keeps technical detail out of the daily workflow', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('颜色 HEX'), findsNothing);
    expect(find.textContaining('115200'), findsNothing);
    expect(find.textContaining('模板与密钥'), findsNothing);
    expect(find.textContaining('相同 UID'), findsNothing);
    expect(find.byType(TextField), findsNWidgets(3));
    await tester.tap(find.text('帮助'));
    await tester.pumpAndSettle();
    expect(find.textContaining('115200'), findsOneWidget);
    await finish(tester);
  });

  testWidgets(
    'color panel chooses a swatch and cancel preserves the last choice',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('rfid-color-picker')));
      await tester.pumpAndSettle();
      expect(find.text('选择颜色'), findsOneWidget);
      expect(find.text('明度'), findsNothing);
      expect(find.widgetWithText(TextField, 'HEX（自动生成）'), findsNothing);
      final colorPanel = tester.getSize(find.byType(ColorPickerPanel));
      expect(colorPanel.width, lessThanOrEqualTo(380));
      expect(colorPanel.height, lessThanOrEqualTo(360));
      await tester.tap(find.text('自定义调色'));
      await tester.pumpAndSettle();
      expect(find.text('明度'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('蓝'));
      await tester.tap(find.byTooltip('蓝'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('确认'));
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      BoxDecoration swatch() =>
          tester
                  .widget<Container>(
                    find.byKey(const ValueKey('rfid-selected-color')),
                  )
                  .decoration!
              as BoxDecoration;
      expect(swatch().color, const Color(0xFF1A73E8));
      expect(find.text('蓝'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rfid-color-picker')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('红'));
      await tester.tap(find.byTooltip('红'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('取消'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(swatch().color, const Color(0xFF1A73E8));
      expect(serial.requests, isEmpty);
      await tester.tap(find.text('连接套件'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '品牌'), 'eSUN');
      await tester.enterText(find.widgetWithText(TextField, '型号 / 材料'), 'PLA');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('读取标签'));
      await tester.pumpAndSettle();
      expect(c.items.single.draft.color, const Color(0xFF1A73E8));
      expect(c.items.single.draft.colorName, '蓝');
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  testWidgets('help has exact SPI wiring and does not operate hardware', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('帮助'));
    await tester.pumpAndSettle();
    expect(find.text('GPIO27 / D27'), findsOneWidget);
    expect(find.text('3V3（不能接 VIN / 5V）'), findsOneWidget);
    expect(serial.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  testWidgets('waiting has an accessible cancel control that ends link', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('连接套件'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '品牌'), 'eSUN');
    await tester.enterText(find.widgetWithText(TextField, '型号 / 材料'), 'PLA');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    serial.autoReply = false;
    await tester.tap(find.text('读取标签'));
    await tester.pump();
    expect(find.text('等待标签，请保持贴近'), findsOneWidget);
    await tester.tap(find.text('取消操作'));
    await tester.pumpAndSettle();
    expect(bridge.connected, false);
    expect(c.items, isEmpty);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });
  testWidgets('读取资料卡后移除待办不会触发入库', (tester) async {
    await mount(tester);
    await tester.tap(find.text('连接套件'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '品牌'), 'eSUN');
    await tester.enterText(find.widgetWithText(TextField, '型号 / 材料'), 'PLA');
    await tester.enterText(find.widgetWithText(TextField, '卷数'), '3');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('读取标签'));
    await tester.pumpAndSettle();
    expect(c.pendingCount, 1);
    expect(c.items.single.quantity, 3);
    expect(find.text('入库 3 卷'), findsOneWidget);
    expect(find.textContaining(c.items.single.uid), findsNothing);
    await tester.tap(find.text('eSUN PLA'));
    await tester.pumpAndSettle();
    expect(find.textContaining(c.items.single.uid), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('取消此条，不增加库存'));
    await tester.pumpAndSettle();
    expect(c.items, isEmpty);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('large batches scroll inside the compact queue, not the dialog', (
    tester,
  ) async {
    await mount(tester);
    await bridge.connect('COM7');
    await tester.pumpAndSettle();
    final readPosition = tester.getTopLeft(find.text('读取标签'));
    for (var i = 0; i < 12; i++) {
      serial.uid = 'D021B7${i.toRadixString(16).padLeft(2, '0')}';
      await c.enqueueScan(
        draft: MobileConsumableDraft(
          brand: 'SUNLU',
          model: 'PLA $i',
          color: const Color(0xFF23A66B),
          colorName: '绿色',
        ),
        grams: 1000,
        kind: 'cuid',
        typeConfirmed: true,
        mode: RfidReceiptMode.stock,
        quantity: 1,
      );
    }
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('rfid-workbench-dialog'))),
      const Size(840, 580),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('rfid-queue-list'))).height,
      224,
    );
    expect(find.text('入库 12 卷'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('SUNLU PLA 11'), findsOneWidget);
    expect(tester.getTopLeft(find.text('读取标签')), readPosition);
    c.selectTemplate(syntheticAmsTemplate());
    await c.scanTarget();
    await tester.tap(find.text('模板写卡'));
    await tester.pumpAndSettle();
    final writeQueue = tester.getRect(
      find.byKey(const ValueKey('rfid-queue-card')),
    );
    final workbench = tester.getRect(find.byType(DesktopRfidWorkbench));
    expect(writeQueue.bottom, lessThan(workbench.bottom));
    expect(
      tester.getSize(find.byKey(const ValueKey('rfid-queue-list'))).height,
      176,
    );
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets(
    'closing an active operation asks before leaving inventory dialog',
    (tester) async {
      await mount(tester, motion: true);
      await tester.tap(find.text('连接套件'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '品牌'), 'eSUN');
      await tester.enterText(find.widgetWithText(TextField, '型号 / 材料'), 'PLA');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      serial.autoReply = false;
      await tester.tap(find.text('读取标签'));
      await tester.pump();
      await tester.tap(find.byTooltip('关闭工作台'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('结束当前读写？'), findsOneWidget);
      await tester.tap(find.text('继续当前操作'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(bridge.busy, isTrue);
      expect(find.byType(DesktopRfidWorkbench), findsOneWidget);
      await tester.tap(find.byTooltip('关闭工作台'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('结束并关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopRfidWorkbench), findsNothing);
      expect(find.text('库存'), findsOneWidget);
      expect(bridge.connected, isFalse);
      expect(c.items, isEmpty);
      expect(tester.takeException(), isNull);
      await finish(tester);
    },
  );

  for (final item in [
    (const Size(800, 600), 1.0),
    (const Size(980, 720), 1.0),
    (const Size(720, 900), 1.5),
    (const Size(1024, 800), 2.0),
  ]) {
    testWidgets('compact responsive layout ${item.$1} scale ${item.$2}', (
      tester,
    ) async {
      await mount(tester, size: item.$1, scale: item.$2);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('模板写卡'));
      await tester.tap(find.text('模板写卡'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'capture desktop RFID workbench ${brightness.name}',
      (tester) async {
        await tester.runAsync(() async {
          final regular = await File(
            r'C:\Windows\Fonts\msyh.ttc',
          ).readAsBytes();
          final bold = await File(r'C:\Windows\Fonts\msyhbd.ttc').readAsBytes();
          for (final family in [
            'HarmonyOS Sans',
            'Microsoft YaHei UI',
            'Roboto',
            'Ahem',
          ]) {
            await (FontLoader(family)
                  ..addFont(Future.value(ByteData.sublistView(regular)))
                  ..addFont(Future.value(ByteData.sublistView(bold))))
                .load();
          }
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
        debugDisableShadows = false;
        addTearDown(() => debugDisableShadows = true);
        await mount(tester, brightness: brightness);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '../build/rfid-kit-ui/disconnected-${brightness.name}.png',
          ),
        );
        await bridge.connect('COM7');
        await tester.enterText(find.widgetWithText(TextField, '品牌'), 'SUNLU');
        await tester.enterText(
          find.widgetWithText(TextField, '型号 / 材料'),
          'PLA Matte',
        );
        await tester.tap(find.byType(CheckboxListTile));
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        for (var i = 0; i < 4; i++) {
          serial.uid = 'D021B75${i + 1}';
          await c.enqueueScan(
            draft: MobileConsumableDraft(
              brand: i < 2 ? 'SUNLU' : 'eSUN',
              model: i < 2 ? 'PLA Matte' : 'PETG',
              color: [
                const Color(0xFF23A66B),
                const Color(0xFF445B91),
                const Color(0xFFFFC96B),
                const Color(0xFFDE928F),
              ][i],
              colorName: '演示颜色',
            ),
            grams: 1000,
            kind: 'cuid',
            typeConfirmed: true,
            mode: RfidReceiptMode.stock,
            quantity: i < 2 ? 2 : 1,
          );
        }
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '../build/rfid-kit-ui/batch-${brightness.name}.png',
          ),
        );
        c.selectTemplate(syntheticAmsTemplate());
        await c.scanTarget();
        await tester.tap(find.text('模板写卡'));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '../build/rfid-kit-ui/write-${brightness.name}.png',
          ),
        );
        await tester.tap(find.byKey(const ValueKey('rfid-color-picker')));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '../build/rfid-kit-ui/color-picker-${brightness.name}.png',
          ),
        );
        await tester.ensureVisible(find.text('取消'));
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await finish(tester);
        debugDisableShadows = true;
      },
      skip: !const bool.fromEnvironment('CAPTURE_RFID_UI'),
    );
  }
}
