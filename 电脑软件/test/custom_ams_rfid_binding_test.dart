import 'package:consumable_tracker_desktop/core/services/consumable_twin_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/consumable_twin_event.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the physical AMS tag_uid separately from tray_uuid', () {
    final trays = AmsTray.parseList({
      'ams_exist_bits': '1',
      'tray_exist_bits': '1',
      'ams': [
        {
          'id': '0',
          'tray': [
            {
              'tag_uid': '04:a1:b2:c3:d4:e5:f6:07',
              'tray_uuid': '11111111-2222-3333-4444-555555555555',
              'tray_tag': 'thirdparty',
            },
          ],
        },
      ],
    });

    expect(trays.single.tagUid, '04:a1:b2:c3:d4:e5:f6:07');
    expect(trays.single.normalizedTagUid, '04A1B2C3D4E5F607');
    expect(
      trays.single.normalizedTrayUuid,
      '11111111222233334444555555555555',
    );
    expect(trays.single.physicalRfidIdentity, '04A1B2C3D4E5F607');
    expect(trays.single.rfidIdentityCandidates, [
      '04A1B2C3D4E5F607',
      '11111111222233334444555555555555',
    ]);
  });

  test('AMS RFID identity is available for a third-party tray', () {
    const custom = AmsTray(
      amsId: 0,
      slot: 0,
      trayTag: 'thirdparty',
      traySubBrands: 'eSUN',
      trayUuid: '  custom-uuid  ',
      hasFilament: true,
    );
    const untagged = AmsTray(amsId: 0, slot: 0, hasFilament: true);
    const zeroUuid = AmsTray(
      amsId: 0,
      slot: 1,
      trayUuid: '00000000000000000000000000000000',
      hasFilament: true,
    );
    const external = AmsTray(
      amsId: -1,
      slot: 0,
      trayUuid: 'external-uuid',
      hasFilament: true,
    );

    expect(custom.isBambuOfficialRfid, isFalse);
    expect(custom.hasAmsRfidIdentity, isTrue);
    expect(untagged.hasAmsRfidIdentity, isFalse);
    expect(zeroUuid.hasAmsRfidIdentity, isFalse);
    expect(external.hasAmsRfidIdentity, isFalse);
  });

  test('a bound third-party RFID tray is restored to its AMS channel',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final printerId = await db.into(db.printers).insert(
          PrintersCompanion.insert(
            brand: '拓竹',
            model: 'P1S',
            channelCount: const Value(1),
          ),
        );
    final consumableId = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'eSUN',
        model: 'PETG+',
        materialType: const Value('PETG'),
        colorHex: const Value('#22AAFF'),
        totalGrams: const Value(1000),
        remainingGrams: const Value(720),
      ),
    );
    await db.consumableDao.updateTrayUuid(consumableId, 'custom-uuid');

    await db.printerDao.syncChannelsFromAms(
      printerId,
      const [
        AmsTray(
          amsId: 0,
          slot: 0,
          trayType: 'PETG',
          trayColor: '22AAFFFF',
          traySubBrands: 'eSUN',
          trayTag: 'thirdparty',
          trayUuid: 'custom-uuid',
          trayWeight: 1000,
          remain: 60,
          hasFilament: true,
        ),
      ],
      autoBindRfid: true,
      unbindEmpty: false,
    );

    final channel = await db.printerDao.getByIdWithChannels(printerId);
    expect(channel!.channels.single.channel.consumableId, consumableId);
    // The channel stores the local loaded-roll baseline. RFID remain is
    // synchronized to the personal inventory record below.
    expect(channel.channels.single.channel.loadedRemainingGrams, 720);
    expect((await db.consumableDao.getById(consumableId))!.remainingGrams, 600);
    expect(
      await db.select(db.consumables).get().then((rows) => rows.length),
      1,
    );
  });

  test('a bound third-party tray can match physical tag_uid without tray_uuid',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final printerId = await db.into(db.printers).insert(
          PrintersCompanion.insert(
            brand: '拓竹',
            model: 'P1S',
            channelCount: const Value(1),
          ),
        );
    final consumableId = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'eSUN',
        model: 'PETG+',
        materialType: const Value('PETG'),
        colorHex: const Value('#22AAFF'),
        totalGrams: const Value(1000),
        remainingGrams: const Value(720),
      ),
    );
    await db.consumableDao.setRfidSpoolBinding(
      consumableId,
      tagUid: '04:a1:b2:c3',
      tagType: 'cuid',
      cycle: 1,
      status: 'active',
    );

    await db.printerDao.syncChannelsFromAms(
      printerId,
      const [
        AmsTray(
          amsId: 0,
          slot: 0,
          trayType: 'PETG',
          trayColor: '22AAFFFF',
          traySubBrands: 'eSUN',
          trayTag: 'thirdparty',
          tagUid: '04:A1:B2:C3',
          trayWeight: 1000,
          remain: 60,
          hasFilament: true,
        ),
      ],
      autoBindRfid: true,
      unbindEmpty: false,
    );

    expect(await db.printerDao.getConsumableIdByChannel(printerId, 0),
        consumableId);
    // A reusable tag is an identity, not a trustworthy absolute scale.
    expect((await db.consumableDao.getById(consumableId))!.remainingGrams, 720);
  });

  test('an unknown third-party RFID UUID is not auto-created or fuzzy-bound',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final printerId = await db.into(db.printers).insert(
          PrintersCompanion.insert(
            brand: '拓竹',
            model: 'P1S',
            channelCount: const Value(1),
          ),
        );
    final existingId = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'eSUN',
        model: 'PETG+',
        materialType: const Value('PETG'),
        colorHex: const Value('#22AAFF'),
        totalGrams: const Value(1000),
        remainingGrams: const Value(720),
      ),
    );

    await db.printerDao.syncChannelsFromAms(
      printerId,
      const [
        AmsTray(
          amsId: 0,
          slot: 0,
          trayType: 'PETG',
          trayColor: '22AAFFFF',
          traySubBrands: 'eSUN',
          trayTag: 'thirdparty',
          trayUuid: 'unknown-uuid',
          trayInfoIdx: 'PETG+',
          trayWeight: 1000,
          remain: 60,
          hasFilament: true,
        ),
      ],
      autoBindRfid: true,
      unbindEmpty: false,
    );

    expect(await db.printerDao.getConsumableIdByChannel(printerId, 0), isNull);
    expect(await db.consumableDao.getById(existingId), isNotNull);
    expect(
      await db.select(db.consumables).get().then((rows) => rows.length),
      1,
    );
  });

  test('bound third-party RFID remain is recorded and adopted by the twin',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.customStatement(
      "INSERT INTO printers(id, brand, model, serial) "
      "VALUES (1, '拓竹', 'P1S', 'CUSTOM-RFID-PRINTER')",
    );
    final consumableId = await db.customInsert(
      "INSERT INTO consumables(manufacturer, model, material_type, color_hex, "
      "total_grams, remaining_grams, tray_uuid) "
      "VALUES ('eSUN', 'PETG+', 'PETG', '#22AAFF', 1000, 720, 'custom-uuid')",
    );
    final service = ConsumableTwinService(db);

    await service.handleAmsTrays(
      printerId: 1,
      printerSerial: 'CUSTOM-RFID-PRINTER',
      trays: const [
        AmsTray(
          amsId: 0,
          slot: 0,
          trayType: 'PETG',
          trayColor: '22AAFFFF',
          traySubBrands: 'eSUN',
          trayTag: 'thirdparty',
          trayUuid: 'custom-uuid',
          trayWeight: 1000,
          remain: 42,
          hasFilament: true,
        ),
      ],
    );

    expect((await db.consumableDao.getById(consumableId))!.remainingGrams, 420);
    final events = await service.getTimeline('custom-uuid');
    expect(
      events.any((event) => event.eventType == TwinEventType.rfidObserved),
      isTrue,
    );
  });
}
