import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/data/models/rfid_tag_history.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late Consumable old;
  late RfidSpoolBinding successor;
  const owner = 'rebind@example.com|personal';
  const originalTag = '04AA0001';
  const newTag = '04BB0002';
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.utc(2026, 9, 8);
    final id = await db.consumableDao.upsertPersonalInventoryRecord(
      PersonalInventoryRecord(
        uid: 'leftover',
        manufacturer: 'eSUN',
        model: 'PLA',
        materialType: 'PLA',
        colorHex: '#FFFFFF',
        totalGrams: 1000,
        remainingGrams: 750,
        createdAt: now,
        updatedAt: now,
        rfidTagUid: originalTag,
        rfidTagType: 'CUID',
      ),
      ownerAccount: owner,
    );
    await db.consumableDao.adjustGrams(id, 625);
    await db.usageLogDao.addLog(
      UsageLogsCompanion.insert(
        channelIndex: Value(0),
        consumableId: Value(id),
        consumedGrams: Value(625),
      ),
    );
    successor = await db.consumableDao.replacePersonalRfidSpool(
      consumableId: id,
      initialGrams: 500,
    );
    old = (await db.consumableDao.getById(id))!;
  });
  tearDown(() => db.close());

  Future<RfidSpoolBinding> rebind({
    String tag = newTag,
    String? account = owner,
  }) => db.consumableDao.rebindPersonalRfidSpool(
    consumableId: old.id,
    expectedTagUid: originalTag,
    newTagUid: tag,
    newTagType: 'FUID',
    ownerAccount: account,
  );

  test(
    'retagging preserves spool balance, usage, old tag chain and successor',
    () async {
      final rebound = await rebind(tag: '04:bb:00:02');
      final row = (await db.consumableDao.getById(old.id))!;
      expect(row.uid, old.uid);
      expect(row.totalGrams, 1000);
      expect(row.remainingGrams, 125);
      expect(row.createdAt, old.createdAt);
      expect(rebound.tagUid, newTag);
      expect(rebound.cycle, 1);
      expect(rebound.previousInventoryUid, isNull);
      expect(rebound.isActive, isTrue);
      expect(rebound.tagHistory.single.tagUid, originalTag);
      final history = await db.consumableDao.getPersonalRfidSpoolHistory(
        originalTag,
        ownerAccount: owner,
      );
      expect(history.map((b) => b.inventoryUid), [
        successor.inventoryUid,
        old.uid,
      ]);
      expect(history.last.isHistoricalTag, isTrue);
      expect(history.last.isActive, isFalse);
      expect(
        (await db.consumableDao.getPersonalActiveRfidSpool(
          originalTag,
          ownerAccount: owner,
        ))!.inventoryUid,
        successor.inventoryUid,
      );
      expect(
        (await db.consumableDao.getPersonalActiveRfidSpool(
          newTag,
          ownerAccount: owner,
        ))!.inventoryUid,
        old.uid,
      );
      expect(
        await db.consumableDao.getPersonalInventoryConsumedGrams(
          old.uid,
          ownerAccount: owner,
        ),
        625,
      );
      final event = (await db.consumableDao.getPersonalInventoryEventsForUid(
        old.uid,
        ownerAccount: owner,
      )).firstWhere((e) => e.eventType == 'tag_rebound');
      expect(event.beforeGrams, 125);
      expect(event.afterGrams, 125);
      expect(event.deltaGrams, 0);
      expect(event.rfidTagUid, newTag);
      final next = await db.consumableDao.replacePersonalRfidSpool(
        consumableId: old.id,
        initialGrams: 1000,
      );
      expect(next.cycle, 2);
      expect(next.previousInventoryUid, old.uid);
      expect(
        (await db.consumableDao.getPersonalRfidSpoolHistory(
          originalTag,
          ownerAccount: owner,
        )),
        hasLength(2),
      );
      final again = await db.consumableDao.rebindPersonalRfidSpool(
        consumableId: old.id,
        expectedTagUid: newTag,
        newTagUid: '04CC0003',
        newTagType: 'CUID',
        ownerAccount: owner,
      );
      expect(again.tagHistory.map((entry) => entry.tagUid), [
        originalTag,
        newTag,
      ]);
      expect(
        (await db.consumableDao.getPersonalRfidSpoolHistory(
          newTag,
          ownerAccount: owner,
        )),
        hasLength(2),
      );
      expect(
        (await db.consumableDao.getPersonalRfidSpoolHistory(
          originalTag,
          ownerAccount: owner,
        )),
        hasLength(2),
      );
      expect((await db.consumableDao.getById(old.id))!.remainingGrams, 125);
    },
  );

  test(
    'wrong account, same tag, invalid UID and stale UI cannot alter the roll',
    () async {
      for (final operation in <Future<Object?> Function()>[
        () => rebind(account: null),
        () => rebind(account: 'other|personal'),
        () => rebind(tag: originalTag),
        () => rebind(tag: '04BB000200000000'),
      ]) {
        await expectLater(
          operation(),
          throwsA(anyOf(isA<StateError>(), isA<ArgumentError>())),
        );
      }
      await rebind();
      await expectLater(rebind(tag: '04CC0003'), throwsStateError);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(old.id))!.tagHistory,
        hasLength(1),
      );
      expect((await db.consumableDao.getById(old.id))!.remainingGrams, 125);
    },
  );

  test(
    'a tag recorded for another account cannot be silently rebound',
    () async {
      final now = DateTime.now();
      await db.consumableDao.upsertPersonalInventoryRecord(
        PersonalInventoryRecord(
          uid: 'foreign',
          manufacturer: 'eSUN',
          model: 'PLA',
          materialType: 'PLA',
          colorHex: '#FFFFFF',
          totalGrams: 1000,
          remainingGrams: 1000,
          createdAt: now,
          updatedAt: now,
          rfidTagUid: newTag,
        ),
        ownerAccount: 'foreign|personal',
      );
      await expectLater(rebind(), throwsStateError);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(old.id))!.tagUid,
        originalTag,
      );
    },
  );

  test('unsettled task blocks retagging atomically', () async {
    final task = await db.customInsert(
      "INSERT INTO print_tasks(uid, gcode_path, task_name, status, created_at, updated_at) VALUES ('rebind-print', 'test.gcode', 'test', 'printing', 1, 1)",
    );
    await db.customInsert(
      'INSERT INTO print_task_consumables(task_id, consumable_id, estimated_grams, created_at, updated_at) VALUES (?, ?, 20, 1, 1)',
      variables: [Variable(task), Variable(old.id)],
    );
    await expectLater(rebind(), throwsStateError);
    expect(
      (await db.consumableDao.getRfidSpoolBindingById(old.id))!.tagHistory,
      isEmpty,
    );
    expect(
      (await db.consumableDao.getPersonalInventoryEventsForUid(
        old.uid,
        ownerAccount: owner,
      )).where((e) => e.eventType == 'tag_rebound'),
      isEmpty,
    );
  });

  for (final status in ['depleted', 'retired', 'replaced']) {
    test(
      'a $status target UID with historical ownership is not an unused tag',
      () async {
        final now = DateTime.now();
        await db.consumableDao.upsertPersonalInventoryRecord(
          PersonalInventoryRecord(
            uid: 'previous-target',
            manufacturer: 'old',
            model: 'PLA',
            materialType: 'PLA',
            colorHex: '#FFFFFF',
            totalGrams: 1000,
            remainingGrams: status == 'depleted' ? 0 : 200,
            createdAt: now,
            updatedAt: now,
            rfidTagUid: '04:bb:00:02',
            rfidTagType: 'CUID',
            rfidTagCycle: 3,
            lifecycleStatus: status,
          ),
          ownerAccount: 'foreign|personal',
        );
        expect(
          await db.consumableDao.getAnyPersonalByRfidTagUid(newTag),
          isNull,
        );
        await expectLater(rebind(tag: '04 bb 00 02'), throwsStateError);
        expect(
          (await db.consumableDao.getRfidSpoolBindingById(old.id))!.tagUid,
          originalTag,
        );
        expect((await db.consumableDao.getById(old.id))!.remainingGrams, 125);
      },
    );
  }

  test(
    'ambiguous active target UID cannot bypass the unused-tag check',
    () async {
      final now = DateTime.now();
      for (final suffix in ['a', 'b']) {
        await db.consumableDao.upsertPersonalInventoryRecord(
          PersonalInventoryRecord(
            uid: 'target-$suffix',
            manufacturer: 'old',
            model: 'PLA',
            materialType: 'PLA',
            colorHex: '#FFFFFF',
            totalGrams: 1000,
            remainingGrams: 200,
            createdAt: now,
            updatedAt: now,
            rfidTagUid: newTag,
            rfidTagType: 'CUID',
          ),
          ownerAccount: '$suffix|personal',
        );
      }
      expect(await db.consumableDao.getAnyPersonalByRfidTagUid(newTag), isNull);
      await expectLater(rebind(), throwsStateError);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(old.id))!.tagHistory,
        isEmpty,
      );
    },
  );

  test(
    'a UID retained only in another spool tag history cannot start cycle one again',
    () async {
      final now = DateTime.now();
      await db.consumableDao.upsertPersonalInventoryRecord(
        PersonalInventoryRecord(
          uid: 'already-retagged',
          manufacturer: 'old',
          model: 'PLA',
          materialType: 'PLA',
          colorHex: '#FFFFFF',
          totalGrams: 1000,
          remainingGrams: 200,
          createdAt: now,
          updatedAt: now,
          rfidTagUid: '04DD0004',
          rfidTagType: 'FUID',
          rfidTagHistory: [RfidTagHistoryEntry(tagUid: newTag, cycle: 1)],
        ),
        ownerAccount: owner,
      );
      final history = await db.consumableDao.getAnyPersonalRfidSpoolHistory(
        newTag,
      );
      expect(history.single.isHistoricalTag, isTrue);
      await expectLater(rebind(), throwsStateError);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(old.id))!.tagUid,
        originalTag,
      );
    },
  );

  test('a retired spool cannot be reactivated by changing its tag', () async {
    await db.consumableDao.retirePersonalRfidSpool(old.id);
    await expectLater(rebind(), throwsStateError);
  });
}
