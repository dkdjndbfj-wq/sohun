import 'package:consumable_tracker_desktop/features/printers/add_printer_sheet.dart';
import 'package:consumable_tracker_desktop/features/printers/printers_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/desktop_walkthrough_support.dart';

const _captureEnabled = bool.fromEnvironment('SOHUN_DESKTOP_GUIDE_CAPTURE');

void main() {
  testWidgets(
    'desktop walkthrough 04 adds a custom printer through the real form',
    (tester) async {
      final guide = await DesktopWalkthrough.mount(
        tester,
        segment: '04-add-printer',
      );
      try {
        await guide.hold(10);
        await guide.click(
          find.byKey(const ValueKey('personal-nav-printers')),
          '侧栏 / 打印机',
          linger: 13,
        );
        expect(find.byType(PrintersScreen), findsOneWidget);
        await guide.click(find.text('添加打印机'), '设备列表 / 添加打印机');
        expect(find.byType(AddPrinterSheet), findsOneWidget);
        await guide.click(find.text('自定义'), '添加打印机 / 自定义', linger: 7);
        await guide.type(walkthroughField('品牌 *'), 'Creality', '品牌');
        await guide.type(walkthroughField('型号 *'), 'K1 Max', '型号');
        await guide.type(walkthroughField('打印机名称（可选）'), '工位 03', '打印机名称');
        expect(find.text('供料布局：1 个外挂料位'), findsOneWidget);
        await guide.hold(12);
        guide.mark('确认名称与单外挂供料布局');
        await guide.click(find.text('添加'), '添加打印机 / 保存', linger: 12);
        await guide.settle();
        final saved = await tester.runAsync(
          () => guide.db.select(guide.db.printers).get(),
        );
        expect(saved, hasLength(1));
        expect(saved!.single.name, '工位 03');
        expect(saved.single.brand, 'Creality');
        expect(saved.single.channelCount, 1);
        expect(find.byType(AddPrinterSheet), findsNothing);
        expect(find.text('工位 03'), findsWidgets);
        await guide.hold(24);
        guide.mark('新增打印机已出现在设备列表');
        await guide.finish(
          '添加打印机与自定义机型',
          extra: {
            'verifiedLocalResult': {
              'printerCount': saved.length,
              'name': saved.single.name,
              'brand': saved.single.brand,
              'model': saved.single.model,
              'physicalFeedPositions': saved.single.channelCount,
            },
            'hardwareBoundary':
                'This registers a local device record. It does not pair or connect a physical printer.',
          },
        );
      } finally {
        await guide.dispose();
      }
    },
    skip: !_captureEnabled,
    timeout: const Timeout(Duration(minutes: 12)),
  );

  testWidgets(
    'desktop walkthrough 05 chooses a preset and saves AMS feed positions',
    (tester) async {
      final guide = await DesktopWalkthrough.mount(
        tester,
        segment: '05-printer-config',
      );
      try {
        // The first recording already demonstrates the sidebar. Begin this
        // focused clip at the real device page, with setup recorded externally.
        await tester.tap(find.byKey(const ValueKey('personal-nav-printers')));
        await guide.settle();
        guide.preludeControls.add('personal-nav-printers');
        await guide.hold(10);
        await guide.click(find.text('添加打印机'), '设备列表 / 添加打印机');
        final presetList = find.descendant(
          of: find.byType(AddPrinterSheet),
          matching: find.byType(ListView),
        );
        for (
          var attempt = 0;
          find.text('P1S').hitTestable().evaluate().isEmpty && attempt < 8;
          attempt++
        ) {
          await guide.scroll(presetList, 280, linger: 3);
        }
        await guide.click(find.text('P1S'), '预设机型 / 拓竹 P1S', linger: 12);
        await guide.type(walkthroughField('打印机名称（可选）'), '多色工位 01', '打印机名称');
        await guide.click(find.text('1 组'), '多色系统 / 1 组 AMS', linger: 18);
        expect(find.text('供料布局：1 个外挂 + 4 个 AMS 料位'), findsOneWidget);
        guide.mark('1 个外挂与 4 个 AMS 料位');
        final bottomScroll = find.descendant(
          of: find.byType(AddPrinterSheet),
          matching: find.byType(SingleChildScrollView),
        );
        if (find.text('添加').hitTestable().evaluate().isEmpty) {
          await guide.scroll(bottomScroll, 220, linger: 10);
        }
        await guide.click(find.text('添加'), '添加打印机 / 保存供料配置', linger: 12);
        await guide.settle();
        final saved = await tester.runAsync(
          () => guide.db.select(guide.db.printers).get(),
        );
        final channels = await tester.runAsync(
          () => guide.db.select(guide.db.printerChannels).get(),
        );
        expect(saved, hasLength(1));
        expect(saved!.single.name, '多色工位 01');
        expect(saved.single.model, 'P1S');
        expect(saved.single.channelCount, 5);
        expect(channels, hasLength(5));
        expect(
          channels!.every((channel) => channel.consumableId == null),
          isTrue,
        );
        expect(find.byType(AddPrinterSheet), findsNothing);
        expect(find.text('多色工位 01'), findsWidgets);
        await guide.hold(26);
        guide.mark('设备列表中的外挂与 AMS 供料位');
        await guide.finish(
          '选择预设机型与配置 AMS',
          extra: {
            'verifiedLocalResult': {
              'printerCount': saved.length,
              'name': saved.single.name,
              'model': saved.single.model,
              'physicalFeedPositions': channels.length,
              'feedLabels': channels.map((channel) => channel.label).toList(),
            },
            'hardwareBoundary':
                'Saved local feed layout only. No physical AMS was connected and no material was loaded.',
          },
        );
      } finally {
        await guide.dispose();
      }
    },
    skip: !_captureEnabled,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
