import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final type in <String?>[
    'NTAG213',
    'NTAG213 CUID',
    'CLASSIC',
    null,
    'ams',
  ]) {
    test(
      '$type history cannot bypass desktop replacement or retagging boundaries',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final at = DateTime.utc(2026, 9, 8);
        final old = await db.consumableDao.upsertPersonalInventoryRecord(
          PersonalInventoryRecord(
            uid: 'historical-roll',
            manufacturer: 'eSUN',
            model: 'PLA',
            materialType: 'PLA',
            colorHex: '#FFFFFF',
            totalGrams: 750,
            remainingGrams: 123,
            createdAt: at,
            updatedAt: at,
            rfidTagUid: '04A1B2C3',
            rfidTagType: type,
          ),
        );
        await expectLater(
          db.consumableDao.replacePersonalRfidSpool(
            consumableId: old,
            initialGrams: 500,
          ),
          throwsStateError,
        );
        expect(await db.select(db.consumables).get(), hasLength(1));
        final original = (await db.consumableDao.getRfidSpoolBindingById(old))!;
        expect(original.tagType, type);
        expect(original.status, 'active');
        // A valid successor graph isolates the old-card-type gate: every other
        // precondition for moving this leftover spool to an unused CUID is met.
        await db.consumableDao.updateRfidSpoolLifecycle(
          old,
          status: 'replaced',
        );
        await db.consumableDao.upsertPersonalInventoryRecord(
          PersonalInventoryRecord(
            uid: 'next-roll',
            manufacturer: 'eSUN',
            model: 'PLA',
            materialType: 'PLA',
            colorHex: '#FFFFFF',
            totalGrams: 500,
            remainingGrams: 500,
            createdAt: at,
            updatedAt: at,
            rfidTagUid: '04A1B2C3',
            rfidTagType: 'CUID',
            rfidTagCycle: 2,
            previousConsumableUid: 'historical-roll',
          ),
        );
        await expectLater(
          db.consumableDao.rebindPersonalRfidSpool(
            consumableId: old,
            expectedTagUid: '04A1B2C3',
            newTagUid: '04BB0002',
            newTagType: 'CUID',
            ownerAccount: null,
          ),
          throwsStateError,
        );
        final preserved = (await db.consumableDao.getRfidSpoolBindingById(
          old,
        ))!;
        expect(preserved.tagUid, original.tagUid);
        expect(preserved.tagType, original.tagType);
        expect(preserved.tagHistory, isEmpty);
        expect((await db.consumableDao.getById(old))!.remainingGrams, 123);
        expect(
          (await db.consumableDao.getPersonalInventoryEventsForUid(
            'historical-roll',
            ownerAccount: null,
          )).where((e) => e.eventType == 'tag_rebound'),
          isEmpty,
        );
      },
    );
  }
}
