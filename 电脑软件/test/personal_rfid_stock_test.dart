import 'dart:io';

import 'package:consumable_tracker_desktop/core/services/personal_inventory_sync_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/personal_ams_identity.dart';
import 'package:consumable_tracker_desktop/data/database/personal_inventory_balance_sync.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/data/external/community/community_api_client.dart';
import 'package:consumable_tracker_desktop/data/models/app_auth.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

const owner = 'stock@example.com|personal';
const card = 'D021B75E';
const operation = '8bccb30f-5da8-48d0-988f-ab01e23b0b01';

PersonalInventoryRecord template({double grams = 2000}) =>
    PersonalInventoryRecord(
      uid: 'template-not-a-spool',
      manufacturer: 'eSUN',
      model: 'PLA',
      materialType: 'PLA',
      colorHex: '#223344',
      totalGrams: grams,
      remainingGrams: grams,
      createdAt: DateTime.utc(2026, 9, 8),
      updatedAt: DateTime.utc(2026, 9, 8),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<PersonalStockReceipt> receive({
    String uid = operation,
    int quantity = 2,
    String? account = owner,
    String tag = card,
    String type = 'CUID',
    double grams = 2000,
  }) => db.consumableDao.addPersonalStockFromRfidCard(
    operationUid: uid,
    tagUid: tag,
    tagType: type,
    template: template(grams: grams),
    quantity: quantity,
    ownerAccount: account,
  );

  Future<int> count(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
          .read<int>('n');

  test(
    'one reusable card receives several actual spools without binding or altering prior stock',
    () async {
      final first = await receive();
      expect(first.consumableIds, hasLength(2));
      expect(first.inventoryUids.toSet(), hasLength(2));
      expect(
        await db.consumableDao.getRfidSpoolBindingsMap(first.consumableIds),
        isEmpty,
      );
      final sources = await db.consumableDao.getPersonalRfidStockSourcesMap(
        first.consumableIds,
      );
      expect(sources.values.map((s) => s.tagUid), everyElement(card));
      expect(sources.values.map((s) => s.index).toSet(), {0, 1});
      await db.consumableDao.adjustGrams(first.consumableIds.first, 675);
      final second = await receive(
        uid: const Uuid().v4(),
        quantity: 1,
        grams: 500,
      );
      expect(await count('consumables'), 3);
      expect(
        (await db.consumableDao.getById(
          first.consumableIds.first,
        ))!.remainingGrams,
        1325,
      );
      expect(
        (await db.consumableDao.getById(
          second.consumableIds.single,
        ))!.remainingGrams,
        500,
      );
      expect(await count('personal_inventory_events'), 3);
      final events = await db.consumableDao.getPersonalInventoryEvents(owner);
      expect(events.map((e) => e.eventType), everyElement('stock_received'));
      expect(events.map((e) => e.rfidTagUid), everyElement(isNull));
    },
  );

  test(
    'same confirmation is replayed and a modified retry is rejected',
    () async {
      final first = await receive();
      final again = await receive(tag: 'd0:21:b7:5e', type: ' cuid ');
      expect(again.replayed, isTrue);
      expect(again.inventoryUids, first.inventoryUids);
      expect(await count('consumables'), 2);
      expect(await count('personal_inventory_events'), 2);
      await expectLater(receive(quantity: 3), throwsStateError);
      await expectLater(receive(grams: 500), throwsStateError);
      expect(await count('consumables'), 2);
    },
  );

  test(
    'independent confirmations from the same card really add inventory',
    () async {
      await receive(quantity: 1);
      await receive(quantity: 1, uid: const Uuid().v4());
      expect(await count('consumables'), 2);
      expect(await count('personal_stock_receipts'), 2);
    },
  );

  test('failure midway rolls back all stock, events and receipt', () async {
    final secondUid = const Uuid().v5(operation, 'stock:1');
    await db.customStatement(
      '''CREATE TRIGGER fail_second_stock BEFORE INSERT ON consumables
      WHEN NEW.uid = '$secondUid' BEGIN SELECT RAISE(ABORT, 'injected stock failure'); END''',
    );
    await expectLater(receive(), throwsA(anything));
    expect(await count('consumables'), 0);
    expect(await count('personal_inventory_events'), 0);
    expect(await count('personal_stock_receipts'), 0);
  });

  test(
    'receipt survives deleting its stock and never resurrects old rows',
    () async {
      final first = await receive();
      for (final id in first.consumableIds) {
        await db.consumableDao.deleteConsumable(id);
      }
      final again = await receive();
      expect(again.replayed, isTrue);
      expect(again.inventoryUids, first.inventoryUids);
      expect(again.consumableIds, isEmpty);
      expect(await count('consumables'), 0);
      expect(
        (await PersonalAmsIdentityResolver.load(
          db,
        )).resolve('${card}00000100').requiresConfirmation,
        isTrue,
      );
    },
  );

  test(
    'receipt belongs to its account and anonymous claim keeps retry idempotent',
    () async {
      final first = await receive(account: null);
      for (final id in first.consumableIds) {
        await db.consumableDao.setOwnerAccount(id, owner);
      }
      expect((await receive()).replayed, isTrue);
      await expectLater(
        receive(account: 'other@example.com|personal'),
        throwsStateError,
      );
      await expectLater(receive(account: null), throwsStateError);
      expect(await count('consumables'), 2);
    },
  );

  test(
    'unbound sourced stock remains a single 2kg spool and cannot be refilled',
    () async {
      final result = await receive(quantity: 1);
      final id = result.consumableIds.single;
      expect(await db.consumableDao.isIndividualPersonalSpool(id), isTrue);
      await expectLater(db.consumableDao.addOneRoll(id), throwsStateError);
      await db.consumableDao.adjustGrams(id, 250);
      await db.consumableDao.adjustGrams(id, -9999);
      expect((await db.consumableDao.getById(id))!.remainingGrams, 2000);
      expect(await db.consumableDao.deductOneRoll(id), 2000);
      expect((await db.consumableDao.getById(id))!.remainingGrams, 0);
    },
  );

  test(
    'manual aggregate inventory keeps the existing multi-roll behavior',
    () async {
      final id = await db.consumableDao.upsertPersonalInventoryRecord(
        template(),
        ownerAccount: owner,
      );
      expect(await db.consumableDao.isIndividualPersonalSpool(id), isFalse);
      expect(await db.consumableDao.addOneRoll(id), 3000);
      expect(await db.consumableDao.deductOneRoll(id), 1000);
    },
  );

  for (final type in ['NTAG213', 'CLASSIC', 'unknown', 'NTAG213 CUID', 'AMS']) {
    test('$type cannot enter reusable-card receipt inventory', () async {
      await expectLater(receive(type: type), throwsArgumentError);
      expect(await count('consumables'), 0);
    });
  }

  test('invalid quantities, UID and per-spool weights are rejected', () async {
    for (final quantity in [0, -1, 101]) {
      await expectLater(receive(quantity: quantity), throwsArgumentError);
    }
    await expectLater(receive(tag: '04AABBCCDDEEFF'), throwsArgumentError);
    await expectLater(receive(grams: 0), throwsArgumentError);
    await expectLater(receive(grams: double.nan), throwsArgumentError);
    expect(await count('consumables'), 0);
  });

  test(
    'AMS only suggests already received stock until explicit selection',
    () async {
      final receipt = await receive();
      var resolver = await PersonalAmsIdentityResolver.load(db);
      for (final reported in [card, '${card}00000100', '${card}FFFFFFFF']) {
        final identity = resolver.resolve(reported);
        expect(identity.requiresConfirmation, isTrue);
        expect(identity.currentConsumableId, isNull);
        expect(
          identity.stockCandidates.map((c) => c.consumableId).toSet(),
          receipt.consumableIds.toSet(),
        );
      }
      final binding = await db.consumableDao
          .attachPersonalRfidTagToExistingStock(
            consumableId: receipt.consumableIds.first,
            tagUid: card,
            tagType: 'CUID',
            ownerAccount: owner,
          );
      expect(binding.cycle, 1);
      expect(binding.inventoryUid, receipt.inventoryUids.first);
      expect(await count('consumables'), 2);
      await confirmPersonalAmsIdentity(
        db,
        consumableId: binding.consumableId,
        reportedUid: '${card}00000100',
      );
      resolver = await PersonalAmsIdentityResolver.load(db);
      expect(resolver.resolve('${card}00000100').requiresConfirmation, isFalse);
      expect(
        resolver.resolve('${card}00000100').currentConsumableId,
        binding.consumableId,
      );
    },
  );

  test(
    'reused card selects existing next stock without creating or refilling a spool',
    () async {
      final receipt = await receive();
      final first = await db.consumableDao.attachPersonalRfidTagToExistingStock(
        consumableId: receipt.consumableIds.first,
        tagUid: card,
        tagType: 'CUID',
        ownerAccount: owner,
      );
      await db.consumableDao.adjustGrams(first.consumableId, 1500);
      final next = await db.consumableDao.attachPersonalRfidTagToExistingStock(
        consumableId: receipt.consumableIds.last,
        tagUid: card,
        tagType: 'CUID',
        ownerAccount: owner,
      );
      expect(next.cycle, 2);
      expect(next.previousInventoryUid, first.inventoryUid);
      expect(next.inventoryUid, receipt.inventoryUids.last);
      expect(
        (await db.consumableDao.getById(first.consumableId))!.remainingGrams,
        500,
      );
      expect(
        (await db.consumableDao.getById(next.consumableId))!.remainingGrams,
        2000,
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(
          first.consumableId,
        ))!.status,
        'replaced',
      );
      expect(await count('consumables'), 2);
      expect(
        (await db.consumableDao.attachPersonalRfidTagToExistingStock(
          consumableId: next.consumableId,
          tagUid: card,
          tagType: 'CUID',
          ownerAccount: owner,
        )).cycle,
        2,
      );
      await expectLater(
        db.consumableDao.adjustGrams(first.consumableId, -20),
        throwsStateError,
      );
    },
  );

  test(
    'reused card can return to an earlier partial spool without losing its balance',
    () async {
      final receipt = await receive(quantity: 2, grams: 1000);
      final firstId = receipt.consumableIds.first;
      final secondId = receipt.consumableIds.last;
      final first = await db.consumableDao.attachPersonalRfidTagToExistingStock(
        consumableId: firstId,
        tagUid: card,
        tagType: 'CUID',
        ownerAccount: owner,
      );
      await db.consumableDao.adjustGrams(firstId, 585);
      final second = await db.consumableDao
          .attachPersonalRfidTagToExistingStock(
            consumableId: secondId,
            tagUid: card,
            tagType: 'CUID',
            ownerAccount: owner,
          );

      final resumed = await db.consumableDao
          .attachPersonalRfidTagToExistingStock(
            consumableId: firstId,
            tagUid: card,
            tagType: 'CUID',
            ownerAccount: owner,
          );

      expect(first.cycle, 1);
      expect(second.cycle, 2);
      expect(resumed.cycle, 3);
      expect(resumed.previousInventoryUid, second.inventoryUid);
      expect((await db.consumableDao.getById(firstId))!.remainingGrams, 415);
      expect((await db.consumableDao.getById(secondId))!.remainingGrams, 1000);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(firstId))!.status,
        'active',
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(secondId))!.status,
        'replaced',
      );
      final history = await db.consumableDao.getPersonalRfidSpoolHistory(
        card,
        ownerAccount: owner,
      );
      expect(history.map((entry) => entry.cycle), [3, 2, 1]);
      expect(history.map((entry) => entry.consumableId), [
        firstId,
        secondId,
        firstId,
      ]);
      expect(await count('consumables'), 2);
    },
  );

  test(
    'selection cannot activate another account or a different source card',
    () async {
      final receipt = await receive(quantity: 1);
      final id = receipt.consumableIds.single;
      await expectLater(
        db.consumableDao.attachPersonalRfidTagToExistingStock(
          consumableId: id,
          tagUid: card,
          tagType: 'CUID',
          ownerAccount: 'other',
        ),
        throwsStateError,
      );
      await expectLater(
        db.consumableDao.attachPersonalRfidTagToExistingStock(
          consumableId: id,
          tagUid: '04AABBCC',
          tagType: 'CUID',
          ownerAccount: owner,
        ),
        throwsStateError,
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(id))!.tagUid,
        isEmpty,
      );
    },
  );

  test(
    'pending task blocks implicit selection and explicit handoff preserves task segments',
    () async {
      final receipt = await receive();
      final oldId = receipt.consumableIds.first;
      final nextId = receipt.consumableIds.last;
      await db.consumableDao.attachPersonalRfidTagToExistingStock(
        consumableId: oldId,
        tagUid: card,
        tagType: 'CUID',
        ownerAccount: owner,
      );
      final printer = await db
          .into(db.printers)
          .insert(PrintersCompanion.insert(brand: 'Bambu', model: 'P1S'));
      final channel = await db
          .into(db.printerChannels)
          .insert(
            PrinterChannelsCompanion.insert(
              printerId: printer,
              channelIndex: 0,
            ),
          );
      await db.printerDao.bindConsumable(channel, oldId);
      final task = await db.customInsert(
        "INSERT INTO print_tasks(uid,printer_id,gcode_path,task_name,estimated_grams,status,created_at,updated_at) VALUES ('stock-handoff',?,'test','test',100,'printing',1,1)",
        variables: [Variable(printer)],
      );
      await db.customInsert(
        'INSERT INTO print_task_consumables(task_id,printer_id,channel_index,consumable_id,tool_index,estimated_grams,last_deducted_grams,created_at,updated_at) VALUES (?,?,0,?,0,100,25,1,1)',
        variables: [Variable(task), Variable(printer), Variable(oldId)],
      );
      await db.consumableDao.adjustGrams(oldId, 25);
      await expectLater(
        db.consumableDao.attachPersonalRfidTagToExistingStock(
          consumableId: nextId,
          tagUid: card,
          tagType: 'CUID',
          ownerAccount: owner,
        ),
        throwsStateError,
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(oldId))!.isActive,
        isTrue,
      );
      await db.consumableDao.attachPersonalRfidTagToExistingStock(
        consumableId: nextId,
        tagUid: card,
        tagType: 'CUID',
        ownerAccount: owner,
        continueCurrentTask: true,
      );
      final segments = await db
          .customSelect(
            'SELECT * FROM print_task_consumables WHERE task_id = ? ORDER BY id',
            variables: [Variable(task)],
          )
          .get();
      expect(segments, hasLength(2));
      expect(segments.first.read<double>('estimated_grams'), 25);
      expect(segments.first.read<int?>('consumed_at'), isNotNull);
      expect(segments.last.read<double>('estimated_grams'), 75);
      expect(segments.last.read<double>('segment_start_grams'), 25);
      expect(segments.last.read<int>('consumable_id'), nextId);
      expect(
        (await db.select(db.printerChannels).get()).single.consumableId,
        nextId,
      );
      expect(await count('consumables'), 2);
    },
  );

  test(
    'source survives synchronization to another installation and an older omitted-field snapshot',
    () async {
      final session = _session();
      final syncOwner = PersonalInventorySyncService.ownerAccountFor(session);
      final receipt = await receive(account: syncOwner);
      final api = _Api();
      await PersonalInventorySyncService(
        dao: db.consumableDao,
        api: api,
      ).synchronize(session: session);
      expect(
        api.snapshot.records.map((r) => r.sourceRfidTagUid),
        everyElement(card),
      );
      expect(
        api.snapshot.records.map((r) => r.rfidTagUid),
        everyElement(isNull),
      );
      final other = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(other.close);
      await PersonalInventorySyncService(
        dao: other.consumableDao,
        api: api,
      ).synchronize(session: session);
      final otherStock = await other.consumableDao.getPersonal();
      expect(
        otherStock.map((r) => r.uid).toSet(),
        receipt.inventoryUids.toSet(),
      );
      expect(
        (await other.consumableDao.getPersonalRfidStockSourcesMap(
          otherStock.map((r) => r.id),
        )).length,
        2,
      );
      api.snapshot = PersonalInventorySnapshot(
        revision: api.snapshot.revision,
        records: [
          for (final record in api.snapshot.records)
            PersonalInventoryRecord.fromJson({
              ...record.toJson()..removeWhere(
                (key, _) =>
                    key.startsWith('sourceRfid') ||
                    key.startsWith('stockReceipt'),
              ),
              'updatedAt': '2030-01-01T00:00:00Z',
            }),
        ],
      );
      await PersonalInventorySyncService(
        dao: db.consumableDao,
        api: api,
      ).synchronize(session: session);
      expect(
        api.snapshot.records.map((r) => r.sourceRfidTagUid),
        everyElement(card),
      );
    },
  );

  test(
    'v55 upgrade preserves existing stock and creates empty receipt storage',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sohun_stock_migration_',
      );
      final file = File('${directory.path}/stock.sqlite');
      final old = AppDatabase.forTestingAtVersion(NativeDatabase(file), 55);
      await old.consumableDao.upsertPersonalInventoryRecord(
        template().copyWith(
          uid: 'legacy-spool',
          rfidTagUid: card,
          rfidTagType: 'CUID',
          remainingGrams: 777,
        ),
        ownerAccount: owner,
      );
      await old.close();
      final upgraded = AppDatabase.forTesting(NativeDatabase(file));
      try {
        final stock = await upgraded.consumableDao.getPersonal();
        expect(stock.single.uid, 'legacy-spool');
        expect(stock.single.remainingGrams, 777);
        expect(
          (await upgraded.consumableDao.getRfidSpoolBindingById(
            stock.single.id,
          ))!.tagUid,
          card,
        );
        expect(
          await upgraded.consumableDao.getPersonalRfidStockSourcesMap([
            stock.single.id,
          ]),
          isEmpty,
        );
        expect(
          (await upgraded
                  .customSelect(
                    'SELECT COUNT(*) n FROM personal_stock_receipts',
                  )
                  .getSingle())
              .read<int>('n'),
          0,
        );
      } finally {
        await upgraded.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'simultaneous unbound single-spool balance edits retain a reconciliation conflict',
    () async {
      final session = _session();
      final syncOwner = PersonalInventorySyncService.ownerAccountFor(session);
      final receipt = await receive(account: syncOwner, quantity: 1);
      final api = _Api();
      final sync = PersonalInventorySyncService(
        dao: db.consumableDao,
        api: api,
      );
      await sync.synchronize(session: session);
      await db.consumableDao.adjustGrams(receipt.consumableIds.single, 100);
      api.snapshot = PersonalInventorySnapshot(
        revision: api.snapshot.revision + 1,
        records: [
          api.snapshot.records.single.copyWith(
            remainingGrams: 1800,
            updatedAt: DateTime.utc(2030),
          ),
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
      expect(
        (await db.consumableDao.getById(
          receipt.consumableIds.single,
        ))!.remainingGrams,
        1900,
      );
      final conflicts = await db.consumableDao.readInventoryBalanceConflicts(
        receipt.inventoryUids.single,
        ownerAccount: syncOwner,
      );
      expect(conflicts.single.remote.remainingGrams, 1800);
      await db.consumableDao.reconcilePersonalInventoryBalance(
        receipt.consumableIds.single,
        conflicts.single,
        1777,
      );
      await sync.synchronize(session: session);
      expect(api.snapshot.records.single.remainingGrams, 1777);
      expect(api.snapshot.records.single.sourceRfidTagUid, card);
    },
  );

  test(
    'source-stock activation refuses a physical tag still active in another account',
    () async {
      final other = await db.consumableDao.upsertPersonalInventoryRecord(
        template().copyWith(
          uid: 'another-owner-physical-spool',
          rfidTagUid: card,
          rfidTagType: 'CUID',
        ),
        ownerAccount: 'other',
      );
      final receipt = await receive(quantity: 1);
      await expectLater(
        db.consumableDao.attachPersonalRfidTagToExistingStock(
          consumableId: receipt.consumableIds.single,
          tagUid: card,
          tagType: 'CUID',
          ownerAccount: owner,
        ),
        throwsStateError,
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(other))!.isActive,
        isTrue,
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(
          receipt.consumableIds.single,
        ))!.tagUid,
        isEmpty,
      );
    },
  );
}

AppAuthSession _session() => AppAuthSession(
  user: AppUser(
    id: 'stock-owner',
    email: 'stock@example.com',
    handle: 'stock',
    displayName: 'Stock',
    emailVerified: true,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  accessToken: 'stock-test',
  refreshToken: 'stock-refresh',
  expiresAt: DateTime.utc(2030),
  serverBaseUrl: 'https://stock.example.com',
);

class _Api implements PersonalInventoryApi {
  PersonalInventorySnapshot snapshot = const PersonalInventorySnapshot(
    revision: 0,
    records: [],
  );
  @override
  Future<PersonalInventorySnapshot> fetchPersonalInventory({
    required String accessToken,
  }) async => snapshot;
  @override
  Future<PersonalInventorySnapshot> replacePersonalInventory({
    required String accessToken,
    required PersonalInventorySnapshot snapshot,
  }) async {
    this.snapshot = PersonalInventorySnapshot(
      revision: snapshot.revision + 1,
      records: snapshot.records,
      events: snapshot.events,
      deletedUids: snapshot.deletedUids,
    );
    return this.snapshot;
  }
}
