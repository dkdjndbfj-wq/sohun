// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_dao.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  test('v34 repairs timestamp units and assigns linked stock to its farm',
      () async {
    final directory = await Directory.systemTemp.createTemp('scope_v34_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/inventory.sqlite');

    final staged = AppDatabase.forTestingAtVersion(
      NativeDatabase(file),
      33,
    );
    await staged.customSelect('SELECT 1').getSingle();
    await staged.close();

    final raw = sqlite.sqlite3.open(file.path);
    raw.execute('DROP INDEX IF EXISTS idx_consumables_inventory_scope');
    raw.execute('DROP INDEX IF EXISTS idx_consumables_farm_archived');
    raw.execute('ALTER TABLE consumables DROP COLUMN farm_workspace_id');
    raw.execute('ALTER TABLE consumables DROP COLUMN inventory_scope');
    raw.execute('''
      INSERT INTO consumables(
        uid, manufacturer, model, material_type, color_hex,
        total_grams, remaining_grams, created_at, updated_at
      ) VALUES(
        'personal-1', 'Personal', 'PLA', 'PLA', '#FFFFFF',
        1000, 900, 1785760317, 1785760317
      )
    ''');
    raw.execute('''
      INSERT INTO consumables(
        uid, manufacturer, model, material_type, color_hex,
        total_grams, remaining_grams, purchase_date, created_at, updated_at
      ) VALUES(
        'farm-1', 'Farm', 'PETG', 'PETG', '#000000',
        1000, 1000, 1785760317850000, 1785760317851, 1785760317851000
      )
    ''');
    final farmId = raw.lastInsertRowId;
    raw.execute('''
      INSERT INTO studio_inventory_batches(
        id, workspace_id, batch_no, received_at, roll_count,
        total_grams, created_at
      ) VALUES('batch-1', 'workspace-farm', 'IN-1', 1785760317850, 1, 1000, 1785760317851)
    ''');
    raw.execute('''
      INSERT INTO studio_inventory_batch_items(
        id, batch_id, consumable_id, unit_cost, created_at
      ) VALUES('item-1', 'batch-1', $farmId, 80, 1785760317851)
    ''');
    raw.execute('PRAGMA user_version = 33');
    raw.close();

    final upgraded = AppDatabase.forTesting(NativeDatabase(file));
    addTearDown(upgraded.close);

    final personal = await upgraded.consumableDao.getPersonal();
    final farm = await upgraded.consumableDao.getFarm('workspace-farm');
    expect(personal.map((item) => item.uid), ['personal-1']);
    expect(farm.map((item) => item.uid), ['farm-1']);
    expect(farm.single.purchaseDate?.millisecondsSinceEpoch, 1785760317000);
    expect(farm.single.createdAt.millisecondsSinceEpoch, 1785760317000);
    expect(farm.single.updatedAt.millisecondsSinceEpoch, 1785760317000);
  });

  test('v38 rebuilds missing batch links and derives rolls from 1000g units',
      () async {
    final directory = await Directory.systemTemp.createTemp('batch_v38_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/inventory.sqlite');

    final staged = AppDatabase.forTestingAtVersion(
      NativeDatabase(file),
      37,
    );
    await staged.customSelect('SELECT 1').getSingle();
    await staged.customStatement('''
      INSERT INTO studio_workspaces(id, name, created_at, updated_at)
      VALUES('farm-v38', '迁移测试农场', 1, 1)
    ''');
    await staged.customStatement('''
      INSERT INTO studio_inventory_batches(
        id, workspace_id, batch_no, received_at, roll_count,
        total_grams, created_at
      ) VALUES('batch-v38', 'farm-v38', 'IN-V38', 1, 23, 23000, 1)
    ''');
    for (var index = 0; index < 23; index++) {
      final grams = index == 0 ? 67000 : 1000;
      await staged.customStatement('''
        INSERT INTO consumables(
          uid, manufacturer, model, material_type, color_hex, color_name,
          total_grams, remaining_grams, batch_no, created_at, updated_at,
          inventory_scope, farm_workspace_id
        ) VALUES(
          'farm-v38-$index', '拓竹', 'PLA Basic', 'PLA', '#00B42A', '绿色',
          $grams, $grams, 'IN-V38', 1, 1, 'farm', 'farm-v38'
        )
      ''');
    }
    await staged.close();

    final upgraded = AppDatabase.forTesting(NativeDatabase(file));
    final studio = StudioDao(upgraded);
    addTearDown(() async {
      studio.dispose();
      await upgraded.close();
    });

    final snapshot = await studio.getDefaultSnapshot();
    expect(snapshot.inventoryBatches.single.rollCount, 89);
    expect(snapshot.inventoryBatches.single.totalGrams, 89000);
    expect(snapshot.inventoryBatchItems, hasLength(23));
    expect(
      snapshot.inventoryBatchItems.fold<int>(
        0,
        (sum, item) => sum + item.rollCount,
      ),
      89,
    );
    expect(
      (await upgraded.consumableDao.getFarm('farm-v38')).fold<int>(
        0,
        (sum, item) => sum + (item.remainingGrams / 1000).floor(),
      ),
      89,
    );
  });

  test('cloud sync cannot overwrite repaired farm batch totals with stale data',
      () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final studio = StudioDao(database);
    addTearDown(() async {
      studio.dispose();
      await database.close();
    });
    final createdAt = DateTime(2026, 8, 3, 20, 31).toUtc().toIso8601String();

    await studio.mergeRemoteSnapshot({
      'inventoryItems': [
        for (var index = 0; index < 23; index++)
          {
            'uid': 'remote-farm-$index',
            'manufacturer': '拓竹',
            'model': 'PLA Basic',
            'materialType': 'PLA',
            'colorHex': '#00B42A',
            'colorName': '绿色',
            'totalGrams': index == 0 ? 67000 : 1000,
            'remainingGrams': index == 0 ? 67000 : 1000,
            'batchNo': 'IN-CLOUD-STALE',
            'createdAt': createdAt,
            'updatedAt': createdAt,
          },
      ],
      'inventoryBatches': [
        {
          'id': 'remote-stale-batch',
          'batchNo': 'IN-CLOUD-STALE',
          'receivedAt': createdAt,
          'rollCount': 23,
          'totalGrams': 23000,
          'createdAt': createdAt,
        },
      ],
    });

    final snapshot = await studio.getDefaultSnapshot();
    expect(snapshot.inventoryBatches.single.rollCount, 89);
    expect(snapshot.inventoryBatches.single.totalGrams, 89000);
    expect(snapshot.inventoryBatchItems, hasLength(23));
    expect(
      snapshot.inventoryBatchItems.fold<int>(
        0,
        (sum, item) => sum + item.rollCount,
      ),
      89,
    );
  });

  test('farm inventory operations reject personal stock ids', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final studio = StudioDao(database);
    addTearDown(() async {
      studio.dispose();
      await database.close();
    });
    final workspace = await studio.ensureDefaultWorkspace();
    final now = DateTime.now();
    final personalId = await database.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        uid: const Value('personal-spool'),
        manufacturer: 'Personal',
        model: 'PLA',
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    final farmId = await database.consumableDao.addFarmConsumable(
      ConsumablesCompanion.insert(
        uid: const Value('farm-spool'),
        manufacturer: 'Farm',
        model: 'PLA',
        createdAt: Value(now),
        updatedAt: Value(now),
      ),
      workspaceId: workspace.id,
    );

    expect(await database.consumableDao.getPersonal(), hasLength(1));
    expect(await database.consumableDao.getFarm(workspace.id), hasLength(1));
    await database.usageLogDao.addLog(
      UsageLogsCompanion.insert(
        consumableId: Value(personalId),
        consumedGrams: const Value(10),
      ),
    );
    await database.usageLogDao.addLog(
      UsageLogsCompanion.insert(
        consumableId: Value(farmId),
        consumedGrams: const Value(20),
      ),
    );
    expect(await database.usageLogDao.getPersonal(), hasLength(1));
    await expectLater(
      studio.adjustInventory(
        workspaceId: workspace.id,
        consumableId: personalId,
        deltaGrams: -100,
        type: StudioInventoryEventType.consume,
        reason: 'must be rejected',
      ),
      throwsStateError,
    );
    expect(
      await studio.adjustInventory(
        workspaceId: workspace.id,
        consumableId: farmId,
        deltaGrams: -100,
        type: StudioInventoryEventType.consume,
        reason: 'farm use',
      ),
      -100,
    );
  });

  test('farm inventory can delete an unbound spool and keeps batch totals',
      () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final studio = StudioDao(database);
    addTearDown(() async {
      studio.dispose();
      await database.close();
    });
    final workspace = await studio.ensureDefaultWorkspace();
    await studio.receiveInventoryBatch(
      workspaceId: workspace.id,
      batchNo: 'IN-DELETE',
      receivedAt: DateTime.now(),
      lines: const [
        StudioBatchReceiveLine(
          manufacturer: 'Farm',
          materialType: 'PLA',
          colorHex: '#FF0000',
          rolls: 2,
        ),
      ],
    );
    final initial = await database.consumableDao.getFarm(workspace.id);
    expect(initial, hasLength(1));
    await database.consumableDao.deleteFarmConsumable(
      initial.first.id,
      workspaceId: workspace.id,
    );
    expect(await database.consumableDao.getFarm(workspace.id), isEmpty);
    final snapshot = await studio.getDefaultSnapshot();
    expect(snapshot.inventoryBatches, isEmpty);
  });
}
