import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_dao.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_inventory_stock.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  test('同款农场耗材按品种聚合，并从最早入库记录取一卷', () async {
    final studioDao = StudioDao(database);
    addTearDown(studioDao.dispose);
    final workspace = await studioDao.ensureDefaultWorkspace();
    final baseDate = DateTime(2026, 7, 1, 8, 30);
    int? oldestId;

    for (var index = 0; index < 23; index++) {
      final rolls = index == 22 ? 1 : 4;
      final receivedAt = baseDate.add(Duration(days: index));
      final id = await database.consumableDao.addFarmConsumable(
        ConsumablesCompanion.insert(
          uid: Value('farm-green-$index'),
          manufacturer: '拓竹',
          model: 'PLA Basic',
          materialType: const Value('PLA'),
          colorHex: const Value('#00B42A'),
          colorName: const Value('绿色'),
          totalGrams: Value(rolls * 1000),
          remainingGrams: Value(rolls * 1000),
          batchNo: Value('IN-${index + 1}'),
          purchaseDate: Value(receivedAt),
          createdAt: Value(receivedAt),
          updatedAt: Value(receivedAt),
        ),
        workspaceId: workspace.id,
      );
      oldestId ??= id;
    }

    await database.consumableDao.addFarmConsumable(
      ConsumablesCompanion.insert(
        uid: const Value('farm-white-petg'),
        manufacturer: '拓竹',
        model: 'PETG HF',
        materialType: const Value('PETG'),
        colorHex: const Value('#FFFFFF'),
        colorName: const Value('白色'),
        totalGrams: const Value(2000),
        remainingGrams: const Value(2000),
        batchNo: const Value('IN-PETG'),
        purchaseDate: Value(baseDate),
        createdAt: Value(baseDate),
        updatedAt: Value(baseDate),
      ),
      workspaceId: workspace.id,
    );

    final groups = groupFarmWarehouseMaterials(
      await database.consumableDao.getFarm(workspace.id),
    );
    final green = groups.singleWhere(
      (group) => group.representative.colorHex == '#00B42A',
    );

    expect(groups, hasLength(2));
    expect(green.items, hasLength(23));
    expect(green.availableRolls, 89);
    expect(green.availableGrams, 89000);
    expect(green.batchCount, 23);
    expect(green.nextWholeRoll?.id, oldestId);
  });

  test('农场库存归档保留余量和入库批次，并可恢复', () async {
    final studioDao = StudioDao(database);
    addTearDown(studioDao.dispose);
    final workspace = await studioDao.ensureDefaultWorkspace();
    await studioDao.receiveInventoryBatch(
      workspaceId: workspace.id,
      batchNo: 'IN-ARCHIVE',
      receivedAt: DateTime(2026, 8, 6, 10),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: '拓竹',
          model: 'PLA Basic',
          materialType: 'PLA',
          colorHex: '#FFFFFF',
          colorName: '白色',
          rolls: 3,
          gramsPerRoll: 1000,
          unitCost: 99,
        ),
      ],
    );
    final item = (await database.consumableDao.getFarm(workspace.id)).single;

    await database.consumableDao.archiveFarmConsumables(
      [item.id],
      workspaceId: workspace.id,
    );

    final archived = await database.consumableDao.getById(item.id);
    final archivedMetadata = await database.consumableDao
        .getFarmConsumableMetadata([item.id], workspaceId: workspace.id);
    final snapshot = await studioDao.getDefaultSnapshot();
    expect(archived != null, isTrue);
    expect(archived!.remainingGrams, 3000);
    expect(archived.totalGrams, 3000);
    expect(archivedMetadata[item.id]?.archived, isTrue);
    expect(snapshot.inventoryBatches.single.batchNo, 'IN-ARCHIVE');
    expect(snapshot.inventoryBatchItems.single.consumableId, item.id);

    await database.consumableDao.restoreFarmConsumables(
      [item.id],
      workspaceId: workspace.id,
    );
    final restoredMetadata = await database.consumableDao
        .getFarmConsumableMetadata([item.id], workspaceId: workspace.id);
    expect(restoredMetadata[item.id]?.archived, isFalse);
    expect(
        (await database.consumableDao.getById(item.id))!.remainingGrams, 3000);
  });
}
