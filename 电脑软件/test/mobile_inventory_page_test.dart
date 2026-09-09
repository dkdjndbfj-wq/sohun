import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_tag_repository.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';

class _FakeInventorySync
    implements MobileInventorySync, MobileInventoryStockSync {
  final received =
      <
        ({
          String operationUid,
          MobileConsumableDraft draft,
          String tagId,
          String tagType,
          int quantity,
          double initialGrams,
        })
      >[];

  @override
  Future<MobileStockReceiptResult> receiveFromCard(
    MobileConsumableDraft draft, {
    required String operationUid,
    required String tagUid,
    required String tagType,
    required int quantity,
    required double initialGrams,
  }) async {
    received.add((
      operationUid: operationUid,
      draft: draft,
      tagId: tagUid,
      tagType: tagType,
      quantity: quantity,
      initialGrams: initialGrams,
    ));
    return MobileStockReceiptResult(
      PersonalStockReceipt(
        operationUid: operationUid,
        inventoryUids: List.generate(quantity, (i) => '$operationUid-$i'),
        consumableIds: List.generate(quantity, (i) => i + 1),
        replayed: false,
      ),
    );
  }

  final saved =
      <
        ({
          MobileConsumableDraft draft,
          String? tagId,
          String? tagType,
          double initialGrams,
        })
      >[];

  @override
  Future<MobileInventorySaveResult> save(
    MobileConsumableDraft draft, {
    String? tagId,
    String? tagType,
    bool forceNewCycle = false,
    double initialGrams = 1000,
    String? expectedInventoryUid,
  }) async {
    saved.add((
      draft: draft,
      tagId: tagId,
      tagType: tagType,
      initialGrams: initialGrams,
    ));
    return const MobileInventorySaveResult(inventoryUid: 'fake');
  }
}

void main() {
  late AppDatabase database;
  setUp(() => database = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => database.close());
  final now = DateTime(2026, 9, 5);

  final items = [
    Consumable(
      id: 1,
      uid: 'mobile-inventory-1',
      manufacturer: 'eSUN',
      model: 'PLA+',
      materialType: 'PLA+',
      colorHex: '#E5484D',
      colorName: '珊瑚红',
      totalGrams: 1000,
      remainingGrams: 760,
      createdAt: now,
      updatedAt: now,
      trayUuid: '04AABBCC',
    ),
    Consumable(
      id: 2,
      uid: 'mobile-inventory-2',
      manufacturer: 'Bambu Lab',
      model: 'PETG HF',
      materialType: 'PETG HF',
      colorHex: '#FFFFFF',
      colorName: '白',
      totalGrams: 1000,
      remainingGrams: 120,
      createdAt: now,
      updatedAt: now,
    ),
  ];

  testWidgets('手机库存展示桌面数据并提供批量入库入口', (tester) async {
    final sync = _FakeInventorySync();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          consumablesProvider.overrideWith((ref) => Stream.value(items)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: MobileInventoryPage(
            sync: sync,
            loadMaterials: () async => const ['PLA+', 'PETG HF'],
            onOpenWriter: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('耗材库存'), findsOneWidget);
    expect(find.text('eSUN'), findsOneWidget);
    expect(find.text('PLA+'), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-add-inventory')), findsOneWidget);
    expect(find.byIcon(Icons.nfc_rounded), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('mobile-add-inventory')));
    await tester.pumpAndSettle();
    expect(find.text('手动添加'), findsOneWidget);
    expect(find.text('读取 CUID/FUID'), findsOneWidget);
    expect(find.text('确认新增 1 卷'), findsOneWidget);
    expect(find.text('1 卷 = 1 kg'), findsOneWidget);
    expect(find.text('按卷数入库'), findsOneWidget);
    expect(find.text('按余量入库'), findsOneWidget);
    expect(find.byKey(const ValueKey('batch-remaining-grams')), findsNothing);
  });

  testWidgets('手机旧余料详情可以扫描并换绑另一张标签', (tester) async {
    late Consumable old;
    await tester.runAsync(() async {
      final saved = await MobileInventoryRepository(database.consumableDao)
          .addFromDraft(
            MobileConsumableDraft(
              brand: 'eSUN',
              model: 'PLA',
              color: Colors.blue,
              colorName: '蓝',
            ),
            tagUid: '04A1B2C3',
            tagType: 'CUID',
          );
      old = (await database.consumableDao.getPersonalByUid(
        saved.inventoryUid,
      ))!;
      await database.consumableDao.adjustGrams(old.id, 750);
      await database.consumableDao.replacePersonalRfidSpool(
        consumableId: old.id,
        initialGrams: 1000,
      );
      old = (await database.consumableDao.getById(old.id))!;
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          consumablesProvider.overrideWith((ref) => Stream.value([old])),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: MobileInventoryPage(
            sync: LocalMobileInventorySync(database.consumableDao),
            loadMaterials: () async => const ['PLA'],
            onScanCuidFuid: () async =>
                const MobileInventoryTagScan(tagId: '04:bb:00:02'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLA').first);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('旧余料换绑新标签'));
    await tester.tap(find.text('旧余料换绑新标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('扫描新标签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rebind-tag-type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FUID').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认换绑'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect(
        (await database.consumableDao.getRfidSpoolBindingById(old.id))!.tagUid,
        '04BB0002',
      );
      expect(
        (await database.consumableDao.getById(old.id))!.remainingGrams,
        250,
      );
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('库存搜索只显示匹配耗材', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          consumablesProvider.overrideWith((ref) => Stream.value(items)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: MobileInventoryPage(sync: _FakeInventorySync()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'PETG');
    await tester.pumpAndSettle();
    expect(find.text('PETG HF'), findsOneWidget);
    expect(find.text('PLA+'), findsNothing);
  });

  Future<void> openBatch(
    WidgetTester tester,
    _FakeInventorySync sync, {
    MobileInventoryTagScan? scanned,
    MobileInventoryTagScanner? scanner,
    MobileRfidTagRepository? repository,
    Future<void> Function()? onCancelTagScan,
  }) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          consumablesProvider.overrideWith((ref) => Stream.value([])),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: MobileInventoryPage(
            sync: sync,
            loadMaterials: () async => const ['PLA+'],
            onScanCuidFuid: scanner ?? () async => scanned,
            onCancelTagScan: onCancelTagScan,
            tagRepository: repository,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-add-inventory')));
    await tester.pumpAndSettle();
  }

  testWidgets('批量扫码直接拒绝 NTAG，不填耗材资料也不询问卡型', (tester) async {
    final sync = _FakeInventorySync();
    await openBatch(
      tester,
      sync,
      scanned: MobileInventoryTagScan(
        tagId: '04A1B2C3',
        tagType: 'NTAG213',
        draft: MobileConsumableDraft(
          brand: '不应带入的品牌',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    await tester.tap(find.text('读取 CUID/FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pumpAndSettle();
    expect(find.textContaining('NTAG213 等标签不能用于耗材入库'), findsOneWidget);
    expect(find.text('确认耗材标签卡型'), findsNothing);
    expect(find.text('不应带入的品牌'), findsNothing);
    expect(sync.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('通用 Classic 扫码须确认卡型，取消不登记，确认后传递 FUID', (tester) async {
    final sync = _FakeInventorySync();
    await openBatch(
      tester,
      sync,
      scanned: MobileInventoryTagScan(
        tagId: '04:a1:b2:c3',
        tagType: 'CLASSIC',
        draft: MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    await tester.tap(find.text('读取 CUID/FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    // The scanner remains busy while the card-type modal awaits a choice.
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('确认耗材标签卡型'), findsOneWidget);
    expect(sync.saved, isEmpty);
    await tester.tap(
      find.descendant(of: find.byType(AlertDialog), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('已读取资料卡。'), findsNothing);
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('确认 FUID'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已读取资料卡。'), findsOneWidget);
    await tester.ensureVisible(find.text('确认新增 1 卷'));
    await tester.tap(find.text('确认新增 1 卷'));
    await tester.pumpAndSettle();
    expect(sync.saved, isEmpty, reason: '资料卡来源不是逐卷物理标签绑定');
    expect(sync.received, hasLength(1));
    expect(sync.received.single.tagId, '04A1B2C3');
    expect(sync.received.single.tagType, 'FUID');
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一 CUID 重读不自动新增库存，确认批次可使用 500g', (tester) async {
    final sync = _FakeInventorySync();
    await openBatch(
      tester,
      sync,
      scanned: MobileInventoryTagScan(
        tagId: '04:a1:b2:c3',
        tagType: 'CUID',
        draft: MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    await tester.tap(find.text('读取 CUID/FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已读取资料卡。'), findsOneWidget);
    expect(sync.received, isEmpty, reason: '读取资料卡本身不能新增库存');
    expect(find.text('确认新增 1 卷'), findsOneWidget);
    expect(find.byTooltip('增加数量'), findsOneWidget);
    await tester.ensureVisible(find.text('按余量入库'));
    await tester.tap(find.text('按余量入库'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('增加数量'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('batch-remaining-grams')),
      '500',
    );
    await tester.ensureVisible(find.text('确认余量入库'));
    await tester.tap(find.text('确认余量入库'));
    await tester.pumpAndSettle();
    expect(sync.saved, isEmpty, reason: '资料卡来源不是逐卷物理标签绑定');
    expect(sync.received, hasLength(1));
    expect(sync.received.single.tagId, '04A1B2C3');
    expect(sync.received.single.initialGrams, 500);
    expect(tester.takeException(), isNull);
  });

  testWidgets('资料卡可显式新增多卷，再次确认使用新的批次号', (tester) async {
    final sync = _FakeInventorySync();
    await openBatch(
      tester,
      sync,
      scanned: const MobileInventoryTagScan(
        tagId: '04A1B2C3',
        tagType: 'CUID',
        draft: MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    for (final quantity in [3, 1]) {
      await tester.tap(find.text('读取 CUID/FUID'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('开始扫描'));
      await tester.pumpAndSettle();
      for (var i = 1; i < quantity; i++) {
        await tester.ensureVisible(find.byTooltip('增加数量'));
        await tester.tap(find.byTooltip('增加数量'));
        await tester.pumpAndSettle();
      }
      await tester.ensureVisible(find.text('确认新增 $quantity 卷'));
      await tester.tap(find.text('确认新增 $quantity 卷'));
      await tester.pumpAndSettle();
      expect(sync.received.last.quantity, quantity);
      expect(sync.received.last.initialGrams, 1000);
      if (quantity == 3) {
        await tester.tap(find.byKey(const ValueKey('mobile-add-inventory')));
        await tester.pumpAndSettle();
      }
    }
    expect(sync.received, hasLength(2));
    expect(
      sync.received.map((receipt) => receipt.operationUid).toSet(),
      hasLength(2),
    );
    expect(sync.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两种入库模式来回切换不复用隐藏的重量和卷数', (tester) async {
    final sync = _FakeInventorySync();
    await openBatch(
      tester,
      sync,
      scanned: const MobileInventoryTagScan(
        tagId: '04A1B2C3',
        tagType: 'CUID',
        draft: MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    await tester.tap(find.text('读取 CUID/FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('增加数量'));
    await tester.tap(find.byTooltip('增加数量'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('按余量入库'));
    await tester.tap(find.text('按余量入库'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('增加数量'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('batch-remaining-grams')),
      '375.5',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(find.text('按卷数入库'));
    await tester.tap(find.text('按卷数入库'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('batch-remaining-grams')), findsNothing);
    await tester.ensureVisible(find.text('确认新增 2 卷'));
    await tester.tap(find.text('确认新增 2 卷'));
    await tester.pumpAndSettle();
    expect(sync.received.single.quantity, 2);
    expect(sync.received.single.initialGrams, 1000);
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机两种入库在320宽双倍字号下可滚动且无溢出', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openBatch(tester, _FakeInventorySync());
    await tester.binding.setSurfaceSize(const Size(320, 640));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('按余量入库'));
    await tester.tap(find.text('按余量入库'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('batch-remaining-grams')),
    );
    await tester.enterText(
      find.byKey(const ValueKey('batch-remaining-grams')),
      '375',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('确认余量入库'));
    expect(find.text('确认余量入库').hitTestable(), findsOneWidget);
  });

  testWidgets('资料卡读取后点击取消不会增加任何库存', (tester) async {
    final sync = _FakeInventorySync();
    await openBatch(
      tester,
      sync,
      scanned: const MobileInventoryTagScan(
        tagId: '04A1B2C3',
        tagType: 'CUID',
        draft: MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    await tester.tap(find.text('读取 CUID/FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已读取资料卡。'), findsOneWidget);
    await tester.ensureVisible(find.text('取消').last);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(sync.received, isEmpty);
    expect(sync.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('资料卡批量卷数可直接输入到 100 卷', (tester) async {
    final sync = _FakeInventorySync();
    await openBatch(
      tester,
      sync,
      scanned: const MobileInventoryTagScan(
        tagId: '04A1B2C3',
        tagType: 'FUID',
        draft: MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    await tester.tap(find.text('读取 CUID/FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('batch-count-value')));
    await tester.tap(find.byKey(const ValueKey('batch-count-value')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('batch-count-input')),
      '100',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('确认新增 100 卷'), findsOneWidget);
    await tester.tap(find.text('确认新增 100 卷'));
    await tester.pumpAndSettle();
    expect(sync.received.single.quantity, 100);
    expect(sync.received.single.initialGrams, 1000);
    expect(sync.saved, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('卷数输入拒绝超限并在取消时保持原数量', (tester) async {
    await openBatch(tester, _FakeInventorySync());
    final countButton = find.byKey(const ValueKey('batch-count-value'));
    await tester.ensureVisible(countButton);
    await tester.tap(countButton);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('batch-count-input'));
    for (final value in ['', '0', '101']) {
      await tester.enterText(input, value);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('请输入 1–100 之间的整数卷数'), findsOneWidget);
      expect(find.text('输入本次新增卷数'), findsOneWidget);
    }
    await tester.tap(find.widgetWithText(TextButton, '取消').last);
    await tester.pumpAndSettle();
    expect(find.text('确认新增 1 卷'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从资料卡切回手动添加不会沿用已扫描 UID', (tester) async {
    final sync = _FakeInventorySync();
    await openBatch(
      tester,
      sync,
      scanned: const MobileInventoryTagScan(
        tagId: '04A1B2C3',
        tagType: 'CUID',
        draft: MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    await tester.tap(find.text('读取 CUID/FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动添加'));
    await tester.pumpAndSettle();
    expect(find.text('04A1B2C3'), findsNothing);
    await tester.ensureVisible(find.text('确认新增 1 卷'));
    await tester.tap(find.text('确认新增 1 卷'));
    await tester.pumpAndSettle();
    expect(sync.saved, hasLength(1));
    expect(sync.saved.single.tagId, isNull);
    expect(sync.received, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('等待 NFC 时禁用模式切换，完成后手动模式不会保留迟到 UID', (tester) async {
    final sync = _FakeInventorySync();
    final pending = Completer<MobileInventoryTagScan?>();
    await openBatch(tester, sync, scanner: () => pending.future);
    await tester.tap(find.text('读取 CUID/FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pump(const Duration(milliseconds: 100));
    final selector = find.byKey(const ValueKey('batch-source-mode'));
    expect((tester.widget(selector) as dynamic).onSelectionChanged, isNull);
    expect(sync.received, isEmpty);
    pending.complete(
      const MobileInventoryTagScan(
        tagId: '04A1B2C3',
        tagType: 'CUID',
        draft: MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect((tester.widget(selector) as dynamic).onSelectionChanged, isNotNull);
    await tester.tap(find.text('手动添加'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认新增 1 卷'));
    await tester.tap(find.text('确认新增 1 卷'));
    await tester.pumpAndSettle();
    expect(sync.saved.single.tagId, isNull);
    expect(sync.received, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('余量模式拒绝非法克数，仅传递一卷实际剩余重量', (tester) async {
    final sync = _FakeInventorySync();
    await openBatch(
      tester,
      sync,
      scanned: MobileInventoryTagScan(
        tagId: '04A1B2C3',
        tagType: 'FUID',
        draft: MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA+',
          color: Colors.blue,
          colorName: '蓝',
        ),
      ),
    );
    await tester.tap(find.text('读取 CUID/FUID'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始扫描'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('按余量入库'));
    await tester.tap(find.text('按余量入库'));
    await tester.pumpAndSettle();
    for (final invalid in ['', '0', '-1', 'NaN', '1001']) {
      await tester.enterText(
        find.byKey(const ValueKey('batch-remaining-grams')),
        invalid,
      );
      await tester.ensureVisible(find.text('确认余量入库'));
      await tester.tap(find.text('确认余量入库'));
      await tester.pumpAndSettle();
      expect(sync.saved, isEmpty);
      expect(find.text('请输入大于 0 且不超过 1000 g 的剩余克数'), findsOneWidget);
    }
    await tester.enterText(
      find.byKey(const ValueKey('batch-remaining-grams')),
      '375',
    );
    await tester.ensureVisible(find.text('确认余量入库'));
    await tester.tap(find.text('确认余量入库'));
    await tester.pumpAndSettle();
    expect(sync.received.single.initialGrams, 375);
    expect(sync.received.single.tagType, 'FUID');
    expect(sync.received.single.quantity, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('耗材标签选择器只提供已确认 CUID/FUID 并保留选择的卡型', (tester) async {
    final sync = _FakeInventorySync();
    final repository = _PickerRepository(database, [
      RfidTagRecord(tagUid: '04A1B2C3', tagType: 'FUID', occurredAt: now),
      RfidTagRecord(tagUid: '04A1B204', tagType: 'NTAG213', occurredAt: now),
      RfidTagRecord(tagUid: '04A1B205', tagType: 'CLASSIC', occurredAt: now),
      RfidTagRecord(
        tagUid: '04A1B206',
        tagType: 'CUID',
        profile: 'ntag213',
        occurredAt: now,
      ),
      RfidTagRecord(tagUid: '04A1B207', occurredAt: now),
    ]);
    addTearDown(repository.dispose);
    await openBatch(tester, sync, repository: repository);
    await tester.ensureVisible(find.text('从已保存标签选择'));
    await tester.tap(find.text('从已保存标签选择'));
    await tester.pumpAndSettle();
    expect(find.text('04A1B2C3'), findsOneWidget);
    for (final uid in ['04A1B204', '04A1B205', '04A1B206', '04A1B207']) {
      expect(find.text(uid), findsNothing);
    }
    await tester.tap(find.text('04A1B2C3'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.decoration?.labelText == '品牌',
      ),
      'eSUN',
    );
    await tester.ensureVisible(find.text('选择桌面端型号'));
    await tester.tap(find.text('选择桌面端型号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLA+').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('确认新增 1 卷'));
    await tester.tap(find.text('确认新增 1 卷'));
    await tester.pumpAndSettle();
    expect(find.text('确认耗材标签卡型'), findsNothing);
    expect(sync.saved, isEmpty, reason: '资料卡来源不是逐卷物理标签绑定');
    expect(sync.received, hasLength(1));
    expect(sync.received.single.tagType, 'FUID');
    expect(tester.takeException(), isNull);
  });

  testWidgets('已保存标签弹窗在手机上可滚动选择第 12 条以后的记录', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _PickerRepository(database, [
      for (var index = 29; index >= 0; index--)
        RfidTagRecord(
          tagUid:
              'A1B2${index.toRadixString(16).padLeft(4, '0').toUpperCase()}',
          tagType: 'CUID',
          brand: 'eSUN',
          model: 'PLA+',
          occurredAt: now.add(Duration(minutes: index)),
        ),
    ]);
    addTearDown(repository.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          consumablesProvider.overrideWith((ref) => Stream.value(items)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: MobileInventoryPage(
            sync: _FakeInventorySync(),
            loadMaterials: () async => ['PLA+'],
            tagRepository: repository,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-add-inventory')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('从已保存标签选择'));
    await tester.tap(find.text('从已保存标签选择'));
    await tester.pumpAndSettle();
    expect(find.text('选择已保存标签'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('A1B20000'),
      350,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('A1B20000'));
    await tester.pumpAndSettle();
    expect(find.text('选择已保存标签'), findsNothing);
    expect(find.text('A1B20000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _PickerRepository extends MobileRfidTagRepository {
  _PickerRepository(super.db, this.records);
  final List<RfidTagRecord> records;

  @override
  Future<int> record(RfidTagRecord entry) async => records.length + 1;

  @override
  Future<List<RfidTagRecord>> list({
    String? ownerAccount,
    String? tagUid,
    String? profile,
    String? operation,
    int limit = 100,
  }) async => records;

  @override
  Future<List<RfidTagRecord>> listInventoryTagBindings({
    String? ownerAccount,
    int limit = 100,
  }) async => [];
}
