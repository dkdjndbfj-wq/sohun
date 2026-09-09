import 'package:consumable_tracker_desktop/core/services/farm_brand_catalog_service.dart';
import 'package:consumable_tracker_desktop/core/services/material_identity_service.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_inventory_stock.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RFID 品牌边界', () {
    test('只有明确为拓竹品牌的 RFID 才进入原厂流程', () {
      const official = AmsTray(
        amsId: 0,
        slot: 0,
        trayInfoIdx: 'GFL99',
        trayUuid: 'bambu-uuid',
        traySubBrands: 'Bambu Lab',
        hasFilament: true,
      );
      const thirdPartyRfid = AmsTray(
        amsId: 0,
        slot: 1,
        trayInfoIdx: 'OTHER01',
        trayUuid: 'other-brand-uuid',
        traySubBrands: 'Other RFID Brand',
        hasFilament: true,
      );

      expect(official.isBambuOfficialRfid, isTrue);
      expect(thirdPartyRfid.isBambuOfficialRfid, isFalse);
    });
  });

  test('支撑材料不会与普通 PLA 归为同族', () {
    expect(
      MaterialIdentityService.sameFamily('Bambu Support For PLA', 'PLA Basic'),
      isFalse,
    );
    expect(
      MaterialIdentityService.normalize('Bambu Support For PLA').family,
      'SUPPORT-PLA',
    );
  });

  test('品牌别名标准化，颜色名称不参与库存分组', () async {
    expect(FarmBrandCatalogService.normalize('Bambu Lab').code, 'bambu_lab');
    expect(FarmBrandCatalogService.normalize('拓竹').code, 'bambu_lab');

    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final studio = StudioDao(database);
    addTearDown(studio.dispose);
    final workspace = await studio.ensureDefaultWorkspace();
    await studio.receiveInventoryBatch(
      workspaceId: workspace.id,
      batchNo: 'COLOR-GROUP-A',
      receivedAt: DateTime(2026, 8, 7),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: '拓竹',
          brandCode: 'bambu_lab',
          model: 'PLA Basic',
          materialType: 'PLA',
          colorHex: '#FFFFFF',
          colorName: '白色',
          rolls: 1,
        ),
      ],
    );
    await studio.receiveInventoryBatch(
      workspaceId: workspace.id,
      batchNo: 'COLOR-GROUP-B',
      receivedAt: DateTime(2026, 8, 7, 1),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Bambu Lab',
          brandCode: 'bambu_lab',
          model: 'PLA Basic',
          materialType: 'PLA',
          colorHex: '#FFFFFF',
          colorName: '珍珠白',
          rolls: 1,
        ),
      ],
    );

    final groups = groupFarmWarehouseMaterials(
      await database.consumableDao.getFarm(workspace.id),
    );
    expect(groups, hasLength(1));
    expect(groups.single.availableRolls, 2);
  });

  test('多色字段可保存，错误入库明细可冲销并保留审计', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final studio = StudioDao(database);
    addTearDown(studio.dispose);
    final workspace = await studio.ensureDefaultWorkspace();
    final batchId = await studio.receiveInventoryBatch(
      workspaceId: workspace.id,
      batchNo: 'MULTI-VOID',
      receivedAt: DateTime(2026, 8, 7, 10),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Generic',
          brandCode: 'generic',
          model: 'PLA Multi Color',
          materialType: 'PLA',
          colorHex: '#FF0000',
          colorMode: 'multi',
          secondaryColorHex: '#0000FF',
          rolls: 2,
        ),
      ],
    );
    var snapshot = await studio.getDefaultSnapshot();
    final batchItem = snapshot.inventoryBatchItems.single;
    final metadata = await database.consumableDao.getFarmConsumableMetadata(
      [batchItem.consumableId],
      workspaceId: workspace.id,
    );
    expect(metadata[batchItem.consumableId]?.colorMode, 'multi');
    expect(metadata[batchItem.consumableId]?.secondaryColorHex, '#0000FF');

    await studio.voidInventoryBatchItem(
      itemId: batchItem.id,
      workspaceId: workspace.id,
      reason: '重复入库测试',
    );
    snapshot = await studio.getDefaultSnapshot();
    final voided = snapshot.inventoryBatchItems.single;
    final batch =
        snapshot.inventoryBatches.singleWhere((item) => item.id == batchId);
    final consumable =
        await database.consumableDao.getById(batchItem.consumableId);
    final afterMetadata =
        await database.consumableDao.getFarmConsumableMetadata(
      [batchItem.consumableId],
      workspaceId: workspace.id,
    );

    expect(voided.voided, isTrue);
    expect(voided.voidReason, '重复入库测试');
    expect(voided.voidedAt, isNotNull);
    // 全部明细被冲销时，批次表保留原始到货合计（旧库约束要求 > 0）；
    // 当前有效数量由未冲销明细计算，仓库可用量已经归零。
    expect(batch.rollCount, 2);
    expect(batch.totalGrams, 2000);
    expect(consumable?.remainingGrams, 0);
    expect(consumable?.totalGrams, 2000);
    expect(afterMetadata[batchItem.consumableId]?.archived, isTrue);
    expect(
      snapshot.inventoryEvents.any(
        (event) => event.reason.contains('冲销入库明细'),
      ),
      isTrue,
    );
    expect(
      snapshot.activityEvents.any(
        (event) => event.actionCode == 'inventory.batch_item_voided',
      ),
      isTrue,
    );
  });
}
