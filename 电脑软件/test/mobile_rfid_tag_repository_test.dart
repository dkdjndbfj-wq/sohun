import 'dart:async';

import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_tag_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late MobileRfidTagRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = MobileRfidTagRepository(database);
  });

  tearDown(() async {
    repository.dispose();
    await database.close();
  });

  test('stores repeated UID writes as separate history rows', () async {
    final timestamp = DateTime.fromMillisecondsSinceEpoch(1000);
    final first = await repository.recordWrite(
      tagUid: '04:A1:B2:C3',
      tagType: 'CUID',
      technology: 'MIFARE Classic',
      profile: 'ams',
      brand: 'Sohun',
      model: 'PLA',
      colorHex: '#00B42A',
      verified: true,
      occurredAt: timestamp,
    );
    final second = await repository.recordWrite(
      tagUid: '04:A1:B2:C3',
      tagType: 'CUID',
      technology: 'MIFARE Classic',
      profile: 'ams',
      brand: 'Sohun',
      model: 'PETG',
      colorHex: '#FF0000',
      occurredAt: timestamp.add(const Duration(seconds: 1)),
    );

    expect(first, isNot(second));
    final records = await repository.list(tagUid: '04:A1:B2:C3');
    expect(records, hasLength(2));
    expect(records.first.model, 'PETG');
    expect(records.last.model, 'PLA');
    expect(records.first.verified, isFalse);
  });

  test('filters account history without mixing users', () async {
    await repository.recordScan(
      tagUid: 'CUID-1',
      ownerAccount: 'alice@example.com|cn',
      profile: 'ams',
      bytesRead: 16,
      verified: true,
    );
    await repository.recordScan(
      tagUid: 'CUID-2',
      ownerAccount: 'bob@example.com|cn',
      profile: 'ams',
    );

    final alice = await repository.list(ownerAccount: 'alice@example.com|cn');
    expect(alice, hasLength(1));
    expect(alice.single.tagUid, 'CUID-1');
    expect(await repository.count(ownerAccount: 'bob@example.com|cn'), 1);
  });

  test(
    'normalizes owner keys and keeps an explicit blank scope isolated',
    () async {
      await repository.recordScan(
        tagUid: 'BLANK-1',
        ownerAccount: '  Alice@Example.com|CN  ',
      );
      await repository.recordScan(
        tagUid: 'BLANK-2',
        ownerAccount: 'bob@example.com|cn',
      );
      await repository.recordScan(tagUid: 'BLANK-3');

      final alice = await repository.list(ownerAccount: 'alice@example.com|cn');
      expect(alice.map((record) => record.tagUid), contains('BLANK-1'));
      expect(alice, hasLength(1));

      final unclaimed = await repository.list(ownerAccount: '');
      expect(unclaimed.map((record) => record.tagUid), contains('BLANK-3'));
      expect(unclaimed, hasLength(1));

      // Omitting the filter remains an explicit diagnostic operation.
      expect(await repository.count(), 3);
    },
  );

  test('watch emits after a new operation', () async {
    final stream = repository.watch(ownerAccount: 'alice');
    final iterator = StreamIterator(stream);
    addTearDown(iterator.cancel);
    expect(await iterator.moveNext(), isTrue);
    expect(iterator.current, isEmpty);
    final next = iterator.moveNext();
    await repository.recordScan(
      tagUid: 'NTAG-1',
      ownerAccount: 'alice',
      profile: 'ntag213',
    );
    expect(await next, isTrue);
    expect(iterator.current.single.tagUid, 'NTAG-1');
  });

  test(
    'lists account-scoped inventory bindings for a fresh phone picker',
    () async {
      final timestamp = DateTime.fromMillisecondsSinceEpoch(2000);
      await database.consumableDao.upsertPersonalInventoryRecord(
        PersonalInventoryRecord(
          uid: 'synced-spool-1',
          manufacturer: 'eSUN',
          model: 'PLA+',
          materialType: 'PLA+',
          colorHex: '#E5484D',
          colorName: '珊瑚红',
          totalGrams: 1000,
          remainingGrams: 1000,
          createdAt: timestamp,
          updatedAt: timestamp,
          rfidTagUid: '04:AA:BB:CC',
          rfidTagType: 'CUID',
        ),
        ownerAccount: 'Alice@Example.com|Personal',
      );
      await database.consumableDao.upsertPersonalInventoryRecord(
        PersonalInventoryRecord(
          uid: 'foreign-spool-1',
          manufacturer: 'Other',
          model: 'PETG',
          materialType: 'PETG',
          colorHex: '#FFFFFF',
          totalGrams: 1000,
          remainingGrams: 1000,
          createdAt: timestamp,
          updatedAt: timestamp,
          rfidTagUid: '04:11:22:33',
          rfidTagType: 'FUID',
        ),
        ownerAccount: 'bob@example.com|personal',
      );
      await database.consumableDao.upsertPersonalInventoryRecord(
        PersonalInventoryRecord(
          uid: 'ntag-spool-1',
          manufacturer: 'Sohun',
          model: 'NTAG helper',
          materialType: 'NTAG helper',
          colorHex: '#000000',
          totalGrams: 1000,
          remainingGrams: 1000,
          createdAt: timestamp,
          updatedAt: timestamp,
          rfidTagUid: '04:99:88:77',
          rfidTagType: 'NTAG213',
        ),
        ownerAccount: 'alice@example.com|personal',
      );

      final rows = await repository.listInventoryTagBindings(
        ownerAccount: 'alice@example.com|personal',
      );
      expect(rows, hasLength(1));
      expect(rows.single.tagUid, '04AABBCC');
      expect(rows.single.brand, 'eSUN');
      expect(rows.single.model, 'PLA+');
      expect(rows.single.verified, isFalse);
      expect(rows.single.message, contains('同步库存'));
    },
  );

  test(
    'unknown and nonconsumable inventory types stay out of the tag picker',
    () async {
      final at = DateTime(2026, 9, 8);
      final types = <String?>[
        null,
        '',
        'CLASSIC',
        'NTAG213',
        'MIFARE Ultralight',
        'ams',
        'CUID',
        ' fuid ',
      ];
      for (var index = 0; index < types.length; index++) {
        await database.consumableDao.upsertPersonalInventoryRecord(
          PersonalInventoryRecord(
            uid: 'picker-$index',
            manufacturer: 'eSUN',
            model: 'PLA',
            materialType: 'PLA',
            colorHex: '#112233',
            totalGrams: 500,
            remainingGrams: 321,
            createdAt: at,
            updatedAt: at,
            rfidTagUid: '04AABB${index.toRadixString(16).padLeft(2, '0')}',
            rfidTagType: types[index],
          ),
        );
      }
      final candidates = await repository.listInventoryTagBindings(
        ownerAccount: '',
      );
      expect(candidates.map((row) => row.inventoryUid).toSet(), {
        'picker-6',
        'picker-7',
      });
      expect(
        await database.consumableDao.getPersonalForOwnerAccount(''),
        hasLength(types.length),
      );
    },
  );

  test(
    'retains NTAG operation history without making it a consumable template',
    () async {
      final at = DateTime(2026, 9, 8);
      final records = [
        RfidTagRecord(tagUid: '01', tagType: 'CUID', occurredAt: at),
        RfidTagRecord(tagUid: '02', tagType: 'FUID', occurredAt: at),
        RfidTagRecord(tagUid: '03', tagType: 'NTAG213', occurredAt: at),
        RfidTagRecord(
          tagUid: '04',
          tagType: 'CUID',
          profile: 'ntag213',
          occurredAt: at,
        ),
        RfidTagRecord(tagUid: '05', tagType: 'CLASSIC', occurredAt: at),
        RfidTagRecord(tagUid: '06', occurredAt: at),
        RfidTagRecord(
          tagUid: '07',
          tagType: 'CUID',
          technology: 'MIFARE_ULTRALIGHT',
          occurredAt: at,
        ),
      ];
      for (final record in records) {
        await repository.record(record);
      }
      final history = await repository.list();
      expect(history, hasLength(records.length));
      expect(
        history
            .where((row) => row.isConsumableTagRecord)
            .map((row) => row.tagUid)
            .toSet(),
        {'01', '02'},
      );
    },
  );

  test(
    'claims legacy owner keys case-insensitively without touching other users',
    () async {
      await repository.recordScan(
        tagUid: 'LEGACY-1',
        ownerAccount: 'legacy-local',
      );
      await repository.recordScan(
        tagUid: 'FOREIGN-1',
        ownerAccount: 'other@example.com|personal',
      );

      final claimed = await repository.claimOwnerAccount(
        ownerAccount: 'User@example.com|Personal',
        legacyOwnerAccounts: const [' LEGACY-LOCAL '],
      );
      expect(claimed, 1);
      expect(
        (await repository.list(
          ownerAccount: 'user@example.com|personal',
        )).single.tagUid,
        'LEGACY-1',
      );
      expect(
        (await repository.list(
          ownerAccount: 'other@example.com|personal',
        )).single.tagUid,
        'FOREIGN-1',
      );
    },
  );

  test('schema v47 creates the tag history table and indexes', () async {
    final table = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'rfid_tag_records'",
        )
        .getSingleOrNull();
    expect(table?.read<String>('name'), 'rfid_tag_records');
    final indexes = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name LIKE 'idx_rfid_tag_records_%'",
        )
        .get();
    expect(indexes.length, 3);
  });
}
