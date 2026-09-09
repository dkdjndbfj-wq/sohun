import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_task.dart';
import 'package:consumable_tracker_desktop/providers/batch_recognition_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'batch_recognition_enabled': true,
    });
  });

  test('批次识别覆盖后台任务，并把文件名下划线当普通字符', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement(
      "INSERT INTO printers(id, brand, model, serial) VALUES "
      "(1, 'Bambu Lab', 'P1S', 'BATCH-A'), "
      "(2, 'Bambu Lab', 'P1S', 'BATCH-B')",
    );
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    container.read(batchRecognitionProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final dao = container.read(printTaskDaoProvider);
    final firstId = await dao.create(
      _task(
        uid: 'batch-task-1',
        printerId: 1,
        path: r'C:\jobs\part_1.gcode',
      ),
    );
    final firstBatch = await _waitForBatch(db, firstId);
    expect(firstBatch, isNotNull);

    final wildcardLookalikeId = await dao.create(
      _task(
        uid: 'batch-task-2',
        printerId: 2,
        path: r'C:\jobs\partA1.gcode',
      ),
    );
    final wildcardLookalikeBatch = await _waitForBatch(db, wildcardLookalikeId);
    expect(wildcardLookalikeBatch, isNot(firstBatch));

    final matchingBackgroundId = await dao.create(
      _task(
        uid: 'batch-task-3',
        printerId: 2,
        path: r'D:\queue\part_1.gcode',
      ),
    );
    final matchingBatch = await _waitForBatch(db, matchingBackgroundId);
    expect(matchingBatch, firstBatch);
  });
}

PrintTask _task({
  required String uid,
  required int printerId,
  required String path,
}) {
  final now = DateTime.now();
  return PrintTask(
    uid: uid,
    printerId: printerId,
    gcodePath: path,
    taskName: path.split(r'\').last,
    estimatedGrams: 10,
    estimatedSeconds: 60,
    actualGrams: 0,
    startedAt: now,
    lastMcPercent: 0,
    lastLayer: 0,
    status: PrintTaskStatus.printing,
    source: 'test',
    perFilamentGrams: const [10],
    createdAt: now,
    updatedAt: now,
  );
}

Future<String?> _waitForBatch(AppDatabase db, int taskId) async {
  for (var i = 0; i < 100; i++) {
    final row = await db.customSelect(
      'SELECT batch_id FROM print_tasks WHERE id = ?',
      variables: [Variable<int>(taskId)],
    ).getSingle();
    final value = row.data['batch_id'] as String?;
    if (value != null && value.isNotEmpty) return value;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return null;
}
