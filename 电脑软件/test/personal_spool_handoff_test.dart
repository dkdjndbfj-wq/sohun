import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_task_dao.dart';
import 'package:consumable_tracker_desktop/data/models/personal_inventory_sync.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_task_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const owner = 'handoff@example.com|personal';
  late AppDatabase db;
  late ProviderContainer container;
  late int printerId, channelId, oldId, newId;

  Future<int> spool(String uid, String tag, double grams) =>
      db.consumableDao.upsertPersonalInventoryRecord(
        PersonalInventoryRecord(
          uid: uid,
          manufacturer: 'Test',
          model: 'PLA',
          materialType: 'PLA',
          colorHex: '#FFFFFF',
          totalGrams: 1000,
          remainingGrams: grams,
          createdAt: DateTime.utc(2026, 9, 6),
          updatedAt: DateTime.utc(2026, 9, 6),
          rfidTagUid: tag,
          rfidTagType: 'CUID',
        ),
        ownerAccount: owner,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mergedPrinterListProvider.overrideWithValue(const []),
      ],
    );
    oldId = await spool('old-spool', '04AABB01', 750);
    newId = await spool('new-spool', '04AABB02', 1000);
    printerId = await db
        .into(db.printers)
        .insert(
          PrintersCompanion.insert(
            brand: 'Test',
            model: 'P1',
            name: const Value('工作台'),
          ),
        );
    channelId = await db
        .into(db.printerChannels)
        .insert(
          PrinterChannelsCompanion.insert(
            printerId: printerId,
            channelIndex: 0,
          ),
        );
    await db.printerDao.bindConsumable(channelId, oldId);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<int> task({double deducted = 20, int tool = 0, int? taskId}) async {
    final id =
        taskId ??
        await db.customInsert(
          "INSERT INTO print_tasks(uid, printer_id, gcode_path, task_name, estimated_grams, "
          "actual_grams, status, created_at, updated_at) VALUES ('handoff-job', ?, "
          "'sample.gcode', 'test', 100, ?, 'printing', 1, 1)",
          variables: [Variable(printerId), Variable(deducted)],
        );
    await db.customInsert(
      'INSERT INTO print_task_consumables(task_id, printer_id, channel_index, consumable_id, '
      'tool_index, estimated_grams, last_deducted_grams, created_at, updated_at) '
      'VALUES (?, ?, 0, ?, ?, 100, ?, 1, 1)',
      variables: [
        Variable(id),
        Variable(printerId),
        Variable(oldId),
        Variable(tool),
        Variable(deducted),
      ],
    );
    await db.consumableDao.adjustGrams(oldId, deducted);
    return id;
  }

  Future<void> finish(int id, double grams, {bool cancelled = false}) async {
    await container
        .read(printTaskDaoProvider)
        .finish(
          id: id,
          actualGrams: grams,
          status: cancelled
              ? PrintTaskStatus.cancelled
              : PrintTaskStatus.finished,
        );
    await container
        .read(printTaskOrchestratorProvider.notifier)
        .recoverPendingSettlements();
  }

  Future<List<double>> usage(int id) async =>
      (await db
              .customSelect(
                'SELECT consumed_grams FROM usage_logs WHERE consumable_id = ? ORDER BY id',
                variables: [Variable(id)],
              )
              .get())
          .map((r) => r.read<double>('consumed_grams'))
          .toList();

  test(
    '1 kg roll and 31 g remnant retain actual weight without repeat consumption',
    () async {
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: newId,
        manualRemainingGrams: 31,
      );
      expect((await db.consumableDao.getById(oldId))!.totalGrams, 1000);
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 31);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(oldId))!.isActive,
        isTrue,
      );
      expect(await usage(oldId), [719]);
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: oldId,
        manualRemainingGrams: 800,
      );
      expect((await db.consumableDao.getById(newId))!.totalGrams, 1000);
      expect(await usage(newId), [200]);
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: newId,
      );
      expect(await usage(oldId), [719]);
      await db.printerDao.finishChannel(channelId);
      expect((await db.consumableDao.getById(newId))!.remainingGrams, 0);
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(newId))!.status,
        'depleted',
      );
      expect(await usage(newId), [200, 800]);
    },
  );

  test(
    'weighing rejects non-finite and over-capacity values without changing bindings',
    () async {
      for (final grams in [double.nan, double.infinity, -1.0, 1001.0]) {
        await expectLater(
          db.printerDao.changeRoll(
            channelId: channelId,
            newConsumableId: newId,
            manualRemainingGrams: grams,
          ),
          throwsArgumentError,
        );
      }
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 750);
      expect(await db.printerDao.getConsumableIdByChannel(printerId, 0), oldId);
      expect(await usage(oldId), isEmpty);
    },
  );

  test(
    'mid-task handoff closes old segment; restart recovery settles new only once',
    () async {
      final id = await task();
      final dao = container.read(printTaskConsumableDaoProvider);
      final stale = (await dao.getByTask(id)).single;
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: newId,
      );
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: newId,
      );
      var entries = await dao.getByTask(id);
      expect(entries, hasLength(2));
      expect(entries.first.consumedAt, isNotNull);
      expect(entries.last.segmentStartGrams, 20);
      expect(entries.last.estimatedGrams, 80);
      expect(entries.last.estimatedConsumedAt(50), 30);
      expect(
        await dao.updateDeducted(stale.id!, 50, expectedPrevious: 20),
        isFalse,
      );
      expect(await usage(oldId), [20]);
      // Reconstruct the providers as on process restart; accounting comes from DB.
      container.dispose();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          mergedPrinterListProvider.overrideWithValue(const []),
        ],
      );
      await finish(id, 120);
      await container
          .read(printTaskOrchestratorProvider.notifier)
          .recoverPendingSettlements();
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 730);
      expect((await db.consumableDao.getById(newId))!.remainingGrams, 900);
      expect(await usage(newId), [100]);
      final events = await db.consumableDao.getPersonalInventoryEvents(owner);
      final usageEvents = events.where((e) => e.source == 'usage').toList();
      expect(usageEvents.map((e) => e.taskUid), everyElement('handoff-job'));
      expect(
        usageEvents.map((e) => e.deltaGrams).reduce((a, b) => a! + b!),
        -120,
      );
    },
  );

  test(
    'repeated swap and reusing the original remnant preserve all three segments',
    () async {
      final id = await task();
      final dao = container.read(printTaskConsumableDaoProvider);
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: newId,
      );
      final second = (await dao.getByTask(id)).last;
      final plan = planRealtimeConsumableDeduction(
        estimatedGrams: second.estimatedGrams,
        segmentStartGrams: second.segmentStartGrams,
        mcPercent: 60,
        lastDeductedGrams: 0,
        maintenancePaused: false,
      );
      await db.transaction(() async {
        await db.consumableDao.adjustGrams(newId, plan.inventoryDelta);
        await dao.updateDeducted(
          second.id!,
          plan.inventoryDelta,
          expectedPrevious: 0,
        );
      });
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: oldId,
      );
      final entries = await dao.getByTask(id);
      expect(entries.map((e) => e.consumableId), [oldId, newId, oldId]);
      expect(entries.last.segmentStartGrams, 60);
      expect(entries.fold(0.0, (sum, e) => sum + e.estimatedGrams), 100);
      await finish(id, 80, cancelled: true);
      expect(await usage(oldId), [20, 20]);
      expect(await usage(newId), [40]);
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 710);
      expect((await db.consumableDao.getById(newId))!.remainingGrams, 960);
    },
  );

  test(
    'failure during handoff rolls back both task segments, inventory and events',
    () async {
      final id = await task();
      final before = (await db.consumableDao.getPersonalInventoryEvents(
        owner,
      )).length;
      await db.customStatement(
        "CREATE TRIGGER fail_handoff BEFORE INSERT ON usage_logs "
        "BEGIN SELECT RAISE(ABORT, 'test write failure'); END",
      );
      await expectLater(
        db.printerDao.changeRoll(channelId: channelId, newConsumableId: newId),
        throwsA(anything),
      );
      expect(
        await container.read(printTaskConsumableDaoProvider).getByTask(id),
        hasLength(1),
      );
      expect(await db.printerDao.getConsumableIdByChannel(printerId, 0), oldId);
      expect(
        (await db.consumableDao.getPersonalInventoryEvents(owner)).length,
        before,
      );
      await db.customStatement('DROP TRIGGER fail_handoff');
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: newId,
      );
      expect(await usage(oldId), [20]);
    },
  );

  test(
    'active task cannot be erased by finish, direct bind, move or metadata remapping',
    () async {
      final id = await task();
      await expectLater(
        db.printerDao.finishChannel(channelId),
        throwsStateError,
      );
      await expectLater(
        db.printerDao.unbindChannel(channelId),
        throwsStateError,
      );
      await expectLater(
        db.printerDao.bindConsumable(channelId, newId),
        throwsStateError,
      );
      await expectLater(
        db.printerDao.changeRoll(
          channelId: channelId,
          newConsumableId: newId,
          manualRemainingGrams: 600,
        ),
        throwsStateError,
      );
      await expectLater(
        container.read(printTaskConsumableDaoProvider).updateExternalMappings(
          id,
          [
            (
              toolIndex: 0,
              consumableId: newId,
              costPerKg: null,
              costConfigId: null,
            ),
          ],
        ),
        throwsStateError,
      );
      await expectLater(
        db.printerDao.bindSpoolReplacement(
          printerId: printerId,
          channelIndex: 1,
          consumableId: oldId,
          uniquePhysicalSpool: true,
        ),
        throwsStateError,
      );
      expect(await db.printerDao.getConsumableIdByChannel(printerId, 0), oldId);
      expect(await usage(oldId), isEmpty);
    },
  );

  test(
    'same CUID starts a new cycle and continues the local task atomically',
    () async {
      final id = await task();
      final next = await db.consumableDao.replacePersonalRfidSpool(
        consumableId: oldId,
        initialGrams: 1000,
        continueCurrentTask: true,
      );
      expect(next.cycle, 2);
      expect(next.tagUid, '04AABB01');
      expect(
        await db.printerDao.getConsumableIdByChannel(printerId, 0),
        next.consumableId,
      );
      expect(
        (await db.consumableDao.getRfidSpoolBindingById(oldId))!.status,
        'replaced',
      );
      await finish(id, 100);
      expect(await usage(oldId), [20]);
      expect(await usage(next.consumableId), [80]);
      expect((await db.consumableDao.getById(oldId))!.remainingGrams, 730);
      expect(
        (await db.consumableDao.getById(next.consumableId))!.remainingGrams,
        920,
      );
    },
  );

  test(
    'two tools and concurrent duplicate swaps retain each tool budget',
    () async {
      final id = await task();
      await task(taskId: id, tool: 1, deducted: 10);
      await Future.wait([
        db.printerDao.changeRoll(channelId: channelId, newConsumableId: newId),
        db.printerDao.changeRoll(channelId: channelId, newConsumableId: newId),
      ]);
      final entries = await container
          .read(printTaskConsumableDaoProvider)
          .getByTask(id);
      expect(entries, hasLength(4));
      expect(entries.fold(0.0, (sum, e) => sum + e.estimatedGrams), 200);
      await finish(id, 200);
      expect(await usage(oldId), [20, 10]);
      expect(await usage(newId), [80, 90]);
    },
  );

  test(
    'failed final settlement retries without repeating the sealed old segment',
    () async {
      final id = await task();
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: newId,
      );
      await db.customStatement(
        "CREATE TRIGGER fail_final BEFORE INSERT ON usage_logs "
        "BEGIN SELECT RAISE(ABORT, 'test final write failure'); END",
      );
      await finish(id, 50, cancelled: true);
      expect((await db.consumableDao.getById(newId))!.remainingGrams, 1000);
      expect(await usage(oldId), [20]);
      await db.customStatement('DROP TRIGGER fail_final');
      await container
          .read(printTaskOrchestratorProvider.notifier)
          .recoverPendingSettlements();
      expect(await usage(newId), [30]);
      expect(await usage(oldId), [20]);
    },
  );

  test(
    'zero-progress handoff followed by cancellation writes no consumption',
    () async {
      final id = await task(deducted: 0);
      await db.printerDao.changeRoll(
        channelId: channelId,
        newConsumableId: newId,
      );
      await finish(id, 0, cancelled: true);
      expect(await usage(oldId), isEmpty);
      expect(await usage(newId), isEmpty);
      expect((await db.consumableDao.getById(newId))!.remainingGrams, 1000);
    },
  );
}
