import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/personal_inventory_balance_sync.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_event.dart';
import 'package:consumable_tracker_desktop/data/models/rfid_tag_history.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart' show Colors;
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';

void main() {
  late AppDatabase database;
  late ConsumableDao dao;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dao = database.consumableDao;
  });

  tearDown(() => database.close());

  test(
    'a failed cloud upload reports the committed local roll and retries without duplication',
    () async {
      final api = _FakeInventoryApi(
        const PersonalInventorySnapshot(revision: 0, records: []),
      );
      api.beforeReplaceResponse = () async => throw StateError('offline');
      final sync = AccountMobileInventorySync(
        dao: dao,
        api: api,
        session: _session(),
      );
      final saved = await sync.save(
        MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA',
          color: Colors.blue,
          colorName: '蓝',
        ),
        tagId: '04A1B2C3',
        tagType: 'CUID',
      );
      expect(saved.syncPending, isTrue);
      expect(
        (await dao.getAnyPersonalByRfidTagUid('04A1B2C3'))!.uid,
        saved.inventoryUid,
      );
      api.beforeReplaceResponse = null;
      await sync.synchronizeExisting();
      expect(api.snapshot.records, hasLength(1));
      expect(api.snapshot.records.single.rfidTagType, 'CUID');
    },
  );

  test('manual batch failure rolls back every roll before retry', () async {
    final sync = LocalMobileInventorySync(dao);
    const draft = MobileConsumableDraft(
      brand: 'eSUN',
      model: 'PLA',
      color: Colors.blue,
      colorName: '蓝',
    );
    await database.customStatement('''
      CREATE TRIGGER fail_second_manual BEFORE INSERT ON consumables
      WHEN (SELECT COUNT(*) FROM consumables) = 1
      BEGIN SELECT RAISE(ABORT, 'injected second roll failure'); END
    ''');
    await expectLater(
      sync.saveManualBatch(draft, quantity: 3, initialGrams: 500),
      throwsA(anything),
    );
    expect(await database.select(database.consumables).get(), isEmpty);
    await database.customStatement('DROP TRIGGER fail_second_manual');
    final saved = await sync.saveManualBatch(
      draft,
      quantity: 3,
      initialGrams: 500,
    );
    expect(saved.map((entry) => entry.inventoryUid).toSet(), hasLength(3));
    final rows = await database.select(database.consumables).get();
    expect(rows, hasLength(3));
    expect(rows.every((row) => row.remainingGrams == 500), isTrue);
    // 100 is the documented upper bound for one confirmed receipt; the next
    // value must be rejected without changing the already committed rows.
    for (final quantity in [0, 101]) {
      await expectLater(
        sync.saveManualBatch(draft, quantity: quantity, initialGrams: 500),
        throwsArgumentError,
      );
    }
    expect(await database.select(database.consumables).get(), hasLength(3));
  });

  test(
    'manual batch commits once and cloud retry does not add duplicate rolls',
    () async {
      final api = _FakeInventoryApi(
        const PersonalInventorySnapshot(revision: 0, records: []),
      );
      api.beforeReplaceResponse = () async => throw StateError('offline');
      final sync = AccountMobileInventorySync(
        dao: dao,
        api: api,
        session: _session(),
      );
      final saved = await sync.saveManualBatch(
        const MobileConsumableDraft(
          brand: 'eSUN',
          model: 'PLA',
          color: Colors.blue,
          colorName: '蓝',
        ),
        quantity: 3,
        initialGrams: 500,
      );
      expect(saved, hasLength(3));
      expect(saved.every((entry) => entry.syncPending), isTrue);
      expect(await database.select(database.consumables).get(), hasLength(3));
      api.beforeReplaceResponse = null;
      await sync.synchronizeExisting();
      expect(api.snapshot.records, hasLength(3));
      expect(await database.select(database.consumables).get(), hasLength(3));
    },
  );

  test(
    'account change before manual batch commit rolls back all rolls',
    () async {
      var checks = 0;
      final sync = AccountMobileInventorySync(
        dao: dao,
        api: _FakeInventoryApi(
          const PersonalInventorySnapshot(revision: 0, records: []),
        ),
        session: _session(),
        ensureSession: () async {
          if (++checks > 1)
            throw const MobileInventoryAccountChangedException();
          return _session();
        },
      );
      await expectLater(
        sync.saveManualBatch(
          const MobileConsumableDraft(
            brand: 'eSUN',
            model: 'PLA',
            color: Colors.blue,
            colorName: '蓝',
          ),
          quantity: 3,
          initialGrams: 500,
        ),
        throwsA(isA<MobileInventoryAccountChangedException>()),
      );
      expect(await database.select(database.consumables).get(), isEmpty);
    },
  );

  PersonalInventoryRecord record(
    String uid, {
    String? tag,
    int cycle = 1,
    String? previous,
    DateTime? updatedAt,
  }) {
    final now = DateTime.utc(2026, 8, 1);
    return PersonalInventoryRecord(
      uid: uid,
      manufacturer: 'eSUN',
      model: 'PLA',
      materialType: 'PLA',
      colorHex: '#FFFFFF',
      totalGrams: 1000,
      remainingGrams: 900,
      createdAt: now,
      updatedAt: updatedAt ?? now,
      rfidTagUid: tag,
      rfidTagType: tag == null ? null : 'CUID',
      rfidTagCycle: cycle,
      previousConsumableUid: previous,
    );
  }

  test(
    'a late pre-rebind snapshot cannot erase the new identity even with a newer clock',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final old = record(
        'rebound',
        tag: '04A1B2C3',
      ).copyWith(lifecycleStatus: 'replaced');
      final rebound = record('rebound', tag: '04BB0002').copyWith(
        rfidTagHistory: const [
          RfidTagHistoryEntry(tagUid: '04A1B2C3', cycle: 1),
        ],
      );
      await dao.upsertPersonalInventoryRecord(rebound, ownerAccount: owner);
      final api = _FakeInventoryApi(
        PersonalInventorySnapshot(
          revision: 1,
          records: [
            old.copyWith(updatedAt: DateTime.utc(2030)),
            record('next', tag: '04A1B2C3', cycle: 2, previous: old.uid),
          ],
        ),
      );
      await PersonalInventorySyncService(
        dao: dao,
        api: api,
      ).synchronize(session: session);
      final saved = api.snapshot.records.firstWhere((r) => r.uid == old.uid);
      expect(saved.rfidTagUid, '04BB0002');
      expect(saved.rfidTagHistory, hasLength(1));
      expect(saved.remainingGrams, 900);
      final id = (await dao.getPersonalByUid(old.uid, ownerAccount: owner))!.id;
      expect((await dao.getRfidSpoolBindingById(id))!.tagHistory, hasLength(1));
    },
  );

  test(
    'account rebind rolls back the local tag and event if cloud upload fails',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final id = await dao.upsertPersonalInventoryRecord(
        record('old', tag: '04A1B2C3'),
        ownerAccount: owner,
      );
      await dao.replacePersonalRfidSpool(consumableId: id, initialGrams: 750);
      final api = _FakeInventoryApi(
        const PersonalInventorySnapshot(revision: 0, records: []),
      );
      final sync = PersonalInventorySyncService(dao: dao, api: api);
      await sync.synchronize(session: session);
      api.beforeReplaceResponse = () async =>
          throw StateError('connection lost');
      await expectLater(
        sync.rebindAndSynchronize(
          session: session,
          consumableId: id,
          expectedTagUid: '04A1B2C3',
          newTagUid: '04BB0002',
          newTagType: 'CUID',
        ),
        throwsStateError,
      );
      expect((await dao.getRfidSpoolBindingById(id))!.tagUid, '04A1B2C3');
      expect((await dao.getRfidSpoolBindingById(id))!.tagHistory, isEmpty);
      expect(
        (await dao.getPersonalInventoryEvents(
          owner,
        )).where((e) => e.eventType == 'tag_rebound'),
        isEmpty,
      );
      api.beforeReplaceResponse = null;
      await sync.rebindAndSynchronize(
        session: session,
        consumableId: id,
        expectedTagUid: '04A1B2C3',
        newTagUid: '04BB0002',
        newTagType: 'CUID',
      );
      expect((await dao.getRfidSpoolBindingById(id))!.tagUid, '04BB0002');
    },
  );

  test(
    'pulling a rebind detaches an idle slot that still points at the original tag',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final old = record('idle-old', tag: '04A1B2C3');
      final id = await dao.upsertPersonalInventoryRecord(
        old,
        ownerAccount: owner,
      );
      final printer = await database
          .into(database.printers)
          .insert(PrintersCompanion.insert(brand: 'Bambu', model: 'P1S'));
      final channel = await database
          .into(database.printerChannels)
          .insert(
            PrinterChannelsCompanion.insert(
              printerId: printer,
              channelIndex: 0,
              consumableId: Value(id),
              loadedRemainingGrams: const Value(900),
            ),
          );
      final rebound = record('idle-old', tag: '04BB0002').copyWith(
        rfidTagHistory: const [
          RfidTagHistoryEntry(tagUid: '04A1B2C3', cycle: 1),
        ],
      );
      final api = _FakeInventoryApi(
        PersonalInventorySnapshot(
          revision: 1,
          records: [
            rebound,
            record('idle-next', tag: '04A1B2C3', cycle: 2, previous: old.uid),
          ],
        ),
      );
      await PersonalInventorySyncService(
        dao: dao,
        api: api,
      ).synchronize(session: session);
      final rows = await database
          .customSelect(
            'SELECT consumable_id, loaded_remaining_grams FROM printer_channels WHERE id = ?',
            variables: [Variable(channel)],
          )
          .getSingle();
      expect(rows.read<int?>('consumable_id'), isNull);
      expect(rows.read<double>('loaded_remaining_grams'), 0);
    },
  );

  test(
    'remote tag reuse cannot end a spool with an unsettled local task',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final old = record('task-old', tag: '04A1B2C3');
      final oldId = await dao.upsertPersonalInventoryRecord(
        old,
        ownerAccount: owner,
      );
      final taskId = await database.customInsert(
        "INSERT INTO print_tasks(uid, gcode_path, task_name, status, created_at, updated_at) "
        "VALUES ('local-print', 'test.gcode', 'test', 'printing', 1, 1)",
      );
      await database.customInsert(
        'INSERT INTO print_task_consumables(task_id, consumable_id, estimated_grams, '
        'created_at, updated_at) VALUES (?, ?, 100, 1, 1)',
        variables: [Variable(taskId), Variable(oldId)],
      );
      final api = _FakeInventoryApi(
        PersonalInventorySnapshot(
          revision: 1,
          records: [
            old.copyWith(
              lifecycleStatus: 'replaced',
              updatedAt: DateTime.utc(2026, 9, 6),
            ),
            record('task-next', tag: '04A1B2C3', cycle: 2, previous: old.uid),
          ],
        ),
      );
      final sync = PersonalInventorySyncService(dao: dao, api: api);
      await expectLater(
        sync.synchronize(session: session),
        throwsA(
          isA<CommunityApiException>().having(
            (e) => e.code,
            'code',
            'inventory_task_handoff_required',
          ),
        ),
      );
      expect((await dao.getRfidSpoolBindingById(oldId))!.isActive, isTrue);
      expect((await dao.getById(oldId))!.remainingGrams, 900);
      expect(api.lastPut, isNull);
      await database.customStatement(
        'UPDATE print_task_consumables SET consumed_at = 1',
      );
      await sync.synchronize(session: session);
      expect((await dao.getRfidSpoolBindingById(oldId))!.status, 'replaced');
    },
  );

  test(
    'sync preserves binding metadata and closes a superseded active cycle',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final old = record('old-roll', tag: '04A1B2C3');
      final id = await dao.upsertPersonalInventoryRecord(
        old,
        ownerAccount: owner,
      );
      final remoteOld = record('old-roll', updatedAt: DateTime.utc(2026, 8, 2));
      final next = record(
        'new-roll',
        tag: '04:a1:b2:c3',
        cycle: 2,
        previous: old.uid,
      );
      final api = _FakeInventoryApi(
        PersonalInventorySnapshot(revision: 0, records: [remoteOld, next]),
      );
      await PersonalInventorySyncService(
        dao: dao,
        api: api,
      ).synchronize(session: session);
      final binding = (await dao.getRfidSpoolBindingById(id))!;
      expect(binding.tagUid, '04A1B2C3');
      expect(binding.status, 'replaced');
      expect(
        (await dao.getAnyPersonalByRfidTagUid('04A1B2C3'))!.uid,
        'new-roll',
      );
      expect((await dao.getById(id))!.remainingGrams, 900);
    },
  );

  test('an in-flight sync response cannot undo a local consumption', () async {
    final session = _session();
    final owner = PersonalInventorySyncService.ownerAccountFor(session);
    final id = await dao.upsertPersonalInventoryRecord(
      record('live-roll', tag: '04A1B2C3'),
      ownerAccount: owner,
    );
    final api = _FakeInventoryApi(
      const PersonalInventorySnapshot(revision: 0, records: []),
    );
    api.beforeReplaceResponse = () => dao.adjustGrams(id, 50);
    final service = PersonalInventorySyncService(dao: dao, api: api);
    await service.synchronize(session: session);
    expect((await dao.getById(id))!.remainingGrams, 850);
    api.beforeReplaceResponse = null;
    await service.synchronize(session: session);
    expect(api.lastPut!.records.single.remainingGrams, 850);
  });

  test(
    'a newer metadata edit cannot restore the pre-consumption balance',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final initial = record('field-merge', tag: '04A1B2C3');
      final id = await dao.upsertPersonalInventoryRecord(
        initial,
        ownerAccount: owner,
      );
      final api = _FakeInventoryApi(
        PersonalInventorySnapshot(revision: 0, records: [initial]),
      );
      final sync = PersonalInventorySyncService(dao: dao, api: api);
      await sync.synchronize(session: session);
      await dao.adjustGrams(id, 100);
      api.snapshot = PersonalInventorySnapshot(
        revision: api.snapshot.revision + 1,
        records: [
          initial.copyWith(model: '手机更新的型号', updatedAt: DateTime.utc(2090)),
        ],
      );
      await sync.synchronize(session: session);
      expect(api.snapshot.records.single.remainingGrams, 800);
      expect(api.snapshot.records.single.model, '手机更新的型号');
      expect((await dao.getById(id))!.remainingGrams, 800);
    },
  );

  test(
    'different concurrent balances require explicit reconciliation before upload',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final initial = record('balance-conflict', tag: '04A1B2C3');
      final id = await dao.upsertPersonalInventoryRecord(
        initial,
        ownerAccount: owner,
      );
      final api = _FakeInventoryApi(
        PersonalInventorySnapshot(revision: 0, records: [initial]),
      );
      final sync = PersonalInventorySyncService(dao: dao, api: api);
      await sync.synchronize(session: session);
      await dao.adjustGrams(id, 40);
      api.snapshot = PersonalInventorySnapshot(
        revision: api.snapshot.revision + 1,
        records: [
          initial.copyWith(remainingGrams: 820, updatedAt: DateTime.utc(2090)),
        ],
      );
      await expectLater(
        sync.synchronize(session: session),
        throwsA(
          isA<CommunityApiException>().having(
            (error) => error.code,
            'code',
            'inventory_balance_conflict',
          ),
        ),
      );
      expect((await dao.getById(id))!.remainingGrams, 860);
      expect(api.snapshot.records.single.remainingGrams, 820);
      final conflict = (await dao.readInventoryBalanceConflicts(
        initial.uid,
        ownerAccount: owner,
      )).single;
      await dao.reconcilePersonalInventoryBalance(id, conflict, 805);
      await sync.synchronize(session: session);
      expect(api.snapshot.records.single.remainingGrams, 805);
      expect(
        await dao.readInventoryBalanceConflicts(
          initial.uid,
          ownerAccount: owner,
        ),
        isEmpty,
      );
      expect(
        (await dao.getPersonalInventoryEvents(
          owner,
        )).singleWhere((e) => e.eventType == 'balance_reconciled').afterGrams,
        805,
      );
    },
  );

  test('a late active snapshot cannot refill a replaced roll', () async {
    final session = _session();
    final owner = PersonalInventorySyncService.ownerAccountFor(session);
    final old = record(
      'closed-roll',
      tag: '04A1B2C3',
    ).copyWith(remainingGrams: 200, lifecycleStatus: 'replaced');
    final id = await dao.upsertPersonalInventoryRecord(
      old,
      ownerAccount: owner,
    );
    final stale = record('closed-roll', updatedAt: DateTime.utc(2026, 8, 3));
    final api = _FakeInventoryApi(
      PersonalInventorySnapshot(revision: 0, records: [stale]),
    );
    await PersonalInventorySyncService(
      dao: dao,
      api: api,
    ).synchronize(session: session);
    expect((await dao.getById(id))!.remainingGrams, 200);
    expect((await dao.getRfidSpoolBindingById(id))!.status, 'replaced');
  });

  test(
    'concurrent replacements are imported for review before any invalid upload',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final old = record(
        'previous',
        tag: '04A1B2C3',
      ).copyWith(lifecycleStatus: 'replaced');
      await dao.upsertPersonalInventoryRecord(old, ownerAccount: owner);
      await dao.upsertPersonalInventoryRecord(
        record('branch-a', tag: '04A1B2C3', cycle: 2, previous: old.uid),
        ownerAccount: owner,
      );
      final api = _FakeInventoryApi(
        PersonalInventorySnapshot(
          revision: 0,
          records: [
            old,
            record('branch-b', tag: '04A1B2C3', cycle: 2, previous: old.uid),
          ],
        ),
      );
      await expectLater(
        PersonalInventorySyncService(
          dao: dao,
          api: api,
        ).synchronize(session: session),
        throwsA(
          isA<CommunityApiException>().having(
            (e) => e.code,
            'code',
            'inventory_tag_cycle_conflict',
          ),
        ),
      );
      expect(api.lastPut, isNull);
      expect(
        await dao.getPersonalRfidSpoolHistory('04A1B2C3', ownerAccount: owner),
        hasLength(3),
      );
      expect(await dao.getAnyPersonalByRfidTagUid('04A1B2C3'), isNull);
      final chosen = (await dao.getPersonalByUid(
        'branch-a',
        ownerAccount: owner,
      ))!;
      await dao.resolvePersonalRfidSpoolConflict(chosen.id);
      await PersonalInventorySyncService(
        dao: dao,
        api: api,
      ).synchronize(session: session);
      expect(
        (await dao.getAnyPersonalByRfidTagUid('04A1B2C3'))!.uid,
        'branch-a',
      );
      final next = await dao.replacePersonalRfidSpool(
        consumableId: chosen.id,
        initialGrams: 500,
      );
      expect(next.cycle, 3);
    },
  );

  test(
    'local delete is uploaded as a tombstone and is not resurrected',
    () async {
      final now = DateTime.utc(2026, 8, 1);
      final record = PersonalInventoryRecord(
        uid: 'sync-spool-1',
        manufacturer: 'Bambu',
        model: 'PLA Basic',
        materialType: 'PLA',
        colorHex: '#FFFFFF',
        totalGrams: 1000,
        remainingGrams: 900,
        createdAt: now,
        updatedAt: now,
      );
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final id = await dao.addConsumableWithOwner(
        ConsumablesCompanion.insert(
          uid: Value(record.uid),
          manufacturer: record.manufacturer,
          model: record.model,
          materialType: Value(record.materialType),
          colorHex: Value(record.colorHex),
          totalGrams: Value(record.totalGrams),
          remainingGrams: Value(record.remainingGrams),
          createdAt: Value(record.createdAt),
          updatedAt: Value(record.updatedAt),
        ),
        ownerAccount: owner,
      );
      expect(await dao.deleteConsumable(id), 1);
      expect(
        await dao.getPersonalByUid(record.uid, ownerAccount: owner),
        isNull,
      );

      final api = _FakeInventoryApi(
        PersonalInventorySnapshot(revision: 0, records: [record]),
      );
      final result = await PersonalInventorySyncService(
        dao: dao,
        api: api,
      ).synchronize(session: session);

      expect(result.pushedChanges, isTrue);
      expect(api.lastPut?.records, isEmpty);
      expect(api.lastPut?.deletedUids.keys, contains(record.uid));
      expect(
        await dao.getPersonalByUid(record.uid, ownerAccount: owner),
        isNull,
      );
    },
  );

  test(
    'a depleted fork can be selected and the retired branch does not block replacement',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final chosen = record(
        'empty-choice',
        tag: '04A1B2C3',
      ).copyWith(remainingGrams: 0, lifecycleStatus: 'depleted');
      final other = record(
        'other-choice',
        tag: '04A1B2C3',
      ).copyWith(remainingGrams: 0, lifecycleStatus: 'depleted');
      final chosenId = await dao.upsertPersonalInventoryRecord(
        chosen,
        ownerAccount: owner,
      );
      await dao.upsertPersonalInventoryRecord(other, ownerAccount: owner);
      await dao.resolvePersonalRfidSpoolConflict(chosenId);
      final history = await dao.getPersonalRfidSpoolHistory(
        '04A1B2C3',
        ownerAccount: owner,
      );
      expect(history.first.inventoryUid, chosen.uid);
      final next = await dao.replacePersonalRfidSpool(
        consumableId: chosenId,
        initialGrams: 750,
      );
      expect(next.cycle, 2);
    },
  );

  test(
    'sync projects NFC and consumption history and imports remote events',
    () async {
      final session = _session();
      final owner = PersonalInventorySyncService.ownerAccountFor(session);
      final spool = record('event-spool', tag: '04A1B2C3');
      final spoolId = await dao.upsertPersonalInventoryRecord(
        spool,
        ownerAccount: owner,
      );
      final at = DateTime.utc(2026, 8, 4).millisecondsSinceEpoch;
      await dao.customInsert(
        'INSERT INTO rfid_tag_records('
        'tag_uid, tag_type, operation, status, inventory_uid, owner_account, '
        'occurred_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          const Variable('04:a1:b2:c3'),
          const Variable('CUID'),
          const Variable('bind'),
          const Variable('success'),
          Variable(spool.uid),
          Variable(owner),
          Variable(at),
          Variable(at),
          Variable(at),
        ],
      );
      final expectedTime = DateTime.utc(2026, 8, 4, 0, 0, 1);
      await database.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(spoolId),
          consumedGrams: const Value(37.5),
          loggedAt: Value(expectedTime),
        ),
      );
      final captured = (await dao.getPersonalInventoryEvents(
        owner,
      )).singleWhere((e) => e.source == 'usage');
      expect(captured.occurredAt, expectedTime);
      expect(captured.deltaGrams, -37.5);
      final api = _FakeInventoryApi(
        PersonalInventorySnapshot(revision: 0, records: [spool]),
      );
      await PersonalInventorySyncService(
        dao: dao,
        api: api,
      ).synchronize(session: session);
      expect(api.lastPut, isNotNull);
      expect(
        api.lastPut!.events.map((event) => event.source),
        containsAll(<String>['nfc', 'usage']),
      );

      final remoteEvent = PersonalInventoryEvent(
        eventUid: 'remote:event-1',
        inventoryUid: spool.uid,
        rfidTagUid: '04A1B2C3',
        rfidTagCycle: 1,
        eventType: 'replacement_confirmed',
        occurredAt: DateTime.utc(2026, 8, 5),
        source: 'desktop',
      );
      api.snapshot = PersonalInventorySnapshot(
        revision: api.snapshot.revision,
        records: api.snapshot.records,
        events: [remoteEvent],
      );
      await PersonalInventorySyncService(
        dao: dao,
        api: api,
      ).synchronize(session: session);
      final events = await dao.getPersonalInventoryEvents(owner);
      expect(events.map((event) => event.eventUid), contains('remote:event-1'));
    },
  );
}

AppAuthSession _session() {
  final now = DateTime.utc(2026, 8, 1);
  return AppAuthSession(
    user: AppUser(
      id: 'user-1',
      email: 'sync@example.com',
      handle: 'sync_user',
      displayName: 'Sync User',
      emailVerified: true,
      createdAt: now,
      updatedAt: now,
    ),
    accessToken: 'access-token',
    refreshToken: 'refresh-token',
    expiresAt: now.add(const Duration(hours: 1)),
    serverBaseUrl: 'https://example.com',
  );
}

class _FakeInventoryApi implements PersonalInventoryApi {
  _FakeInventoryApi(this.snapshot);

  PersonalInventorySnapshot snapshot;
  PersonalInventorySnapshot? lastPut;
  Future<Object?> Function()? beforeReplaceResponse;

  @override
  Future<PersonalInventorySnapshot> fetchPersonalInventory({
    required String accessToken,
  }) async => snapshot;

  @override
  Future<PersonalInventorySnapshot> replacePersonalInventory({
    required String accessToken,
    required PersonalInventorySnapshot snapshot,
  }) async {
    lastPut = snapshot;
    await beforeReplaceResponse?.call();
    this.snapshot = PersonalInventorySnapshot(
      revision: snapshot.revision + 1,
      records: snapshot.records,
      materialCatalog: snapshot.materialCatalog,
      deletedUids: snapshot.deletedUids,
      events: snapshot.events,
    );
    return this.snapshot;
  }
}
