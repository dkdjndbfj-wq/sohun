import 'package:consumable_tracker_desktop/core/services/consumable_twin_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/consumable_twin_event.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/models/rfid_tag_identity.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_repository.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late MobileInventoryRepository inventory;
  late int printerId;
  final draft = MobileConsumableDraft(
    brand: 'eSUN',
    model: 'PLA',
    color: Colors.blue,
    colorName: '蓝色',
  );
  const tag = '04:A1:B2:C3';
  AmsTray tray({int slot = 0, String tagUid = tag, String trayUuid = ''}) =>
      AmsTray(
        amsId: 0,
        slot: slot,
        tagUid: tagUid,
        trayUuid: trayUuid,
        trayTag: 'thirdparty',
        hasFilament: true,
        trayWeight: 1000,
        remain: 90,
      );
  Future<void> sync(List<AmsTray> trays) => db.printerDao.syncChannelsFromAms(
    printerId,
    trays,
    autoBindRfid: true,
    unbindEmpty: false,
  );
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    inventory = MobileInventoryRepository(db.consumableDao);
    printerId = await db
        .into(db.printers)
        .insert(
          PrintersCompanion.insert(
            brand: 'Bambu',
            model: 'P1S',
            channelCount: const Value(2),
          ),
        );
  });
  tearDown(() => db.close());

  test(
    'after retagging, AMS restores the leftover and successor to separate slots',
    () async {
      final first = await inventory.addFromDraft(
        draft,
        tagUid: tag,
        tagType: 'CUID',
      );
      final old = (await db.consumableDao.getPersonalByUid(
        first.inventoryUid,
      ))!;
      await db.consumableDao.adjustGrams(old.id, 750);
      final next = await db.consumableDao.replacePersonalRfidSpool(
        consumableId: old.id,
        initialGrams: 750,
      );
      await db.consumableDao.rebindPersonalRfidSpool(
        consumableId: old.id,
        expectedTagUid: tag,
        newTagUid: '04BB0002',
        newTagType: 'FUID',
        ownerAccount: null,
      );
      await sync([tray(slot: 0), tray(slot: 1, tagUid: '04BB0002')]);
      expect(
        await db.printerDao.getConsumableIdByChannel(printerId, 0),
        next.consumableId,
      );
      expect(
        await db.printerDao.getConsumableIdByChannel(printerId, 1),
        old.id,
      );
      expect((await db.consumableDao.getById(old.id))!.remainingGrams, 250);
      expect(
        (await db.consumableDao.getById(next.consumableId))!.remainingGrams,
        750,
      );
    },
  );

  test(
    'same tag replacement has separate stock, position, and usage ledgers',
    () async {
      final first = await inventory.addFromDraft(
        draft,
        tagUid: tag,
        tagType: 'CUID',
      );
      final old = (await db.consumableDao.getPersonalByUid(
        first.inventoryUid,
      ))!;
      await db.consumableDao.adjustGrams(old.id, 280);
      await db.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(old.id),
          printerId: Value(printerId),
          consumedGrams: const Value(280),
        ),
      );
      await sync([tray()]);
      final twin = ConsumableTwinService(db);
      await twin.handleAmsTrays(
        printerId: printerId,
        printerSerial: 'RFID-TEST',
        trays: [tray()],
      );
      expect((await db.consumableDao.getById(old.id))!.remainingGrams, 720);

      final second = await inventory.addFromDraft(
        draft,
        tagUid: tag,
        forceNewCycle: true,
        expectedInventoryUid: old.uid,
        initialGrams: 750,
      );
      final next = (await db.consumableDao.getPersonalByUid(
        second.inventoryUid,
      ))!;
      await sync([tray()]);
      expect(
        await db.printerDao.getConsumableIdByChannel(printerId, 0),
        next.id,
      );
      expect((await db.consumableDao.getById(next.id))!.remainingGrams, 750);
      await db.consumableDao.adjustGrams(next.id, 50);
      await db.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(next.id),
          printerId: Value(printerId),
          consumedGrams: const Value(50),
        ),
      );
      await twin.handleAmsTrays(
        printerId: printerId,
        printerSerial: 'RFID-TEST',
        trays: [tray()],
      );
      await db.consumableDao.updateRfidSync(
        consumableId: old.id,
        remainingGrams: 999,
      );
      expect((await db.consumableDao.getById(old.id))!.remainingGrams, 720);
      expect((await db.consumableDao.getById(next.id))!.remainingGrams, 700);
      expect(
        (await db.usageLogDao.getForConsumable(old.id)).single.consumedGrams,
        280,
      );
      expect(
        (await db.usageLogDao.getForConsumable(next.id)).single.consumedGrams,
        50,
      );
      final oldEvents = await twin.getTimeline(rfidSpoolLedgerKey(old.uid));
      final newEvents = await twin.getTimeline(rfidSpoolLedgerKey(next.uid));
      expect(oldEvents.map((e) => e.consumableId).toSet(), {old.id});
      expect(newEvents.map((e) => e.consumableId).toSet(), {next.id});
      expect(
        oldEvents.any((e) => e.eventType == TwinEventType.removed),
        isTrue,
      );
      expect(
        newEvents.any((e) => e.eventType == TwinEventType.discovered),
        isTrue,
      );
      await expectLater(db.consumableDao.addOneRoll(next.id), throwsStateError);
    },
  );

  test('physical tag takes priority over a cloned material payload', () async {
    final result = await inventory.addFromDraft(
      draft,
      tagUid: tag,
      tagType: 'CUID',
    );
    final item = (await db.consumableDao.getPersonalByUid(
      result.inventoryUid,
    ))!;
    await db.consumableDao.updateTrayUuid(item.id, 'shared-template');
    await sync([tray(tagUid: '04:99:88:77', trayUuid: 'shared-template')]);
    expect(await db.printerDao.getConsumableIdByChannel(printerId, 0), isNull);
  });

  test(
    'a registered CUID with a Bambu payload cannot overwrite its stock',
    () async {
      final result = await inventory.addFromDraft(
        draft,
        tagUid: tag,
        tagType: 'CUID',
        initialGrams: 750,
      );
      const copied = AmsTray(
        amsId: 0,
        slot: 0,
        tagUid: tag,
        trayUuid: 'copied-bambu',
        traySubBrands: 'Bambu',
        trayInfoIdx: 'GFA00',
        hasFilament: true,
        trayWeight: 1000,
        remain: 95,
      );
      expect(copied.isBambuOfficialRfid, isTrue);
      await sync([copied]);
      final item = (await db.consumableDao.getPersonalByUid(
        result.inventoryUid,
      ))!;
      await ConsumableTwinService(db).handleAmsTrays(
        printerId: printerId,
        printerSerial: 'COPY-TEST',
        trays: [copied],
      );
      expect((await db.consumableDao.getById(item.id))!.remainingGrams, 750);
      expect(
        await db.printerDao.getConsumableIdByChannel(printerId, 0),
        item.id,
      );
    },
  );

  test(
    'two simultaneous cloned tags are not automatically assigned one roll',
    () async {
      await inventory.addFromDraft(draft, tagUid: tag, tagType: 'CUID');
      await sync([tray(), tray(slot: 1)]);
      expect(
        await db.printerDao.getConsumableIdByChannel(printerId, 0),
        isNull,
      );
      expect(
        await db.printerDao.getConsumableIdByChannel(printerId, 1),
        isNull,
      );
      final twin = ConsumableTwinService(db);
      await twin.handleAmsTrays(
        printerId: printerId,
        printerSerial: 'CLONE-TEST',
        trays: [tray(), tray(slot: 1)],
      );
      expect(
        await twin.getCurrentState(
          rfidSpoolLedgerKey(
            (await db.consumableDao.getAnyPersonalByRfidTagUid(tag))!.uid,
          ),
        ),
        isNull,
      );
    },
  );

  test('a registered 2kg roll remains one physical spool', () async {
    final result = await inventory.addFromDraft(
      draft,
      tagUid: tag,
      initialGrams: 2000,
      tagType: 'CUID',
    );
    final item = (await db.consumableDao.getPersonalByUid(
      result.inventoryUid,
    ))!;
    await sync([tray(), const AmsTray(amsId: 0, slot: 1, hasFilament: true)]);
    final printer = (await db.printerDao.getByIdWithChannels(printerId))!;
    final first = printer.channels.first.channel;
    expect(first.loadedRemainingGrams, 2000);
    await expectLater(
      db.printerDao.bindConsumable(printer.channels.last.channel.id, item.id),
      throwsStateError,
    );
  });
}
