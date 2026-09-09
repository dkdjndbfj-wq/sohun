import 'dart:convert';

import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_event.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const owner = 'ledger@example.com|personal';
final at = DateTime.utc(2026, 9, 6, 12, 30, 45);
PersonalInventoryRecord spool() => PersonalInventoryRecord(
  uid: 'spool-1',
  manufacturer: 'eSUN',
  model: 'PLA',
  materialType: 'PLA',
  colorHex: '#FFFFFF',
  totalGrams: 750,
  remainingGrams: 750,
  createdAt: at,
  updatedAt: at,
  rfidTagUid: '04A1B2C3',
  rfidTagType: 'CUID',
);

void main() {
  // Each instance uses a separate in-memory executor to simulate devices.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test(
    'Drift source time, printer and slot are captured once and survive source deletion',
    () async {
      final dao = db.consumableDao;
      final id = await dao.upsertPersonalInventoryRecord(
        spool(),
        ownerAccount: owner,
      );
      final printer = await db
          .into(db.printers)
          .insert(
            PrintersCompanion.insert(
              uid: const Value('printer-1'),
              brand: 'Test',
              model: 'Model',
              name: const Value('工作台'),
            ),
          );
      final log = await db.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(id),
          printerId: Value(printer),
          channelIndex: const Value(6),
          loggedAt: Value(at),
          consumedGrams: const Value(37.5),
          note: const Value(r'C:\private\job.gcode access_code=do-not-sync'),
        ),
        taskUid: 'print-task-1',
      );
      final first = (await dao.getPersonalInventoryEvents(owner)).single;
      expect(first.occurredAt, at);
      expect(first.deltaGrams, -37.5);
      expect(first.printerName, '工作台');
      expect(first.printerUid, 'printer-1');
      expect(first.channelIndex, 6);
      expect(first.taskUid, 'print-task-1');
      expect(jsonEncode(first.toJson()), isNot(contains('do-not-sync')));
      await dao.upsertPersonalInventoryRecord(
        spool().copyWith(model: 'Updated'),
        ownerAccount: owner,
      );
      await db.usageLogDao.deleteLog(log);
      final reread = (await dao.getPersonalInventoryEvents(owner)).single;
      expect(reread.toJson(), first.toJson());
      await dao.upsertPersonalInventoryEvents([first], ownerAccount: owner);
      expect(
        (await dao.getPersonalInventoryEvents(owner)).single.isRemote,
        isFalse,
      );
      expect(
        await dao.getPersonalInventoryConsumedGrams(
          spool().uid,
          ownerAccount: owner,
        ),
        37.5,
      );
    },
  );

  test(
    'two installations with the same local row IDs produce distinct immutable events',
    () async {
      final other = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(other.close);
      final ids = <String>[];
      for (final database in [db, other]) {
        final id = await database.consumableDao.upsertPersonalInventoryRecord(
          spool(),
          ownerAccount: owner,
        );
        await database.usageLogDao.addLog(
          UsageLogsCompanion.insert(
            consumableId: Value(id),
            loggedAt: Value(at),
            consumedGrams: const Value(10),
          ),
        );
        ids.add(
          (await database.consumableDao.getPersonalInventoryEvents(
            owner,
          )).single.eventUid,
        );
      }
      expect(ids.toSet(), hasLength(2));
    },
  );

  test('wrong-owner NFC source never leaks into the spool ledger', () async {
    await db.consumableDao.upsertPersonalInventoryRecord(
      spool(),
      ownerAccount: owner,
    );
    await db.customStatement(
      'INSERT INTO rfid_tag_records(tag_uid, inventory_uid, owner_account, '
      'occurred_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        '04A1B2C3',
        spool().uid,
        'someone-else|personal',
        at.millisecondsSinceEpoch,
        at.millisecondsSinceEpoch,
        at.millisecondsSinceEpoch,
      ],
    );
    expect(await db.consumableDao.getPersonalInventoryEvents(owner), isEmpty);
  });

  test(
    'a dropped append response retries stable IDs without duplicating or reclassifying local usage',
    () async {
      final id = await db.consumableDao.upsertPersonalInventoryRecord(
        spool(),
        ownerAccount: owner,
      );
      await db.usageLogDao.addLog(
        UsageLogsCompanion.insert(
          consumableId: Value(id),
          loggedAt: Value(at),
          consumedGrams: const Value(30),
        ),
      );
      final api = _PagedApi()..dropAppendResponse = true;
      final sync = PersonalInventorySyncService(
        dao: db.consumableDao,
        api: api,
      );
      await expectLater(sync.synchronize(session: session()), throwsStateError);
      expect(api.events, hasLength(1));
      await sync.synchronize(session: session());
      await sync.synchronize(session: session());
      expect(api.appendCalls, 2);
      expect(api.events, hasLength(1));
      final events = await db.consumableDao.getPersonalInventoryEvents(owner);
      expect(events, hasLength(1));
      expect(events.single.isRemote, false);
    },
  );

  test(
    'download failure resumes the committed cursor and aggregates every page once',
    () async {
      final api = _PagedApi()..failAfterCursor = 200;
      api.events.addAll(
        List.generate(
          450,
          (i) => PersonalInventoryEvent(
            eventUid: 'remote-$i',
            inventoryUid: spool().uid,
            rfidTagUid: '04A1B2C3',
            rfidTagCycle: 1,
            eventType: 'usage_finished',
            source: 'usage',
            deltaGrams: -1,
            occurredAt: at,
          ),
        ),
      );
      final sync = PersonalInventorySyncService(
        dao: db.consumableDao,
        api: api,
      );
      await expectLater(sync.synchronize(session: session()), throwsStateError);
      expect(
        await db.consumableDao.getPersonalInventoryEvents(owner),
        hasLength(200),
      );
      await sync.synchronize(session: session());
      expect(api.requestedCursors, [0, 200, 200, 400]);
      expect(
        await db.consumableDao.getPersonalInventoryEvents(owner),
        hasLength(450),
      );
      expect(
        await db.consumableDao.getPersonalInventoryConsumedGrams(
          spool().uid,
          ownerAccount: owner,
        ),
        450,
      );
      expect(
        await db.consumableDao.getPersonalInventoryEventsForUid(
          spool().uid,
          ownerAccount: 'wrong-account',
        ),
        isEmpty,
      );
      expect(
        (await db.consumableDao.getPersonalInventoryEventsForUid(
          spool().uid,
          ownerAccount: owner,
          offset: 440,
          limit: 20,
        )),
        hasLength(10),
      );
    },
  );

  test(
    'tagged manual use respects actual 750 g weight, archives evidence and rejects stale deductions',
    () async {
      final dao = db.consumableDao;
      final id = await dao.upsertPersonalInventoryRecord(
        spool(),
        ownerAccount: owner,
      );
      expect(await dao.adjustGrams(id, -100), 0);
      await expectLater(dao.adjustGrams(id, double.nan), throwsArgumentError);
      expect(await dao.deductOneRoll(id), 750);
      final event = (await dao.getPersonalInventoryEvents(owner)).single;
      expect(event.deltaGrams, -750);
      final next = await dao.replacePersonalRfidSpool(
        consumableId: id,
        initialGrams: 2000,
      );
      await expectLater(dao.adjustGrams(id, -10), throwsStateError);
      await dao.retirePersonalRfidSpool(next.consumableId);
      await expectLater(
        dao.adjustGrams(next.consumableId, 10),
        throwsStateError,
      );
      final afterArchive = await dao.replacePersonalRfidSpool(
        consumableId: next.consumableId,
        initialGrams: 500,
      );
      expect(afterArchive.cycle, 3);
      expect(
        (await dao.getRfidSpoolBindingById(next.consumableId))!.status,
        'retired',
      );
      expect(
        (await dao.getPersonalInventoryEvents(owner)).map((e) => e.eventType),
        containsAll(['nfc_replace_success', 'nfc_archive_success']),
      );
    },
  );
}

AppAuthSession session() => AppAuthSession(
  user: AppUser(
    id: 'user',
    email: 'ledger@example.com',
    handle: 'ledger',
    displayName: 'Ledger',
    emailVerified: true,
    createdAt: at,
    updatedAt: at,
  ),
  accessToken: 'test-token',
  refreshToken: 'test-refresh',
  expiresAt: at.add(const Duration(days: 1)),
  serverBaseUrl: 'https://example.com',
);

class _PagedApi implements PersonalInventoryApi, PersonalInventoryEventApi {
  PersonalInventorySnapshot snapshot = PersonalInventorySnapshot(
    revision: 1,
    records: [spool()],
    eventSyncVersion: 1,
  );
  final events = <PersonalInventoryEvent>[];
  final requestedCursors = <int>[];
  bool dropAppendResponse = false;
  int? failAfterCursor;
  int appendCalls = 0;

  @override
  Future<PersonalInventorySnapshot> fetchPersonalInventory({
    required String accessToken,
  }) async => snapshot;
  @override
  Future<PersonalInventorySnapshot> replacePersonalInventory({
    required String accessToken,
    required PersonalInventorySnapshot snapshot,
  }) async {
    expect(snapshot.events, isEmpty);
    return this.snapshot = PersonalInventorySnapshot(
      revision: snapshot.revision + 1,
      records: snapshot.records,
      deletedUids: snapshot.deletedUids,
      materialCatalog: snapshot.materialCatalog,
      eventSyncVersion: 1,
    );
  }

  @override
  Future<void> appendPersonalInventoryEvents({
    required String accessToken,
    required List<PersonalInventoryEvent> events,
  }) async {
    appendCalls++;
    expect(events.length, lessThanOrEqualTo(200));
    for (final event in events) {
      final index = this.events.indexWhere((e) => e.eventUid == event.eventUid);
      if (index < 0)
        this.events.add(event);
      else
        expect(this.events[index].toJson(), event.toJson());
    }
    if (dropAppendResponse) {
      dropAppendResponse = false;
      throw StateError('response lost after server commit');
    }
  }

  @override
  Future<PersonalInventoryEventPage> fetchPersonalInventoryEvents({
    required String accessToken,
    required int afterCursor,
  }) async {
    requestedCursors.add(afterCursor);
    if (failAfterCursor == afterCursor) {
      failAfterCursor = null;
      throw StateError('download interrupted');
    }
    final end = (afterCursor + 200).clamp(0, events.length);
    return PersonalInventoryEventPage(
      events: events.sublist(afterCursor, end),
      nextCursor: end,
      hasMore: end < events.length,
    );
  }
}
