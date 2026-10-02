import 'dart:async';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/ams_tag_template.dart';
import 'package:consumable_tracker_desktop/mobile/ams_template_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_home_page.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_tag_repository.dart';
import 'package:consumable_tracker_desktop/mobile/rfid_native_bridge.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'support/ams_template_fixture.dart';

const _alice = 'alice@example.com|personal';
const _bob = 'bob@example.com|personal';

class _Vault implements AmsTemplateRepository {
  _Vault(this.template);
  final AmsTagTemplate template;

  @override
  Future<List<AmsTagTemplate>> list({required String ownerAccount}) async => [
    template,
  ];

  @override
  Future<AmsTagTemplate?> read(
    String id, {
    required String ownerAccount,
  }) async => id == template.id ? template : null;

  @override
  Future<void> save(
    AmsTagTemplate template, {
    required String ownerAccount,
  }) async {}

  @override
  Future<void> delete(String id, {required String ownerAccount}) async {}
}

class _Nfc implements RfidNativeBridge, AmsTemplateNfc {
  _Nfc(this.readResult);
  final AmsTemplateReadResult readResult;
  int restores = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> isEnabled() async => true;

  @override
  Future<AmsTemplateReadResult> readAmsTemplate() async => readResult;

  @override
  Future<RfidWriteResult> restoreAmsTemplate(
    AmsTagTemplate template, {
    required String targetKind,
    required bool allowUidChange,
    void Function(String state)? onProgress,
  }) async {
    restores++;
    return RfidWriteSuccess(
      tagId: template.uid,
      tagType: targetKind.toUpperCase(),
      technology: 'MIFARE_CLASSIC',
      blocksWritten: 64,
      blocksVerified: 64,
      verified: true,
      amsCompatibility: 'template_restored_unverified',
    );
  }

  @override
  Future<RfidWriteResult> write(MobileConsumableDraft draft) async =>
      const RfidWriteFailure('UNEXPECTED', '完整模板流程不能调用普通写入');

  @override
  Future<void> cancel() async {}
}

class _Sync implements MobileInventorySync, MobileInventoryStockSync {
  _Sync({this.repository, this.owner = _alice});
  final MobileInventoryRepository? repository;
  final String owner;
  final received = <MobileConsumableDraft>[];
  int saves = 0;
  Completer<MobileInventorySaveResult>? pendingSave;

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
    if (pendingSave != null) return pendingSave!.future;
    if (repository != null) {
      return repository!.addFromDraft(
        draft,
        tagUid: tagId,
        tagType: tagType,
        ownerAccount: owner,
        forceNewCycle: forceNewCycle,
        initialGrams: initialGrams,
        expectedInventoryUid: expectedInventoryUid,
      );
    }
    return const MobileInventorySaveResult(inventoryUid: 'saved-spool');
  }

  @override
  Future<MobileStockReceiptResult> receiveFromCard(
    MobileConsumableDraft draft, {
    required String operationUid,
    required String tagUid,
    required String tagType,
    required int quantity,
    required double initialGrams,
  }) async {
    received.add(draft);
    return MobileStockReceiptResult(
      PersonalStockReceipt(
        operationUid: operationUid,
        inventoryUids: ['received-spool'],
        consumableIds: [1],
        replayed: false,
      ),
    );
  }
}

void main() {
  late AppDatabase database;
  late MobileRfidTagRepository tags;
  late AmsTagTemplate template;
  late _Vault vault;
  late _Sync sync;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    tags = MobileRfidTagRepository(database);
    // Open the real in-memory schema before the widget's NFC callbacks run.
    await tags.count();
    template = syntheticAmsTemplate();
    vault = _Vault(template);
    sync = _Sync();
  });

  tearDown(() async {
    tags.dispose();
    await database.close();
  });

  Future<void> mount(
    WidgetTester tester,
    _Nfc nfc, {
    String owner = _alice,
    _Sync? inventorySync,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MobileRfidHomePage(
          key: const ValueKey('reader-under-test'),
          nfc: nfc,
          sync: inventorySync ?? sync,
          loadMaterials: () async => ['PLA', 'PETG'],
          amsTemplateRepository: vault,
          tagRepository: tags,
          accountIdentity: owner,
          ownerAccount: owner,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addInventory(
    String uid, {
    required String brand,
    required String material,
    String color = '#FFFFFF',
    double remaining = 1000,
    bool sourceCard = false,
  }) async {
    final at = DateTime(2026, 9, 1);
    await database.consumableDao.upsertPersonalInventoryRecord(
      PersonalInventoryRecord(
        uid: uid,
        manufacturer: brand,
        model: material,
        materialType: material,
        colorHex: color,
        totalGrams: 1000,
        remainingGrams: remaining,
        createdAt: at,
        updatedAt: at,
        rfidTagUid: sourceCard ? null : template.uid,
        rfidTagType: sourceCard ? null : 'CUID',
        sourceRfidTagUid: sourceCard ? template.uid : null,
        sourceRfidTagType: sourceCard ? 'CUID' : null,
        stockReceiptUid: sourceCard ? const Uuid().v4() : null,
        stockReceiptIndex: sourceCard ? 0 : null,
        stockReceiptQuantity: sourceCard ? 1 : null,
        lifecycleStatus: remaining <= 0 ? 'depleted' : 'active',
      ),
      ownerAccount: _alice,
    );
  }

  Future<void> openWriter(WidgetTester tester, _Nfc nfc) async {
    await mount(tester, nfc);
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();
    expect(find.text('写入新卡'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('mobile-new-card-brand')),
      'eSUN',
    );
    await tester.tap(find.byKey(const ValueKey('mobile-new-card-material')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLA').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('mobile-new-card-write')),
    );
    await tester.tap(find.byKey(const ValueKey('mobile-new-card-write')));
  }

  testWidgets('读取采用桌面同步的当前绑定，旧扫描资料不会覆盖库存品牌和类型', (tester) async {
    await addInventory(
      'desktop-current-spool',
      brand: 'eSUN',
      material: 'PETG',
      color: '#456789',
    );
    await tags.recordScan(
      tagUid: template.uid,
      tagType: 'CUID',
      ownerAccount: _alice,
      brand: '拓竹',
      model: 'PLA',
      colorHex: '#FFFFFF',
      verified: true,
      occurredAt: DateTime(2026, 9, 2),
    );
    await mount(tester, _Nfc(AmsTemplateReadSuccess(template)));
    await tester.tap(find.byKey(const ValueKey('mobile-reader-primary')));
    await tester.pumpAndSettle();

    expect(find.text('eSUN'), findsOneWidget);
    expect(find.text('PETG · #456789'), findsOneWidget);
    expect(find.text('拓竹'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('mobile-read-confirm-stock')));
    await tester.pumpAndSettle();
    expect(sync.received.single.brand, 'eSUN');
    expect(sync.received.single.model, 'PETG');
    expect(sync.received.single.colorHex, '#456789');
    final scan = await tags.latestForTag(template.uid, ownerAccount: _alice);
    expect(scan!.brand, 'eSUN');
    expect(scan.model, 'PETG');
  });

  testWidgets('同一源卡在同步库存中存在冲突资料时先阻止写卡', (tester) async {
    await addInventory(
      'synced-pla',
      brand: 'eSUN',
      material: 'PLA',
      sourceCard: true,
    );
    await addInventory(
      'synced-petg',
      brand: 'eSUN',
      material: 'PETG',
      sourceCard: true,
    );
    final nfc = _Nfc(const AmsTemplateReadFailure('BLANK_TAG', '空白卡'));
    await openWriter(tester, nfc);
    await tester.pumpAndSettle();

    expect(nfc.restores, 0);
    expect(sync.saves, 0);
    expect(find.textContaining('已绑定为 eSUN · PETG'), findsOneWidget);
    expect(await tags.count(operation: 'write', ownerAccount: _alice), 0);
    expect(
      await database.consumableDao.getPersonalForOwnerAccount(_alice),
      hasLength(2),
    );
  });

  testWidgets('已耗尽的卷写卡后提示确认换卷，保留余量且不伪造新绑定', (tester) async {
    await addInventory(
      'depleted-spool',
      brand: 'eSUN',
      material: 'PLA',
      remaining: 0,
    );
    sync = _Sync(repository: MobileInventoryRepository(database.consumableDao));
    final nfc = _Nfc(const AmsTemplateReadFailure('BLANK_TAG', '空白卡'));
    await openWriter(tester, nfc);
    await tester.pumpAndSettle();

    expect(nfc.restores, 1);
    expect(sync.saves, 1);
    expect(find.textContaining('请到库存详情确认换卷；原余量已保留'), findsOneWidget);
    expect(find.textContaining('耗材已保存'), findsNothing);
    final stock = await database.consumableDao.getPersonalForOwnerAccount(
      _alice,
    );
    expect(stock, hasLength(1));
    expect(stock.single.remainingGrams, 0);
    expect(stock.single.uid, 'depleted-spool');
    expect(await tags.count(operation: 'write', ownerAccount: _alice), 1);
    expect(await tags.count(operation: 'bind', ownerAccount: _alice), 0);
  });

  testWidgets('保存等待中切换账号，迟到结果不会写入新账号审计或显示旧账号成功', (tester) async {
    final nfc = _Nfc(const AmsTemplateReadFailure('BLANK_TAG', '空白卡'));
    sync.pendingSave = Completer<MobileInventorySaveResult>();
    await openWriter(tester, nfc);
    // A pending save keeps the NFC progress animation active.
    for (var frame = 0; frame < 20 && sync.saves == 0; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(sync.saves, 1);
    expect(nfc.restores, 1);
    final bobSync = _Sync(owner: _bob);
    await mount(tester, nfc, owner: _bob, inventorySync: bobSync);
    sync.pendingSave!.complete(
      const MobileInventorySaveResult(inventoryUid: 'alice-saved-spool'),
    );
    await tester.pumpAndSettle();

    expect(bobSync.saves, 0);
    expect(await tags.count(ownerAccount: _bob), 0);
    expect(await tags.count(ownerAccount: _alice), 0);
    expect(find.textContaining('写入完成'), findsNothing);
    expect(find.textContaining('耗材已保存'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('mobile-reader-primary')),
          )
          .onPressed,
      isNotNull,
    );
  });
}
