import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _owner = 'stock-delete@example.com|personal';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Consumable stock;
  late int printerId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final receipt = await db.consumableDao.addPersonalStockFromRfidCard(
      operationUid: '8bccb30f-5da8-48d0-988f-ab01e23b0b01',
      tagUid: 'D021B75E',
      tagType: 'CUID',
      template: PersonalInventoryRecord(
        uid: 'unused-template',
        manufacturer: 'eSUN',
        model: 'PLA',
        materialType: 'PLA',
        colorHex: '#2244CC',
        totalGrams: 2000,
        remainingGrams: 1500,
        createdAt: DateTime.utc(2026, 9, 9),
        updatedAt: DateTime.utc(2026, 9, 9),
      ),
      quantity: 1,
      ownerAccount: _owner,
    );
    stock = (await db.consumableDao.getById(receipt.consumableIds.single))!;
    printerId = await db
        .into(db.printers)
        .insert(PrintersCompanion.insert(brand: 'Bambu', model: 'P1S'));
  });
  tearDown(() => db.close());

  Future<int> addPendingTask() async {
    final taskId = await db.customInsert(
      'INSERT INTO print_tasks(uid, printer_id, gcode_path, task_name, '
      'estimated_grams, status, created_at, updated_at) '
      "VALUES ('stock-delete-task', ?, 'test', 'test', 100, 'printing', 1, 1)",
      variables: [Variable(printerId)],
    );
    return db.customInsert(
      'INSERT INTO print_task_consumables(task_id, printer_id, channel_index, '
      'consumable_id, tool_index, estimated_grams, last_deducted_grams, '
      'created_at, updated_at) VALUES (?, ?, 0, ?, 0, 100, 25, 1, 1)',
      variables: [Variable(taskId), Variable(printerId), Variable(stock.id)],
    );
  }

  Future<int> loadStock() async {
    final id = await db
        .into(db.printerChannels)
        .insert(
          PrinterChannelsCompanion.insert(
            printerId: printerId,
            channelIndex: 0,
          ),
        );
    await db.printerDao.bindConsumable(id, stock.id);
    return id;
  }

  Future<void> expectStockIntact() async {
    expect((await db.consumableDao.getById(stock.id))!.remainingGrams, 1500);
    expect(
      await db.consumableDao.getPersonalInventoryTombstones(_owner),
      isEmpty,
    );
    expect(
      (await db.consumableDao.getPersonalRfidStockSourcesMap([
        stock.id,
      ]))[stock.id],
      isNotNull,
    );
  }

  for (final remote in [false, true]) {
    Future<int> remove() => remote
        ? db.consumableDao.deletePersonalByUid(stock.uid, ownerAccount: _owner)
        : db.consumableDao.deleteConsumable(stock.id);
    final method = remote ? 'snapshot deletion' : 'local deletion';

    test(
      '$method rejects unbound received stock with an unsettled task',
      () async {
        final segmentId = await addPendingTask();
        await expectLater(remove(), throwsStateError);
        await expectStockIntact();
        final segment = await db
            .customSelect(
              'SELECT consumable_id, consumed_at FROM print_task_consumables WHERE id = ?',
              variables: [Variable(segmentId)],
            )
            .getSingle();
        expect(segment.read<int?>('consumable_id'), stock.id);
        expect(segment.read<int?>('consumed_at'), isNull);
      },
    );

    test(
      '$method rejects unbound received stock still loaded in a channel',
      () async {
        final channelId = await loadStock();
        final before = await (db.select(
          db.printerChannels,
        )..where((row) => row.id.equals(channelId))).getSingle();
        await expectLater(remove(), throwsStateError);
        await expectStockIntact();
        final after = await (db.select(
          db.printerChannels,
        )..where((row) => row.id.equals(channelId))).getSingle();
        expect(after, before);
      },
    );

    test(
      '$method allows unoccupied received stock and preserves its receipt',
      () async {
        expect(await remove(), 1);
        expect(await db.consumableDao.getById(stock.id), isNull);
        expect(
          (await db
                  .customSelect(
                    'SELECT COUNT(*) n FROM personal_stock_receipts',
                  )
                  .getSingle())
              .read<int>('n'),
          1,
        );
      },
    );
  }

  test(
    'snapshot import rolls back earlier deletions when a later spool is occupied',
    () async {
      final second = await db.consumableDao.addPersonalStockFromRfidCard(
        operationUid: '8bccb30f-5da8-48d0-988f-ab01e23b0b02',
        tagUid: 'D021B75E',
        tagType: 'CUID',
        template: PersonalInventoryRecord(
          uid: 'unused-template',
          manufacturer: stock.manufacturer,
          model: stock.model,
          materialType: stock.materialType,
          colorHex: stock.colorHex,
          totalGrams: 500,
          remainingGrams: 500,
          createdAt: stock.createdAt,
          updatedAt: stock.updatedAt,
        ),
        quantity: 1,
        ownerAccount: _owner,
      );
      final segmentId = await addPendingTask();
      await expectLater(
        db.transaction(() async {
          await db.consumableDao.deletePersonalByUid(
            second.inventoryUids.single,
            ownerAccount: _owner,
          );
          await db.consumableDao.deletePersonalByUid(
            stock.uid,
            ownerAccount: _owner,
          );
        }),
        throwsStateError,
      );
      await expectStockIntact();
      expect(
        await db.consumableDao.getById(second.consumableIds.single),
        isNotNull,
      );
      expect(
        (await db
                .customSelect(
                  'SELECT consumable_id FROM print_task_consumables WHERE id = ?',
                  variables: [Variable(segmentId)],
                )
                .getSingle())
            .read<int?>('consumable_id'),
        stock.id,
      );
      expect(
        await db.consumableDao.deletePersonalByUid(
          stock.uid,
          ownerAccount: 'another-account',
        ),
        0,
      );
    },
  );
}
