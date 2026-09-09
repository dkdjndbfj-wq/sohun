import 'dart:io';

import 'package:consumable_tracker_desktop/data/database/daos/print_task_consumable_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_task.dart';
import 'package:consumable_tracker_desktop/data/external/print_task/print_task_state_machine.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/gcode_parser.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('commercial review data integrity', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    test('active task uid is unique while terminal history is retained',
        () async {
      Future<int> insertTask(String status) => db.customInsert(
            '''
            INSERT INTO print_tasks (
              uid, gcode_path, task_name, status, created_at, updated_at
            ) VALUES ('job-1', 'test.gcode', 'test', ?, 1, 1)
            ''',
            variables: [Variable(status)],
          );

      await insertTask('printing');
      await expectLater(insertTask('planned'), throwsA(anything));
      await insertTask('finished');
    });

    test('consumable settlement can only be claimed once', () async {
      final taskId = await db.customInsert('''
        INSERT INTO print_tasks (
          uid, gcode_path, task_name, status, created_at, updated_at
        ) VALUES ('job-2', 'test.gcode', 'test', 'printing', 1, 1)
      ''');
      final dao = PrintTaskConsumableDao(db);
      final now = DateTime.now();
      final rows = await dao.createForTask(taskId, [
        PrintTaskConsumable(
          taskId: taskId,
          printerId: null,
          channelIndex: 0,
          toolIndex: 0,
          estimatedGrams: 12,
          createdAt: now,
          updatedAt: now,
        ),
      ]);

      expect(await dao.finalize(rows.single.id!, 12), isTrue);
      expect(await dao.finalize(rows.single.id!, 99), isFalse);
      final settled = (await dao.getByTask(taskId)).single;
      expect(settled.consumedGrams, 12);
      expect(settled.consumedAt, isNotNull);
    });

    test('inventory adjustment reports the clamped amount', () async {
      final id = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
          remainingGrams: const Value(5),
        ),
      );

      expect(await db.consumableDao.adjustGrams(id, 12), 5);
      expect((await db.consumableDao.getById(id))!.remainingGrams, 0);
    });

    test('gram adjustment preserves replenished multi-roll inventory',
        () async {
      final id = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'PLA',
          totalGrams: const Value(1000),
          remainingGrams: const Value(3000),
        ),
      );

      expect(await db.consumableDao.adjustGrams(id, 10), 10);
      expect((await db.consumableDao.getById(id))!.remainingGrams, 2990);
    });

    test('realtime deducted amount emits a dashboard refresh', () async {
      final taskId = await db.customInsert('''
        INSERT INTO print_tasks (
          uid, gcode_path, task_name, status, created_at, updated_at
        ) VALUES ('job-live', 'live.gcode', 'live', 'printing', 1, 1)
      ''');
      final dao = PrintTaskConsumableDao(db);
      final now = DateTime.now();
      final rows = await dao.createForTask(taskId, [
        PrintTaskConsumable(
          taskId: taskId,
          printerId: null,
          channelIndex: 0,
          toolIndex: 0,
          estimatedGrams: 20,
          createdAt: now,
          updatedAt: now,
        ),
      ]);
      final emitted = expectLater(dao.changeStream, emits(anything));

      await dao.updateDeducted(rows.single.id!, 5);

      await emitted;
      expect((await dao.getByTask(taskId)).single.lastDeductedGrams, 5);
    });
  });

  group('commercial review parser regressions', () {
    test('idle at 95 percent is treated as a completed offline print', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.idle,
          lastMcPercent: 95,
        ),
        PrintTaskStatus.finished,
      );
    });

    test('idle on the final layer is treated as completed', () {
      expect(
        PrintTaskStateMachine.translate(
          current: PrintTaskStatus.printing,
          gcodeState: BambuGcodeState.idle,
          lastLayer: 100,
          totalLayers: 100,
        ),
        PrintTaskStatus.finished,
      );
    });

    test('GBK origin path preserves a Chinese model name', () {
      final encoded = gbk.encode(r'C:\Models\中文模型.3mf');
      expect(
        GcodeParser.decodeOriginText(encoded),
        r'C:\Models\中文模型.3mf',
      );
    });

    test('oversized G-code line is rejected without buffering the file',
        () async {
      final dir = await Directory.systemTemp.createTemp('gcode_review_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}large.gcode');
      final oversizedLine = List.filled(64 * 1024 + 1, 'A').join();
      await file.writeAsString('$oversizedLine\n');

      await expectLater(
        GcodeParser.parseFile(file.path),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
