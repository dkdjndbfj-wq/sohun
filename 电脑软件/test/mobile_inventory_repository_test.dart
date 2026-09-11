import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase database;
  late MobileInventoryRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = MobileInventoryRepository(database.consumableDao);
  });

  tearDown(() => database.close());

  MobileConsumableDraft draft(String model) => MobileConsumableDraft(
    brand: 'eSUN',
    model: model,
    color: const Color(0xFF112233),
    colorName: '深蓝',
  );

  test('reuses an active spool without refilling it', () async {
    final first = await repository.addFromDraft(
      draft('PLA'),
      tagUid: '04:a1:b2:c3',
      tagType: 'CUID',
      ownerAccount: 'alice@example.com|personal',
    );
    final firstRow = await database.consumableDao.getPersonalByUid(
      first.inventoryUid,
      ownerAccount: 'alice@example.com|personal',
    );
    expect(firstRow, isNotNull);
    await database.consumableDao.adjustGrams(firstRow!.id, 400);

    final rewrite = await repository.addFromDraft(
      draft('PLA Matte'),
      tagUid: '04 A1 B2 C3',
      ownerAccount: 'alice@example.com|personal',
    );
    expect(rewrite.inventoryUid, first.inventoryUid);
    expect(rewrite.rfidTagCycle, 1);
    expect(rewrite.createdNewCycle, isFalse);

    final updated = await database.consumableDao.getById(firstRow.id);
    expect(updated!.remainingGrams, 600);
    final binding = await database.consumableDao.getRfidSpoolBindingById(
      firstRow.id,
    );
    expect(binding!.tagUid, '04A1B2C3');
    expect(binding.cycle, 1);
  });

  for (final grams in [500.0, 1000.0]) {
    test(
      'registers a $grams g CUID roll and rescan preserves exact balance',
      () async {
        final saved = await repository.addFromDraft(
          draft('PLA'),
          tagUid: '04A1B2C3',
          tagType: 'CUID',
          initialGrams: grams,
        );
        final row = (await database.consumableDao.getPersonalByUid(
          saved.inventoryUid,
        ))!;
        expect(row.totalGrams, 1000);
        expect(row.remainingGrams, grams);
        await database.consumableDao.adjustGrams(row.id, 123.45);
        final rescanned = await repository.addFromDraft(
          draft('PLA'),
          tagUid: '04:a1:b2:c3',
          tagType: 'CUID',
          initialGrams: 1000,
        );
        final unchanged = (await database.consumableDao.getById(row.id))!;
        expect(rescanned.inventoryUid, saved.inventoryUid);
        expect(unchanged.totalGrams, 1000);
        expect(unchanged.remainingGrams, closeTo(grams - 123.45, 0.00001));
        expect(
          await database.consumableDao.getPersonalRfidSpoolHistory('04A1B2C3'),
          hasLength(1),
        );
      },
    );
  }

  for (final grams in [30.0, 1001.0, 2000.0, double.infinity, double.nan]) {
    test(
      'rejects $grams g at a new mobile CUID entry without creating stock',
      () async {
        await expectLater(
          repository.addFromDraft(
            draft('PLA'),
            tagUid: '04A1B2C3',
            tagType: 'CUID',
            initialGrams: grams,
          ),
          throwsA(anyOf(isA<ArgumentError>(), isA<StateError>())),
        );
        expect(await database.consumableDao.getPersonal(), isEmpty);
      },
    );
  }

  test(
    'requires an explicit replacement after depletion and keeps the old row',
    () async {
      const owner = 'alice@example.com|personal';
      final first = await repository.addFromDraft(
        draft('PLA'),
        tagUid: 'CUID-REUSE-1',
        tagType: 'FUID',
        ownerAccount: owner,
      );
      final firstRow = await database.consumableDao.getPersonalByUid(
        first.inventoryUid,
        ownerAccount: owner,
      );
      await database.consumableDao.adjustGrams(firstRow!.id, 1000);

      final emptyScan = await repository.addFromDraft(
        draft('PLA'),
        tagUid: 'CUID-REUSE-1',
        ownerAccount: owner,
      );
      expect(emptyScan.inventoryUid, first.inventoryUid);
      expect(emptyScan.createdNewCycle, isFalse);
      expect(
        (await database.consumableDao.getById(firstRow.id))!.remainingGrams,
        0,
      );

      final second = await repository.addFromDraft(
        draft('PLA'),
        tagUid: 'cuid-reuse-1',
        ownerAccount: owner,
        forceNewCycle: true,
        expectedInventoryUid: first.inventoryUid,
      );
      expect(second.inventoryUid, isNot(first.inventoryUid));
      expect(second.rfidTagCycle, 2);
      expect(second.createdNewCycle, isTrue);

      final oldBinding = await database.consumableDao.getRfidSpoolBindingById(
        firstRow.id,
      );
      final newRow = await database.consumableDao.getPersonalByUid(
        second.inventoryUid,
        ownerAccount: owner,
      );
      expect(newRow, isNotNull);
      final confirmedRow = newRow!;
      final confirmedOldBinding = oldBinding!;
      final newBinding = await database.consumableDao.getRfidSpoolBindingById(
        confirmedRow.id,
      );
      final confirmedBinding = newBinding!;
      expect(confirmedOldBinding.status, 'depleted');
      expect(confirmedBinding.status, 'active');
      expect(confirmedBinding.previousInventoryUid, first.inventoryUid);
      expect(
        (await database.consumableDao.getPersonalRfidSpoolHistory(
          'CUID-REUSE-1',
          ownerAccount: owner,
        )),
        hasLength(2),
      );

      // A later metadata refresh of the active second cycle must retain the
      // predecessor pointer instead of silently breaking the lifecycle chain.
      await repository.addFromDraft(
        draft('PLA Matte'),
        tagUid: 'CUID-REUSE-1',
        ownerAccount: owner,
      );
      final refreshed = await database.consumableDao.getRfidSpoolBindingById(
        confirmedRow.id,
      );
      expect(refreshed!.previousInventoryUid, first.inventoryUid);

      final third = await repository.addFromDraft(
        draft('PLA'),
        tagUid: 'CUID-REUSE-1',
        ownerAccount: owner,
        forceNewCycle: true,
        initialGrams: 750,
        expectedInventoryUid: second.inventoryUid,
      );
      expect(third.rfidTagCycle, 3);
      final thirdRow = await database.consumableDao.getPersonalByUid(
        third.inventoryUid,
        ownerAccount: owner,
      );
      expect(thirdRow!.totalGrams, 1000);
      expect(thirdRow.remainingGrams, 750);
      await expectLater(
        repository.addFromDraft(
          draft('PLA'),
          tagUid: 'CUID-REUSE-1',
          ownerAccount: owner,
          forceNewCycle: true,
          expectedInventoryUid: second.inventoryUid,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'copied tag UIDs remain separate per account and anonymous reads cannot adopt them',
    () async {
      final alice = await repository.addFromDraft(
        draft('PLA'),
        tagUid: 'CUID-OWNER-1',
        tagType: 'CUID',
        ownerAccount: 'alice@example.com|personal',
      );
      final bob = await repository.addFromDraft(
        draft('PLA'),
        tagUid: 'CUID-OWNER-1',
        tagType: 'CUID',
        ownerAccount: 'bob@example.com|personal',
      );
      expect(bob.inventoryUid, isNot(alice.inventoryUid));
      expect(
        (await database.consumableDao.getPersonalForOwnerAccount(
          'alice@example.com|personal',
        )).single.uid,
        alice.inventoryUid,
      );
      expect(
        (await database.consumableDao.getPersonalForOwnerAccount(
          'bob@example.com|personal',
        )).single.uid,
        bob.inventoryUid,
      );
      await expectLater(
        repository.addFromDraft(draft('PLA'), tagUid: 'CUID-OWNER-1'),
        throwsA(isA<MobileInventoryTagOwnershipException>()),
      );
    },
  );

  Future<int> legacySpool(String? type, {String uid = 'legacy-spool'}) {
    final at = DateTime(2026, 9, 8);
    return database.consumableDao.upsertPersonalInventoryRecord(
      PersonalInventoryRecord(
        uid: uid,
        manufacturer: 'eSUN',
        model: 'PLA',
        materialType: 'PLA',
        colorHex: '#112233',
        totalGrams: 1000,
        remainingGrams: 321,
        createdAt: at,
        updatedAt: at,
        rfidTagUid: '04A1B2C3',
        rfidTagType: type,
      ),
    );
  }

  for (final type in <String?>[
    'NTAG213',
    'NTAG215',
    'MIFARE Ultralight',
    'ams',
    'CLASSIC',
    'NTAG213 CUID',
    null,
  ]) {
    test(
      'rejects unconfirmed or nonconsumable card $type at first entry',
      () async {
        await expectLater(
          repository.addFromDraft(
            draft('PLA'),
            tagUid: '04A1B2C3',
            tagType: type,
          ),
          throwsA(isA<MobileInventoryTagTypeException>()),
        );
        expect(
          await database.consumableDao.getPersonalForOwnerAccount(''),
          isEmpty,
        );
      },
    );
  }

  test(
    'an NTAG entry cannot bypass the boundary by omitting its UID',
    () async {
      await expectLater(
        repository.addFromDraft(draft('PLA'), tagType: 'NTAG213'),
        throwsA(isA<MobileInventoryTagTypeException>()),
      );
    },
  );

  test('keeps ordinary manual inventory without a tag', () async {
    final saved = await repository.addFromDraft(
      draft('PLA'),
      initialGrams: 500,
    );
    final row = (await database.consumableDao.getPersonalByUid(
      saved.inventoryUid,
    ))!;
    expect(row.totalGrams, 1000);
    expect(saved.rfidTagUid, isNull);
    final binding = (await database.consumableDao.getRfidSpoolBindingById(
      row.id,
    ))!;
    expect(binding.tagUid, isEmpty);
    expect(binding.tagType, isNull);
  });

  for (final type in ['NTAG213', 'MIFARE Ultralight', 'ams']) {
    test(
      'retains $type history while blocking metadata and replacement mutations',
      () async {
        final id = await legacySpool(type);
        for (final forced in [false, true]) {
          for (final requested in <String?>[null, 'CUID']) {
            await expectLater(
              repository.addFromDraft(
                draft('PETG'),
                tagUid: '04A1B2C3',
                tagType: requested,
                forceNewCycle: forced,
              ),
              throwsA(isA<MobileInventoryTagTypeException>()),
            );
          }
        }
        final row = (await database.consumableDao.getById(id))!;
        expect(row.model, 'PLA');
        expect(row.remainingGrams, 321);
        final history = await database.consumableDao
            .getPersonalRfidSpoolHistory('04A1B2C3');
        expect(history, hasLength(1));
        expect(history.single.tagType, type);
        expect(history.single.cycle, 1);
      },
    );
  }

  for (final type in <String?>[null, 'CLASSIC']) {
    test(
      'legacy $type requires explicit card confirmation without refilling',
      () async {
        final id = await legacySpool(type);
        await expectLater(
          repository.addFromDraft(draft('PETG'), tagUid: '04A1B2C3'),
          throwsA(isA<MobileInventoryTagTypeException>()),
        );
        final confirmed = await repository.addFromDraft(
          draft('PLA'),
          tagUid: '04A1B2C3',
          tagType: ' fuid ',
        );
        expect(confirmed.inventoryUid, 'legacy-spool');
        expect((await database.consumableDao.getById(id))!.remainingGrams, 321);
        expect(
          (await database.consumableDao.getRfidSpoolBindingById(id))!.tagType,
          'FUID',
        );
        final next = await repository.addFromDraft(
          draft('PLA'),
          tagUid: '04A1B2C3',
          forceNewCycle: true,
          initialGrams: 500,
        );
        expect(next.rfidTagCycle, 2);
        expect(next.inventoryUid, isNot(confirmed.inventoryUid));
        expect((await database.consumableDao.getById(id))!.remainingGrams, 321);
      },
    );
  }

  test(
    'confirmation is retained when replacing an untyped historical spool',
    () async {
      final id = await legacySpool(null);
      final next = await repository.addFromDraft(
        draft('PLA'),
        tagUid: '04A1B2C3',
        tagType: 'CUID',
        forceNewCycle: true,
      );
      final history = await database.consumableDao.getPersonalRfidSpoolHistory(
        '04A1B2C3',
      );
      expect(history, hasLength(2));
      expect(history.map((binding) => binding.tagType), everyElement('CUID'));
      expect(history.first.inventoryUid, next.inventoryUid);
      expect((await database.consumableDao.getById(id))!.remainingGrams, 321);
    },
  );
}
