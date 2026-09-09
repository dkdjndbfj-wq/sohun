import 'package:consumable_tracker_desktop/core/services/consumable_twin_service.dart';
import 'package:consumable_tracker_desktop/core/services/spool_change_detector.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/personal_ams_identity.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/features/printers/personal_spool_removal_dialog.dart';
import 'package:consumable_tracker_desktop/providers/spool_change_provider.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('personal maintenance pause preserves binding and every gram', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final printerId = await db
        .into(db.printers)
        .insert(
          PrintersCompanion.insert(
            brand: '拓竹',
            model: 'P1S',
            channelCount: const Value(1),
          ),
        );
    final consumableId = await db.consumableDao.addConsumable(
      ConsumablesCompanion.insert(
        manufacturer: 'eSUN',
        model: 'PLA+',
        materialType: const Value('PLA'),
        remainingGrams: const Value(640),
        totalGrams: const Value(1000),
      ),
    );
    final channelId = await db
        .into(db.printerChannels)
        .insert(
          PrinterChannelsCompanion.insert(
            printerId: printerId,
            channelIndex: 0,
            consumableId: Value(consumableId),
            loadedRemainingGrams: const Value(1000),
          ),
        );

    await db.printerDao.syncChannelsFromAms(
      printerId,
      const [AmsTray(amsId: 0, slot: 0, hasFilament: false)],
      autoBindRfid: false,
      unbindEmpty: false,
    );
    final preservedAfterPhysicalRemoval =
        (await db.printerDao.getByIdWithChannels(printerId))!.channels.single;
    expect(preservedAfterPhysicalRemoval.channel.consumableId, consumableId);
    expect(preservedAfterPhysicalRemoval.consumable!.remainingGrams, 640);

    await db.printerDao.pauseChannelRollForMaintenance(channelId);

    final paused = (await db.printerDao.getByIdWithChannels(
      printerId,
    ))!.channels.single;
    expect(paused.farmRollPaused, isTrue);
    expect(paused.channel.consumableId, consumableId);
    expect(paused.channel.loadedRemainingGrams, 1000);
    expect(paused.consumable!.remainingGrams, 640);
    expect(await db.select(db.usageLogs).get(), isEmpty);
    await expectLater(
      db.printerDao.finishChannel(channelId),
      throwsA(isA<StateError>()),
    );

    await db.printerDao.resumeChannelRollAfterMaintenance(channelId);

    final resumed = (await db.printerDao.getByIdWithChannels(
      printerId,
    ))!.channels.single;
    expect(resumed.farmRollPaused, isFalse);
    expect(resumed.channel.consumableId, consumableId);
    expect(resumed.consumable!.remainingGrams, 640);
    expect(await db.select(db.usageLogs).get(), isEmpty);
  });

  test(
    'confirmed detected removal returns a paused partial spool without consuming it',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final printerId = await db
          .into(db.printers)
          .insert(
            PrintersCompanion.insert(
              brand: '拓竹',
              model: 'P1S',
              channelCount: const Value(1),
            ),
          );
      final consumableId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'eSUN',
          model: 'PLA+',
          materialType: const Value('PLA'),
          remainingGrams: const Value(415),
          totalGrams: const Value(1000),
        ),
      );
      final channelId = await db
          .into(db.printerChannels)
          .insert(
            PrinterChannelsCompanion.insert(
              printerId: printerId,
              channelIndex: 0,
              consumableId: Value(consumableId),
              loadedRemainingGrams: const Value(415),
            ),
          );
      await db.printerDao.pauseChannelRollForMaintenance(channelId);

      await db.printerDao.unbindChannel(
        channelId,
        confirmDetectedRemoval: true,
      );

      final returned = await db.consumableDao.getById(consumableId);
      final channel = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      expect(returned!.remainingGrams, 415);
      expect(channel.channel.consumableId, isNull);
      expect(channel.channel.loadedRemainingGrams, 0);
      expect(channel.farmRollPaused, isFalse);
      expect(await db.select(db.usageLogs).get(), isEmpty);
    },
  );

  test(
    'stale detected-removal actions cannot clear the newly loaded spool',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final printerId = await db
          .into(db.printers)
          .insert(
            PrintersCompanion.insert(
              brand: '拓竹',
              model: 'P1S',
              channelCount: const Value(1),
            ),
          );
      final oldId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'eSUN',
          model: 'old',
          remainingGrams: const Value(415),
        ),
      );
      final newId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'eSUN',
          model: 'new',
          remainingGrams: const Value(900),
        ),
      );
      final channelId = await db
          .into(db.printerChannels)
          .insert(
            PrinterChannelsCompanion.insert(
              printerId: printerId,
              channelIndex: 0,
              consumableId: Value(oldId),
              loadedRemainingGrams: const Value(415),
            ),
          );
      await db.printerDao.pauseChannelRollForMaintenance(channelId);
      await db.customUpdate(
        'UPDATE printer_channels SET consumable_id = ?, '
        'loaded_remaining_grams = 900, farm_roll_paused = 0 WHERE id = ?',
        variables: [Variable(newId), Variable(channelId)],
      );

      await expectLater(
        db.printerDao.unbindChannel(
          channelId,
          confirmDetectedRemoval: true,
          expectedConsumableId: oldId,
        ),
        throwsStateError,
      );
      await expectLater(
        db.printerDao.finishChannel(channelId, expectedConsumableId: oldId),
        throwsStateError,
      );

      final channel = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      expect(channel.channel.consumableId, newId);
      expect(channel.consumable!.remainingGrams, 900);
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 415);
      expect(await db.select(db.usageLogs).get(), isEmpty);
    },
  );

  test(
    'reinserted official RFID roll automatically resumes maintenance state',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final printerId = await db
          .into(db.printers)
          .insert(
            PrintersCompanion.insert(
              brand: '拓竹',
              model: 'P1S',
              channelCount: const Value(1),
            ),
          );
      final consumableId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Bambu',
          model: 'GFA00',
          materialType: const Value('PLA'),
          colorHex: const Value('#000000'),
          remainingGrams: const Value(640),
          totalGrams: const Value(1000),
        ),
      );
      await db.consumableDao.updateTrayUuid(consumableId, 'rfid-original');
      final channelId = await db
          .into(db.printerChannels)
          .insert(
            PrinterChannelsCompanion.insert(
              printerId: printerId,
              channelIndex: 0,
              consumableId: Value(consumableId),
              loadedRemainingGrams: const Value(640),
            ),
          );
      await db.printerDao.pauseChannelRollForMaintenance(channelId);
      final frozenUuids = await db.printerDao.getMaintenancePausedTrayUuids(
        printerId,
      );
      expect(frozenUuids, {'rfid-original'});

      await db.printerDao.syncChannelsFromAms(
        printerId,
        const [
          AmsTray(
            amsId: 0,
            slot: 0,
            trayUuid: 'rfid-original',
            trayInfoIdx: 'GFA00',
            traySubBrands: 'Bambu Lab',
            trayType: 'PLA',
            trayColor: '000000FF',
            trayWeight: 1000,
            remain: 20,
            hasFilament: true,
          ),
        ],
        autoBindRfid: true,
        unbindEmpty: false,
      );

      // 通道恢复后 MQTT 仍会持续上报 RFID 百分比。数字孪生记录观测事实，
      // 但维修冻结集合必须阻止 20% 取整读数覆盖精确的 640g。
      final twinService = ConsumableTwinService(db);
      await twinService.handleAmsTrays(
        printerId: printerId,
        printerSerial: 'RFID-MAINTENANCE',
        trays: const [
          AmsTray(
            amsId: 0,
            slot: 0,
            trayUuid: 'rfid-original',
            trayInfoIdx: 'GFA00',
            traySubBrands: 'Bambu Lab',
            trayType: 'PLA',
            trayColor: '000000FF',
            trayWeight: 1000,
            remain: 20,
            hasFilament: true,
          ),
        ],
        preserveObservedRemainFor: frozenUuids,
      );

      final resumed = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      expect(resumed.farmRollPaused, isFalse);
      expect(resumed.channel.consumableId, consumableId);
      expect(resumed.consumable!.remainingGrams, 640);
    },
  );

  test(
    'maintenance RFID roll moved to another slot keeps exact frozen grams',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final printerId = await db.printerDao.addPrinter(
        brand: '拓竹',
        model: 'P1S',
        channelCount: 2,
      );
      final consumableId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Bambu',
          model: 'GFA00',
          materialType: const Value('PLA'),
          colorHex: const Value('#000000'),
          remainingGrams: const Value(640),
          totalGrams: const Value(1000),
        ),
      );
      await db.consumableDao.updateTrayUuid(consumableId, 'rfid-moved');
      final before = await db.printerDao.getByIdWithChannels(printerId);
      final oldChannel = before!.channels
          .firstWhere((item) => item.channel.channelIndex == 0)
          .channel;
      await db.printerDao.bindConsumable(oldChannel.id, consumableId);
      await db.printerDao.pauseChannelRollForMaintenance(oldChannel.id);

      await db.printerDao.syncChannelsFromAms(
        printerId,
        const [
          AmsTray(amsId: 0, slot: 0, hasFilament: false),
          AmsTray(
            amsId: 0,
            slot: 1,
            trayUuid: 'rfid-moved',
            trayInfoIdx: 'GFA00',
            traySubBrands: 'Bambu Lab',
            trayType: 'PLA',
            trayColor: '000000FF',
            trayWeight: 1000,
            remain: 20,
            hasFilament: true,
          ),
        ],
        autoBindRfid: true,
        unbindEmpty: false,
      );

      final after = await db.printerDao.getByIdWithChannels(printerId);
      final oldSlot = after!.channels.firstWhere(
        (item) => item.channel.channelIndex == 0,
      );
      final newSlot = after.channels.firstWhere(
        (item) => item.channel.channelIndex == 1,
      );
      expect(oldSlot.channel.consumableId, isNull);
      expect(oldSlot.farmRollPaused, isFalse);
      expect(newSlot.channel.consumableId, consumableId);
      expect(newSlot.farmRollPaused, isFalse);
      expect(newSlot.consumable!.remainingGrams, 640);
    },
  );

  test(
    'active RFID roll moved to another slot adopts the observed grams',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final printerId = await db.printerDao.addPrinter(
        brand: '拓竹',
        model: 'P1S',
        channelCount: 2,
      );
      final consumableId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Bambu',
          model: 'GFA00',
          materialType: const Value('PLA'),
          colorHex: const Value('#000000'),
          remainingGrams: const Value(700),
          totalGrams: const Value(1000),
        ),
      );
      await db.consumableDao.updateTrayUuid(consumableId, 'rfid-active-moved');
      final before = await db.printerDao.getByIdWithChannels(printerId);
      final oldChannel = before!.channels
          .firstWhere((item) => item.channel.channelIndex == 0)
          .channel;
      await db.printerDao.bindConsumable(oldChannel.id, consumableId);

      await db.printerDao.syncChannelsFromAms(
        printerId,
        const [
          AmsTray(amsId: 0, slot: 0, hasFilament: false),
          AmsTray(
            amsId: 0,
            slot: 1,
            trayUuid: 'rfid-active-moved',
            trayInfoIdx: 'GFA00',
            traySubBrands: 'Bambu Lab',
            trayType: 'PLA',
            trayColor: '000000FF',
            trayWeight: 1000,
            remain: 25,
            hasFilament: true,
          ),
        ],
        autoBindRfid: true,
        unbindEmpty: false,
      );

      final after = await db.printerDao.getByIdWithChannels(printerId);
      final oldSlot = after!.channels.firstWhere(
        (item) => item.channel.channelIndex == 0,
      );
      final newSlot = after.channels.firstWhere(
        (item) => item.channel.channelIndex == 1,
      );
      expect(oldSlot.channel.consumableId, isNull);
      expect(newSlot.channel.consumableId, consumableId);
      expect(newSlot.channel.loadedRemainingGrams, 250);
      expect(newSlot.consumable!.remainingGrams, 250);
    },
  );

  test(
    'detector replacement with the same reusable UID chooses old remainder or a new concrete spool',
    () async {
      const owner = 'maintenance@example.com|personal';
      const tag = 'D021B75E';
      const reported = 'D021B75E00000100';
      const tray = AmsTray(
        amsId: 0,
        slot: 0,
        tagUid: reported,
        trayUuid: '11111111222233334444555555555555',
        trayInfoIdx: 'GFG00',
        traySubBrands: 'Bambu Lab',
        trayType: 'PETG',
        trayColor: 'FFFFFFFF',
        trayWeight: 1000,
        remain: 42,
        hasFilament: true,
      );
      const emptyTray = AmsTray(amsId: 0, slot: 0, hasFilament: false);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final receipt = await db.consumableDao.addPersonalStockFromRfidCard(
        operationUid: '8bccb30f-5da8-48d0-988f-ab01e23b0b04',
        tagUid: tag,
        tagType: 'CUID',
        quantity: 2,
        ownerAccount: owner,
        template: PersonalInventoryRecord(
          uid: 'replacement-template',
          manufacturer: 'eSUN',
          model: 'PETG',
          materialType: 'PETG',
          colorHex: '#FFFFFFFF',
          totalGrams: 1000,
          remainingGrams: 1000,
          createdAt: DateTime.utc(2026, 9, 9),
          updatedAt: DateTime.utc(2026, 9, 9),
        ),
      );
      final oldId = receipt.consumableIds.first;
      final newId = receipt.consumableIds.last;
      final printerId = await db.printerDao.addPrinter(
        brand: '拓竹',
        model: 'P1S',
        channelCount: 1,
      );
      await db.printerDao.bindSpoolReplacement(
        printerId: printerId,
        channelIndex: 0,
        consumableId: oldId,
        uniquePhysicalSpool: true,
        confirmedAmsUid: reported,
        sourceTagUid: tag,
        sourceTagType: 'CUID',
        sourceOwnerAccount: owner,
        enforcePersonalOwner: true,
        personalOwnerAccount: owner,
      );
      await db.consumableDao.adjustGrams(oldId, 585);
      final channel = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single.channel;
      final taskId = await db.customInsert(
        "INSERT INTO print_tasks(uid,printer_id,gcode_path,task_name,estimated_grams,status,created_at,updated_at) VALUES ('same-card-replacement',?,'test','test',100,'printing',1,1)",
        variables: [Variable(printerId)],
      );
      await db.customInsert(
        'INSERT INTO print_task_consumables(task_id,printer_id,channel_index,consumable_id,tool_index,estimated_grams,last_deducted_grams,created_at,updated_at) VALUES (?,?,0,?,0,100,25,1,1)',
        variables: [Variable(taskId), Variable(printerId), Variable(oldId)],
      );

      final detector = SpoolChangeDetector();
      final startedAt = DateTime.utc(2026, 9, 9, 8);
      expect(
        detector.update(
          printerSerial: 'REUSABLE-CARD',
          printerLabel: '工作台',
          trays: const [tray],
          now: startedAt,
        ),
        isEmpty,
      );
      detector.update(
        printerSerial: 'REUSABLE-CARD',
        printerLabel: '工作台',
        trays: const [emptyTray],
        now: startedAt.add(const Duration(milliseconds: 100)),
      );
      final removals = detector.update(
        printerSerial: 'REUSABLE-CARD',
        printerLabel: '工作台',
        trays: const [emptyTray],
        now: startedAt.add(const Duration(seconds: 1)),
      );
      expect(removals.single.isRemoval, isTrue);

      // This is the DAO action performed before the detected-removal reason
      // dialog. The local hold becomes state 2 while the sync lifecycle stays
      // active, so syncing during the dialog cannot retire the retained roll.
      await db.printerDao.preparePersonalSpoolReplacement(
        channel.id,
        expectedConsumableId: oldId,
        enforcePersonalOwner: true,
        personalOwnerAccount: owner,
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(oldId))!.status,
        'active',
      );
      expect(
        await db.printerDao.getChannelRollHoldState(printerId, 0),
        ChannelRollHoldState.awaitingSelection,
      );
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 415);

      final insertions = detector.update(
        printerSerial: 'REUSABLE-CARD',
        printerLabel: '工作台',
        trays: const [tray],
        now: startedAt.add(const Duration(milliseconds: 1100)),
      );
      expect(insertions.single.kind, SpoolChangeKind.inserted);
      await db.printerDao.syncChannelsFromAms(
        printerId,
        const [tray],
        autoBindRfid: true,
        unbindEmpty: false,
        personalOwnerAccount: owner,
      );
      final stillPrepared = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      expect(stillPrepared.channel.consumableId, oldId);
      expect(stillPrepared.farmRollPaused, isTrue);
      expect(stillPrepared.awaitingSpoolSelection, isTrue);

      final queue = SpoolChangeQueueNotifier();
      addTearDown(queue.dispose);
      queue.usePersonalOwner(owner);
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printerId,
        printerSerial: 'REUSABLE-CARD',
        printerLabel: '工作台',
        status: BambuPrinterStatus(serial: 'REUSABLE-CARD', amsTrays: [tray]),
        personalOwnerAccount: owner,
      );
      var event = queue.state.single;
      expect(event.requiresRfidConfirmation, isTrue);
      expect(event.rfidCandidateIds.toSet(), {oldId, newId});
      expect(event.rfidStockCandidates.keys.toSet(), {newId});

      // Choosing the old concrete roll only resumes it; no task segment or
      // lifecycle cycle is manufactured and the exact 415 g remains.
      await db.printerDao.resumePreparedPersonalSpoolReplacement(
        channel.id,
        expectedConsumableId: oldId,
        enforcePersonalOwner: true,
        personalOwnerAccount: owner,
      );
      expect((await db.consumableDao.getRfidSpoolBindingById(oldId))!.cycle, 1);
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 415);
      expect(
        await db
            .customSelect(
              'SELECT * FROM print_task_consumables WHERE task_id = ?',
              variables: [Variable(taskId)],
            )
            .get(),
        hasLength(1),
      );

      // Choosing “replace” again and then the full stock row transfers only
      // the unfinished task segment; it does not refill or zero the old roll.
      await db.printerDao.preparePersonalSpoolReplacement(
        channel.id,
        expectedConsumableId: oldId,
        enforcePersonalOwner: true,
        personalOwnerAccount: owner,
      );
      queue.clear();
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printerId,
        printerSerial: 'REUSABLE-CARD',
        printerLabel: '工作台',
        status: BambuPrinterStatus(serial: 'REUSABLE-CARD', amsTrays: [tray]),
        personalOwnerAccount: owner,
      );
      event = queue.state.single;
      final selected = event.rfidStockCandidates[newId]!;
      await db.printerDao.bindSpoolReplacement(
        printerId: printerId,
        channelIndex: 0,
        consumableId: newId,
        uniquePhysicalSpool: true,
        confirmedAmsUid: reported,
        sourceTagUid: selected.tagUid,
        sourceTagType: selected.tagType,
        sourceOwnerAccount: selected.ownerAccount,
        enforcePersonalOwner: true,
        personalOwnerAccount: owner,
      );
      final loaded = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      expect(loaded.channel.consumableId, newId);
      expect(loaded.farmRollPaused, isFalse);
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 415);
      expect((await db.consumableDao.getById(newId))!.remainingGrams, 1000);
      final segments = await db
          .customSelect(
            'SELECT * FROM print_task_consumables WHERE task_id = ? ORDER BY id',
            variables: [Variable(taskId)],
          )
          .get();
      expect(segments, hasLength(2));
      expect(segments.first.read<int>('consumable_id'), oldId);
      expect(segments.first.read<int?>('consumed_at'), isNotNull);
      expect(segments.last.read<int>('consumable_id'), newId);

      // A normal physical takeoff keeps the current lifecycle syncable but
      // returns the local feed to state 2. Only an explicit concrete-roll
      // choice may release the hold.
      await db.printerDao.unbindChannel(
        loaded.channel.id,
        expectedConsumableId: newId,
        enforcePersonalOwner: true,
        personalOwnerAccount: owner,
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(newId))!.status,
        'active',
      );
      final takenOff = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      expect(takenOff.channel.consumableId, newId);
      expect(takenOff.awaitingSpoolSelection, isTrue);
      queue.clear();
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printerId,
        printerSerial: 'REUSABLE-CARD',
        printerLabel: '工作台',
        status: BambuPrinterStatus(
          serial: 'REUSABLE-CARD',
          amsTrays: const [tray],
        ),
        personalOwnerAccount: owner,
      );
      expect(queue.state.single.requiresRfidConfirmation, isTrue);
      expect(queue.state.single.rfidCandidateIds.toSet(), {oldId, newId});

      await db.printerDao.resumePreparedPersonalSpoolReplacement(
        loaded.channel.id,
        expectedConsumableId: newId,
        enforcePersonalOwner: true,
        personalOwnerAccount: owner,
      );
      final normalTakeoffResumed = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      expect(normalTakeoffResumed.farmRollPaused, isFalse);
      expect(normalTakeoffResumed.channel.consumableId, newId);
      expect((await db.consumableDao.getById(newId))!.remainingGrams, 1000);
    },
  );

  test(
    'legacy CUID without a stock receipt still requires confirming its retained roll',
    () async {
      const tag = 'D021B75E';
      const reported = 'D021B75E00000100';
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final printerId = await db.printerDao.addPrinter(
        brand: '拓竹',
        model: 'P1S',
        channelCount: 1,
      );
      final spoolId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          uid: const Value('legacy-cuid-remnant'),
          manufacturer: 'eSUN',
          model: 'PLA+',
          materialType: const Value('PLA'),
          totalGrams: const Value(1000),
          remainingGrams: const Value(415),
        ),
      );
      await db.consumableDao.setRfidSpoolBinding(
        spoolId,
        tagUid: tag,
        tagType: 'CUID',
        cycle: 1,
        status: 'active',
      );
      final channel = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single.channel;
      await db.printerDao.bindConsumable(channel.id, spoolId);
      await db.printerDao.preparePersonalSpoolReplacement(
        channel.id,
        expectedConsumableId: spoolId,
      );

      final identity = (await PersonalAmsIdentityResolver.load(
        db,
        ownerAccount: '',
      )).resolve(reported);
      expect(identity.requiresConfirmation, isTrue);
      expect(identity.currentConsumableId, isNull);
      expect(identity.candidates.map((candidate) => candidate.consumableId), [
        spoolId,
      ]);

      final queue = SpoolChangeQueueNotifier()..usePersonalOwner('');
      addTearDown(queue.dispose);
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printerId,
        printerSerial: 'LEGACY-CUID',
        printerLabel: '旧数据打印机',
        status: BambuPrinterStatus(
          serial: 'LEGACY-CUID',
          amsTrays: const [
            AmsTray(
              amsId: 0,
              slot: 0,
              tagUid: reported,
              trayUuid: '11111111222233334444555555555555',
              trayInfoIdx: 'GFA00',
              traySubBrands: 'Bambu Lab',
              trayType: 'PLA',
              hasFilament: true,
            ),
          ],
        ),
        personalOwnerAccount: '',
      );
      expect(queue.state.single.requiresRfidConfirmation, isTrue);
      expect(queue.state.single.rfidCandidateIds, [spoolId]);

      // The app performs “resume then finish” in one outer transaction. If a
      // reinsertion/event change is observed between awaits, throwing rolls
      // the provisional resume back to state 2 instead of leaving it active.
      await expectLater(
        db.transaction(() async {
          await db.printerDao.resumePreparedPersonalSpoolReplacement(
            channel.id,
            expectedConsumableId: spoolId,
          );
          throw StateError('simulated reinsertion');
        }),
        throwsStateError,
      );
      expect(
        await db.printerDao.getChannelRollHoldState(printerId, 0),
        ChannelRollHoldState.awaitingSelection,
      );

      await db.printerDao.resumePreparedPersonalSpoolReplacement(
        channel.id,
        expectedConsumableId: spoolId,
      );
      final resumed = (await db.printerDao.getByIdWithChannels(
        printerId,
      ))!.channels.single;
      expect(resumed.farmRollPaused, isFalse);
      expect(resumed.consumable!.remainingGrams, 415);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(spoolId))!.cycle,
        1,
      );

      // A later ordinary takeoff uses the same durable local marker. Legacy
      // rows without receipts remain selectable and do not need a fake new
      // inventory record or a lifecycle roundtrip.
      await db.printerDao.unbindChannel(
        channel.id,
        expectedConsumableId: spoolId,
      );
      expect(
        await db.printerDao.getChannelRollHoldState(printerId, 0),
        ChannelRollHoldState.awaitingSelection,
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(spoolId))!.status,
        'active',
      );
      queue.clear();
      await enqueueUnboundFeedConfiguration(
        queue: queue,
        printerDao: db.printerDao,
        printerId: printerId,
        printerSerial: 'LEGACY-CUID',
        printerLabel: '旧数据打印机',
        status: BambuPrinterStatus(
          serial: 'LEGACY-CUID',
          amsTrays: const [
            AmsTray(
              amsId: 0,
              slot: 0,
              tagUid: reported,
              trayUuid: '11111111222233334444555555555555',
              trayInfoIdx: 'GFA00',
              traySubBrands: 'Bambu Lab',
              trayType: 'PLA',
              hasFilament: true,
            ),
          ],
        ),
        personalOwnerAccount: '',
      );
      expect(queue.state.single.requiresRfidConfirmation, isTrue);
      expect(queue.state.single.rfidCandidateIds, [spoolId]);
      await db.printerDao.resumePreparedPersonalSpoolReplacement(
        channel.id,
        expectedConsumableId: spoolId,
      );
      expect(
        (await db.printerDao.getByIdWithChannels(
          printerId,
        ))!.channels.single.farmRollPaused,
        isFalse,
      );
    },
  );

  testWidgets(
    'personal removal dialog offers a no-deduction maintenance path',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(700, 560));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      PersonalSpoolRemovalDecision? decision;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () async {
                    decision = await PersonalSpoolRemovalDialog.show(
                      context: context,
                      channelLabel: 'AMS 1 · 第 1 通道',
                      spoolLabel: 'eSUN · 黑色 · PLA',
                      remainingGrams: 640,
                      normalDecision: PersonalSpoolRemovalDecision.usedUp,
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('取下耗材前确认'), findsOneWidget);
      expect(find.textContaining('保留当前 640g，不进行扣除'), findsOneWidget);
      expect(find.text('维修暂取'), findsOneWidget);
      expect(find.text('确认用完'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('personal-spool-removal-maintenance')),
      );
      await tester.pumpAndSettle();

      expect(decision, PersonalSpoolRemovalDecision.maintenance);
      expect(find.text('取下耗材前确认'), findsNothing);
    },
  );

  testWidgets('detected removal asks for all four physical reasons', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    PersonalSpoolRemovalDecision? decision;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () async {
                  decision = await PersonalSpoolRemovalDialog.showDetected(
                    context: context,
                    channelLabel: '第 1 台 AMS · 第 1 通道',
                    spoolLabel: 'eSUN · 黑色 · PLA',
                    remainingGrams: 640,
                  );
                },
                child: const Text('模拟拔料'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('模拟拔料'));
    await tester.pumpAndSettle();

    expect(find.text('检测到耗材已取下'), findsOneWidget);
    expect(find.text('堵头或维修暂取'), findsOneWidget);
    expect(find.text('正常取下并放回库存'), findsOneWidget);
    expect(find.text('准备换上新料卷'), findsOneWidget);
    expect(find.text('这卷已经用完'), findsOneWidget);
    expect(find.textContaining('保留 640g，不扣除'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('detected-removal-maintenance')),
    );
    await tester.pumpAndSettle();

    expect(decision, PersonalSpoolRemovalDecision.maintenance);
  });
}
