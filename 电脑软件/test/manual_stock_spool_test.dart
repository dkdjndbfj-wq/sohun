import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/consumable_dao.dart'
    show inventoryRollCount;
import 'package:consumable_tracker_desktop/data/database/personal_ams_identity.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_inventory_sync.dart';
import 'package:consumable_tracker_desktop/mobile/mobile_rfid_models.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _operation = '8bccb30f-5da8-48d0-988f-ab01e23b0b01';
const _owner = 'manual-spool@example.com|personal';
const _draft = MobileConsumableDraft(
  brand: 'eSUN',
  model: 'PLA',
  color: Colors.blue,
  colorName: '蓝',
);

PersonalInventoryRecord _template() => PersonalInventoryRecord(
  uid: 'template',
  manufacturer: 'eSUN',
  model: 'PLA',
  materialType: 'PLA',
  colorHex: '#0000FF',
  totalGrams: 2000,
  remainingGrams: 2000,
  createdAt: DateTime.utc(2026, 9, 9),
  updatedAt: DateTime.utc(2026, 9, 9),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<PersonalStockReceipt> receive({int quantity = 1}) =>
      db.consumableDao.addPersonalStockManual(
        operationUid: _operation,
        template: _template(),
        quantity: quantity,
        ownerAccount: _owner,
      );

  Future<List<int>> channels() async {
    final printerId = await db
        .into(db.printers)
        .insert(PrintersCompanion.insert(brand: 'Bambu', model: 'P1S'));
    return [
      for (var index = 0; index < 2; index++)
        await db
            .into(db.printerChannels)
            .insert(
              PrinterChannelsCompanion.insert(
                printerId: printerId,
                channelIndex: index,
              ),
            ),
    ];
  }

  test(
    'one manual 2kg roll is one identifiable spool, loads 2kg and cannot occupy a second slot',
    () async {
      final saved = await LocalMobileInventorySync(db.consumableDao)
          .saveManualBatch(
            _draft,
            quantity: 1,
            initialGrams: 2000,
            operationUid: _operation,
          );
      expect(saved, hasLength(1));
      final rows = await db.consumableDao.getPersonal();
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.uid, saved.single.inventoryUid);
      final individual = await db.consumableDao.isIndividualPersonalSpool(
        row.id,
      );
      expect(individual, isTrue);
      expect(
        inventoryRollCount(row.remainingGrams, individualSpool: individual),
        1,
      );
      final ids = await channels();
      await db.printerDao.bindConsumable(ids.first, row.id);
      expect(
        (await (db.select(
              db.printerChannels,
            )..where((r) => r.id.equals(ids.first))).getSingle())
            .loadedRemainingGrams,
        2000,
      );
      await expectLater(
        db.printerDao.bindConsumable(ids.last, row.id),
        throwsStateError,
      );
      expect(
        (await (db.select(
          db.printerChannels,
        )..where((r) => r.id.equals(ids.last))).getSingle()).consumableId,
        isNull,
      );
    },
  );

  test(
    'legacy aggregate 2kg remains two standard rolls and can occupy two slots',
    () async {
      final id = await db.consumableDao.upsertPersonalInventoryRecord(
        _template().copyWith(uid: 'legacy-aggregate'),
        ownerAccount: _owner,
      );
      expect(await db.consumableDao.isIndividualPersonalSpool(id), isFalse);
      expect(inventoryRollCount(2000), 2);
      for (final channelId in await channels()) {
        await db.printerDao.bindConsumable(channelId, id);
      }
      final loaded = await db.select(db.printerChannels).get();
      expect(loaded.map((r) => r.loadedRemainingGrams), everyElement(1000));
      expect(loaded.map((r) => r.consumableId), everyElement(id));
    },
  );

  test(
    'manual receipt retry is idempotent and a changed quantity is rejected',
    () async {
      final first = await receive(quantity: 2);
      final replay = await receive(quantity: 2);
      expect(replay.replayed, isTrue);
      expect(replay.inventoryUids, first.inventoryUids);
      expect(await db.consumableDao.getPersonal(), hasLength(2));
      expect(
        await db.consumableDao.getPersonalInventoryEvents(_owner),
        hasLength(2),
      );
      await expectLater(receive(quantity: 3), throwsStateError);
      expect(await db.consumableDao.getPersonal(), hasLength(2));
    },
  );

  test(
    'mobile explicit operation retries preserve the same manual roll IDs',
    () async {
      final sync = LocalMobileInventorySync(db.consumableDao);
      final first = await sync.saveManualBatch(
        _draft,
        quantity: 2,
        initialGrams: 2000,
        operationUid: _operation,
      );
      final second = await sync.saveManualBatch(
        _draft,
        quantity: 2,
        initialGrams: 2000,
        operationUid: _operation,
      );
      expect(
        second.map((r) => r.inventoryUid),
        first.map((r) => r.inventoryUid),
      );
      expect(await db.consumableDao.getPersonal(), hasLength(2));
    },
  );

  test(
    'manual receipt carries no card identity and AMS never resolves it as a source card',
    () async {
      final receipt = await receive();
      final id = receipt.consumableIds.single;
      final source = (await db.consumableDao.getPersonalRfidStockSourcesMap([
        id,
      ]))[id]!;
      expect(source.receiptUid, _operation);
      expect(source.tagUid, isNull);
      expect(source.tagType, isNull);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(id))!.tagUid,
        isEmpty,
      );
      final events = await db.consumableDao.getPersonalInventoryEvents(_owner);
      expect(events.single.rfidTagUid, isNull);
      final resolver = await PersonalAmsIdentityResolver.load(db);
      for (final reported in ['D021B75E', 'D021B75E00000100']) {
        final identity = resolver.resolve(reported);
        expect(identity.currentConsumableId, isNull);
        expect(identity.stockCandidates, isEmpty);
        expect(identity.sourceTagUids, isEmpty);
        expect(identity.isPersonalTag, isFalse);
      }
      await expectLater(
        db.consumableDao.attachPersonalRfidTagToExistingStock(
          consumableId: id,
          tagUid: 'D021B75E',
          tagType: 'CUID',
          ownerAccount: _owner,
        ),
        throwsStateError,
      );
    },
  );

  for (final remote in [false, true]) {
    test(
      '${remote ? 'cloud' : 'local'} deletion protects a loaded manual spool',
      () async {
        final receipt = await receive();
        final id = receipt.consumableIds.single;
        final channelId = (await channels()).first;
        await db.printerDao.bindConsumable(channelId, id);
        await expectLater(
          remote
              ? db.consumableDao.deletePersonalByUid(
                  receipt.inventoryUids.single,
                  ownerAccount: _owner,
                )
              : db.consumableDao.deleteConsumable(id),
          throwsStateError,
        );
        expect(await db.consumableDao.getById(id), isNotNull);
        expect(
          (await (db.select(
            db.printerChannels,
          )..where((r) => r.id.equals(channelId))).getSingle()).consumableId,
          id,
        );
      },
    );
  }

  test(
    'manual spool receipt remains durable after unoccupied stock is deleted',
    () async {
      final receipt = await receive();
      expect(
        await db.consumableDao.deleteConsumable(receipt.consumableIds.single),
        1,
      );
      final replay = await receive();
      expect(replay.replayed, isTrue);
      expect(replay.consumableIds, isEmpty);
      expect(await db.consumableDao.getPersonal(), isEmpty);
      expect(
        (await db
                .customSelect(
                  'SELECT COUNT(*) n FROM personal_stock_receipts WHERE operation_uid = ?',
                  variables: [const Variable(_operation)],
                )
                .getSingle())
            .read<int>('n'),
        1,
      );
    },
  );
}
