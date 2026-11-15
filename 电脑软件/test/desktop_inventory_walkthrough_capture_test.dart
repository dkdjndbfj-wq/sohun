import 'package:consumable_tracker_desktop/core/constants/personal_spool_policy.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/printer_feed_models.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/features/inventory/add_consumable_sheet.dart';
import 'package:consumable_tracker_desktop/features/printers/channel_slot.dart';
import 'package:consumable_tracker_desktop/providers/material_catalog_provider.dart';
import 'package:consumable_tracker_desktop/widgets/app_button.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/desktop_walkthrough_support.dart';

const _capture = bool.fromEnvironment('SOHUN_DESKTOP_GUIDE_CAPTURE');

/// Every receipt is a separate physical 1 kg spool in the disposable database.
/// No real stock, account, device or print task participates in these clips.
class _InventoryScene {
  int? printerId;
  int? channelId;
  late int oldSpoolId;
  late int newSpoolId;

  Future<void> seed(
    AppDatabase db, {
    bool printer = false,
    bool loaded = false,
  }) async {
    final now = DateTime.now();
    final ids = <int>[];
    const entries = [
      ('eSUN', 'PLA', '象牙白', '#E8E6DF', 620.0),
      ('eSUN', 'PLA', '雾蓝', '#4F83B8', 1000.0),
      ('Polymaker', 'PETG', '鼠尾草绿', '#84AC92', 860.0),
      ('Bambu Lab', 'PLA Basic', '曜石黑', '#343D43', 920.0),
    ];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final receipt = await db.consumableDao.addPersonalStockManual(
        operationUid: '59bca611-1115-4f62-a23e-00000000000${index + 1}',
        template: PersonalInventoryRecord(
          uid: 'stock-template-${index + 1}',
          manufacturer: entry.$1,
          model: entry.$2,
          materialType: entry.$2.startsWith('PLA') ? 'PLA' : 'PETG',
          colorName: entry.$3,
          colorHex: entry.$4,
          totalGrams: personalSpoolCapacityGrams,
          remainingGrams: entry.$5,
          createdAt: now.subtract(Duration(days: 5 - index)),
          updatedAt: now,
        ),
        quantity: 1,
      );
      ids.add(receipt.consumableIds.single);
    }
    oldSpoolId = ids[0];
    newSpoolId = ids[1];
    if (!printer) return;
    printerId = await db
        .into(db.printers)
        .insert(
          PrintersCompanion.insert(
            brand: '创想三维',
            model: 'K1 Max',
            name: const Value('创作工作台 · K1 Max'),
            channelCount: const Value(1),
          ),
        );
    channelId = await db
        .into(db.printerChannels)
        .insert(
          PrinterChannelsCompanion.insert(
            printerId: printerId!,
            channelIndex: externalFeedRightChannel,
            label: const Value('外挂料位'),
          ),
        );
    if (loaded) await db.printerDao.bindConsumable(channelId!, oldSpoolId);
  }
}

Finder _formScroll() => find.descendant(
  of: find.byType(AddConsumableSheet),
  matching: find.byType(SingleChildScrollView),
);

Future<void> _reveal(DesktopWalkthrough guide, Finder target) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    if (target.hitTestable().evaluate().isNotEmpty) return;
    await guide.scroll(_formScroll(), 220, linger: 3);
  }
  expect(target.hitTestable(), findsOneWidget);
}

Finder _channelSpool(String visibleTitle) => find.descendant(
  of: find.byType(ChannelSlot),
  matching: find.text(visibleTitle),
);

void main() {
  testWidgets(
    'desktop usage 06 add individual material rolls',
    (tester) async {
      final scene = _InventoryScene();
      final guide = await DesktopWalkthrough.mount(
        tester,
        segment: '06-add-material',
        seed: scene.seed,
        overrides: [
          materialCatalogProvider.overrideWith((_) async => ['PLA', 'PETG']),
        ],
      );
      try {
        await guide.hold(10);
        await guide.click(
          find.byKey(const ValueKey('personal-nav-inventory')),
          '侧栏 / 库存',
          linger: 12,
        );
        await guide.settle();
        await guide.click(
          find.widgetWithText(AppButton, '新增耗材'),
          '库存 / 新增耗材',
          linger: 12,
        );
        await guide.type(walkthroughField('厂商 *'), 'Polymaker', '耗材厂商');
        await guide.click(
          find.byWidgetPredicate(
            (widget) =>
                widget is InputDecorator && widget.decoration.labelText == '颜色',
          ),
          '耗材颜色',
          linger: 8,
        );
        await guide.click(find.byTooltip('蓝'), '选择蓝色', linger: 5);
        await guide.type(walkthroughField('颜色名称'), '湖蓝', '颜色名称');
        await guide.click(find.text('确认'), '确认颜色', linger: 8);
        final rolls = find.byKey(const ValueKey('desktop-entry-roll-count'));
        await _reveal(guide, rolls);
        await guide.type(rolls, '2', '入库卷数 / 每卷 1000 g');
        final price = walkthroughField('单价（元/卷）');
        await _reveal(guide, price);
        await guide.type(price, '89', '耗材单价');
        final save = find.widgetWithText(AppButton, '保存');
        await _reveal(guide, save);
        await guide.click(save, '保存入库', linger: 18);
        await guide.settle();
        await tester.runAsync(() async {
          final all = await guide.db.consumableDao.getPersonal();
          final added = all.where((row) => row.colorName == '湖蓝').toList();
          expect(all, hasLength(6));
          expect(added, hasLength(2));
          expect(added.map((row) => row.totalGrams), everyElement(1000));
          expect(added.map((row) => row.remainingGrams), everyElement(1000));
          for (final row in added) {
            expect(
              await guide.db.consumableDao.isIndividualPersonalSpool(row.id),
              isTrue,
            );
          }
        });
        expect(find.byType(AddConsumableSheet), findsNothing);
        await guide.hold(14);
        guide.mark('库存 / 两卷湖蓝 PLA 已入库');
        await guide.finish(
          '新增耗材与按卷数入库',
          extra: {
            'verifiedLocalResult': '2 separate physical spools, each 1000 g',
            'localStockAdded': 2,
          },
        );
      } finally {
        await guide.dispose();
      }
    },
    skip: !_capture,
    timeout: const Timeout(Duration(minutes: 12)),
  );

  testWidgets(
    'desktop usage 07 load a stored spool into a printer channel',
    (tester) async {
      final scene = _InventoryScene();
      final guide = await DesktopWalkthrough.mount(
        tester,
        segment: '07-load-material',
        seed: (db) => scene.seed(db, printer: true),
      );
      try {
        await guide.hold(10);
        await guide.click(
          find.byKey(const ValueKey('personal-nav-printers')),
          '侧栏 / 打印机',
          linger: 14,
        );
        await guide.settle();
        await guide.click(_channelSpool('未绑定'), '耗材位 / 选择库存卷', linger: 12);
        await guide.settle();
        await guide.type(walkthroughField('搜索'), '雾蓝', '搜索库存颜色');
        await guide.click(find.text('eSUN · 雾蓝 · PLA'), '选择雾蓝 PLA', linger: 18);
        await guide.settle();
        await tester.runAsync(() async {
          final printer = (await guide.db.printerDao.getByIdWithChannels(
            scene.printerId!,
          ))!;
          expect(
            printer.channels.single.channel.consumableId,
            scene.newSpoolId,
          );
          expect(printer.channels.single.channel.loadedRemainingGrams, 1000);
          expect(printer.channels.single.consumable!.remainingGrams, 1000);
          expect(await guide.db.select(guide.db.usageLogs).get(), isEmpty);
        });
        expect(_channelSpool('雾蓝'), findsOneWidget);
        await guide.hold(16);
        guide.mark('耗材位 / 雾蓝 PLA 已装入');
        await guide.finish(
          '为打印机装入库存耗材',
          extra: {
            'verifiedLocalResult':
                'One stock spool bound to one channel at 1000 g',
            'localSpoolBindingsChanged': 1,
          },
        );
      } finally {
        await guide.dispose();
      }
    },
    skip: !_capture,
    timeout: const Timeout(Duration(minutes: 12)),
  );

  testWidgets(
    'desktop usage 08 change a non Bambu spool and retain old remainder',
    (tester) async {
      final scene = _InventoryScene();
      final guide = await DesktopWalkthrough.mount(
        tester,
        segment: '08-change-spool',
        seed: (db) => scene.seed(db, printer: true, loaded: true),
      );
      try {
        await guide.hold(10);
        await guide.click(
          find.byKey(const ValueKey('personal-nav-printers')),
          '侧栏 / 打印机',
          linger: 14,
        );
        await guide.settle();
        // Clicking the spool is the actual channel configuration entry.
        // The separate “更换” button starts the hardware-detection workflow.
        await guide.click(_channelSpool('象牙白'), '耗材位 / 切换库存卷', linger: 12);
        await guide.settle();
        await guide.type(walkthroughField('搜索'), '雾蓝', '搜索新耗材卷');
        await guide.click(
          find.text('eSUN · 雾蓝 · PLA'),
          '选择新卷 / 雾蓝 PLA',
          linger: 14,
        );
        expect(find.text('换卷 · 旧卷剩余克数'), findsOneWidget);
        await guide.type(
          walkthroughField('大约还剩多少克'),
          '375',
          '称重填写 / 旧卷剩余 375 g',
        );
        await guide.click(
          find.widgetWithText(FilledButton, '确认'),
          '保存旧卷余量并装入新卷',
          linger: 18,
        );
        await guide.settle();
        await tester.runAsync(() async {
          final old = (await guide.db.consumableDao.getById(scene.oldSpoolId))!;
          final fresh = (await guide.db.consumableDao.getById(
            scene.newSpoolId,
          ))!;
          expect(old.totalGrams, personalSpoolCapacityGrams);
          expect(old.remainingGrams, 375);
          expect(canReusePersonalSpool(old.remainingGrams), isTrue);
          expect(fresh.totalGrams, personalSpoolCapacityGrams);
          expect(fresh.remainingGrams, personalSpoolCapacityGrams);
          final printer = (await guide.db.printerDao.getByIdWithChannels(
            scene.printerId!,
          ))!;
          expect(
            printer.channels.single.channel.consumableId,
            scene.newSpoolId,
          );
          expect(printer.channels.single.channel.loadedRemainingGrams, 1000);
        });
        expect(_channelSpool('雾蓝'), findsOneWidget);
        await guide.hold(14);
        guide.mark('耗材位 / 新卷已装入');
        await guide.click(
          find.byKey(const ValueKey('personal-nav-inventory')),
          '返回库存 / 查看旧卷余量',
          linger: 18,
        );
        await guide.settle();
        await guide.type(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.hintText == '搜索品牌、型号、材质…',
          ),
          '象牙白',
          '查找已退回库存的旧卷',
        );
        expect(find.text('375g'), findsOneWidget);
        await guide.hold(18);
        guide.mark('库存 / 旧卷保留 375 g');
        await guide.finish(
          '换卷并保存旧卷余量',
          extra: {
            'verifiedLocalResult':
                'Old spool retained at 375 g; new spool loaded at 1000 g',
            'oldSpoolRemainingGrams': 375,
            'newSpoolRemainingGrams': 1000,
            'localSpoolBindingsChanged': 1,
          },
        );
      } finally {
        await guide.dispose();
      }
    },
    skip: !_capture,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
