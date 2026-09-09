import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_task_dao.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_task_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        mergedPrinterListProvider.overrideWithValue(const []),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('并发终态只允许一次写入，迟到进度不能覆盖最终数据', () async {
    final taskId = await _seed(db);
    final dao = container.read(printTaskDaoProvider);
    final claims = await Future.wait([
      dao.finish(
        id: taskId,
        actualGrams: 30,
        lastMcPercent: 100,
        lastLayer: 20,
      ),
      dao.finish(
        id: taskId,
        actualGrams: 99,
        status: PrintTaskStatus.cancelled,
      ),
    ]);
    expect(claims.where((value) => value == 1), hasLength(1));
    final finalTask = (await dao.getById(taskId))!;
    expect(
      await dao.updateStatus(id: taskId, status: PrintTaskStatus.printing),
      0,
    );
    expect(
      await dao.updateProgress(
        id: taskId,
        mcPercent: 5,
        layer: 1,
        actualGrams: 1,
      ),
      0,
    );
    final after = (await dao.getById(taskId))!;
    expect(after.status, finalTask.status);
    expect(after.actualGrams, finalTask.actualGrams);
    expect(after.lastMcPercent, finalTask.lastMcPercent);
    expect(after.lastLayer, finalTask.lastLayer);
    expect(after.finishedAt, finalTask.finishedAt);
    if (claims.first == 1) {
      expect(after.lastMcPercent, 100);
      expect(after.lastLayer, 20);
    }
  });

  test('实时扣减拒绝旧基线与已结束任务，不改变已落库的结算信息', () async {
    final taskId = await _seed(db);
    final entries = container.read(printTaskConsumableDaoProvider);
    final entry = (await entries.getByTask(taskId)).single;
    expect(
      await entries.updateDeducted(entry.id!, 25, expectedPrevious: 20),
      isTrue,
    );
    expect(
      await entries.updateDeducted(entry.id!, 22, expectedPrevious: 20),
      isFalse,
    );
    await container
        .read(printTaskDaoProvider)
        .finish(id: taskId, actualGrams: 30);
    expect(await entries.updateDeducted(entry.id!, 5), isFalse);
    expect((await entries.getByTask(taskId)).single.lastDeductedGrams, 25);
    await entries.finalize(entry.id!, 30);
    expect(await entries.updateDeducted(entry.id!, 99), isFalse);
    expect((await entries.getByTask(taskId)).single.lastDeductedGrams, 30);
  });

  test('终态已写入但结算前退出，重启补齐库存和日志且重复恢复不再扣减', () async {
    final taskId = await _seed(db);
    final dao = container.read(printTaskDaoProvider);
    await dao.finish(id: taskId, actualGrams: 30);
    final orchestrator = container.read(printTaskOrchestratorProvider.notifier);
    await orchestrator.recoverPendingSettlements();
    await orchestrator.recoverPendingSettlements();
    expect(await dao.getPendingSettlements(), isEmpty);
    expect((await db.consumableDao.getById(1))!.remainingGrams, 70);
    final logs = await db
        .customSelect('SELECT consumed_grams FROM usage_logs')
        .get();
    expect(logs, hasLength(1));
    expect(logs.single.read<double>('consumed_grams'), 30);
  });

  test('结算写日志失败会回滚库存和认领标记，下一次重试完整补齐', () async {
    final taskId = await _seed(db);
    await db.customStatement('''
      CREATE TRIGGER fail_usage BEFORE INSERT ON usage_logs
      BEGIN SELECT RAISE(ABORT, 'simulated write failure'); END
    ''');
    final dao = container.read(printTaskDaoProvider);
    await dao.finish(id: taskId, actualGrams: 30);
    final orchestrator = container.read(printTaskOrchestratorProvider.notifier);
    await orchestrator.recoverPendingSettlements();
    expect((await db.consumableDao.getById(1))!.remainingGrams, 80);
    expect(await dao.getPendingSettlements(), hasLength(1));

    await db.customStatement('DROP TRIGGER fail_usage');
    await orchestrator.recoverPendingSettlements();
    expect((await db.consumableDao.getById(1))!.remainingGrams, 70);
    expect(await dao.getPendingSettlements(), isEmpty);
    expect(
      await db.customSelect('SELECT * FROM usage_logs').get(),
      hasLength(1),
    );
  });

  test('校准阶段取消不会扣库或记消耗，同时释放待用耗材额度', () async {
    final taskId = await _seed(db, deducted: 0);
    final dao = container.read(printTaskDaoProvider);
    await dao.finish(
      id: taskId,
      actualGrams: 0,
      status: PrintTaskStatus.cancelled,
    );
    await container
        .read(printTaskOrchestratorProvider.notifier)
        .recoverPendingSettlements();
    expect((await db.consumableDao.getById(1))!.remainingGrams, 100);
    expect(await db.customSelect('SELECT * FROM usage_logs').get(), isEmpty);
    expect(await dao.getPendingSettlements(), isEmpty);
    expect(
      await container
          .read(printTaskConsumableDaoProvider)
          .getOutstandingDemandByConsumable(),
      isEmpty,
    );
  });
}

Future<int> _seed(AppDatabase db, {double deducted = 20}) async {
  await db.customInsert(
    "INSERT INTO consumables(id, manufacturer, model, total_grams, remaining_grams) "
    "VALUES (1, 'Test', 'PLA', 100, ?)",
    variables: [Variable(100 - deducted)],
  );
  final taskId = await db.customInsert('''
    INSERT INTO print_tasks(uid, gcode_path, task_name, estimated_grams,
      actual_grams, status, created_at, updated_at)
    VALUES ('recoverable-job', 'sample.gcode', 'test', 30, 20, 'printing', 1, 1)
  ''');
  await db.customInsert(
    '''
    INSERT INTO print_task_consumables(task_id, channel_index, consumable_id,
      tool_index, estimated_grams, last_deducted_grams, created_at, updated_at)
    VALUES (?, 0, 1, 0, 30, ?, 1, 1)
  ''',
    variables: [Variable(taskId), Variable(deducted)],
  );
  return taskId;
}
