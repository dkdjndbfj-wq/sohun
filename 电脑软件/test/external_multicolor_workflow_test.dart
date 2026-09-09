import 'dart:io';

import 'package:consumable_tracker_desktop/data/database/daos/print_task_consumable_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/filament_change_point.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/gcode_parser.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/slice_result.dart';
import 'package:consumable_tracker_desktop/providers/external_multicolor_plan_provider.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_task_provider.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('external multicolor G-code facts', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('external_multicolor_');
    });

    tearDown(() => dir.delete(recursive: true));

    test('keeps a three-color cycle and ignores reserved tool commands',
        () async {
      final file = File('${dir.path}/cycle.gcode');
      await file.writeAsString('''
; HEADER_BLOCK_START
; BambuStudio 02.07.01.57
; total filament weight [g] : 4,5,6
; total filament length [mm] : 1000,1200,1400
; total layer number: 30
; toolchange count: 3
; filament_colour = #FF3344;#33CC77;#3377FF
; filament_type = PLA;PLA;PETG
; HEADER_BLOCK_END
T0 ; initial tool
;LAYER:0
G1 X1 Y1
;LAYER:5
T1 ; green
;LAYER:10
T2
;LAYER:15
T0
T255
T1000
''');

      final result = await GcodeParser.parseFile(file.path);

      expect(result, isNotNull);
      expect(result!.filamentChangePoints.map((point) => point.toolIndex), [
        1,
        2,
        0,
      ]);
      expect(
        result.filamentChangePoints.map((point) => point.previousToolIndex),
        [0, 1, 2],
      );
      expect(
        result.filamentChangePoints.map((point) => point.colorHex),
        ['#33CC77', '#3377FF', '#FF3344'],
      );
    });

    test('M600 uses a following target tool and never guesses T plus one',
        () async {
      final file = File('${dir.path}/m600.gcode');
      await file.writeAsString('''
; filament_colour = #111111;#222222;#ABCDEF
; filament_type = PLA;PLA;PETG
T0
;LAYER:8
M600
T2
;LAYER:12
M600
''');

      final points = await GcodeParser.parseFilamentChangeLayers(file.path);

      expect(points, hasLength(2));
      expect(points.first.toolIndex, 2);
      expect(points.first.previousToolIndex, 0);
      expect(points.first.colorHex, '#ABCDEF');
      expect(points.last.toolIndex, -1);
      expect(points.last.colorHex, isNull);
    });

    test('loaded colors without positive usage and changes do not prompt',
        () async {
      final file = File('${dir.path}/single.gcode');
      await file.writeAsString('''
; HEADER_BLOCK_START
; BambuStudio 02.07.01.57
; total filament weight [g] : 12
; total filament length [mm] : 3900
; total layer number: 10
; filament_colour = #FF0000;#00FF00;#0000FF;#FFFFFF
; filament_type = PLA;PLA;PLA;PLA
; HEADER_BLOCK_END
;LAYER:0
T0
;LAYER:9
T255
''');

      final result = await GcodeParser.parseFile(file.path);

      expect(result, isNotNull);
      expect(result!.filaments, hasLength(1));
      expect(result.filamentChangePoints, isEmpty);
      expect(
        isExternalMulticolorPrint(
          slice: result,
          hasAms: false,
          trayNow: '254',
        ),
        isFalse,
      );
    });

    test('zero-use colors do not shift later tool identities', () async {
      final file = File('${dir.path}/sparse-tools.gcode');
      await file.writeAsString('''
; total filament weight [g] : 0,5,6
; total filament length [mm] : 0,1200,1400
; filament_colour = #111111;#22AA22;#2244CC
; filament_type = PLA;PLA;PETG
; toolchange count: 1
T1
;LAYER:0
G1 X1
;LAYER:4
T2
''');

      final result = await GcodeParser.parseFile(file.path);

      expect(result!.filaments.map((item) => item.toolIndex), [1, 2]);
      expect(result.filamentChangePoints.single.previousToolIndex, 1);
      expect(result.filamentChangePoints.single.toolIndex, 2);
      expect(result.filamentChangePoints.single.colorHex, '#2244CC');
    });

    test('external detection distinguishes manual and normal AMS mappings', () {
      SliceResult slice(List<int>? mapping) => SliceResult(
            filePath: 'three.gcode',
            taskName: 'three',
            filaments: [
              FilamentUsage(toolIndex: 0, grams: 5, lengthMm: 1),
              FilamentUsage(toolIndex: 1, grams: 4, lengthMm: 1),
              FilamentUsage(toolIndex: 2, grams: 3, lengthMm: 1),
            ],
            filamentChangePoints: const [
              FilamentChangePoint(
                layerNum: 5,
                toolIndex: 1,
                previousToolIndex: 0,
              ),
            ],
            estimatedSeconds: 10,
            toolChangeCount: 1,
            totalLayers: 20,
            slicerName: 'test',
            amsMapping: mapping,
          );

      expect(
        isExternalMulticolorPrint(
          slice: slice(null),
          hasAms: false,
          trayNow: '254',
        ),
        isTrue,
      );
      expect(
        isExternalMulticolorPrint(
          slice: slice([0, 1, 2]),
          hasAms: true,
          trayNow: '1',
        ),
        isFalse,
      );
      expect(
        externalFilamentsRequiringPlan(
          slice: slice([0, 255, 2]),
          hasAms: true,
          trayNow: '0',
        ).map((item) => item.toolIndex),
        [1],
      );
    });
  });

  group('external color inventory mapping', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    test('maps each tool to its own stock spool atomically', () async {
      final redId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'Red PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#FF0000'),
          remainingGrams: const Value(800),
        ),
      );
      final blueId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'Blue PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#0000FF'),
          remainingGrams: const Value(900),
        ),
      );
      final taskId = await db.customInsert('''
        INSERT INTO print_tasks (
          uid, gcode_path, task_name, status, created_at, updated_at
        ) VALUES ('external-map', 'map.gcode', 'map', 'printing', 1, 1)
      ''');
      final dao = PrintTaskConsumableDao(db);
      final now = DateTime(2026, 8, 2);
      await dao.createForTask(taskId, [
        PrintTaskConsumable(
          taskId: taskId,
          printerId: null,
          channelIndex: 0,
          toolIndex: 0,
          estimatedGrams: 10,
          createdAt: now,
          updatedAt: now,
        ),
        PrintTaskConsumable(
          taskId: taskId,
          printerId: null,
          channelIndex: 0,
          toolIndex: 1,
          estimatedGrams: 8,
          createdAt: now,
          updatedAt: now,
        ),
      ]);

      await dao.updateExternalMappings(taskId, [
        (
          toolIndex: 0,
          consumableId: redId,
          costPerKg: 80,
          costConfigId: null,
        ),
        (
          toolIndex: 1,
          consumableId: blueId,
          costPerKg: 90,
          costConfigId: null,
        ),
      ]);

      final rows = await dao.getByTask(taskId);
      expect(rows.map((row) => row.consumableId), [redId, blueId]);
      expect(rows.map((row) => row.costPerKgSnapshot), [80, 90]);

      await dao.finalize(rows.first.id!, 10);
      await expectLater(
        dao.updateExternalMappings(taskId, [
          (
            toolIndex: 0,
            consumableId: blueId,
            costPerKg: null,
            costConfigId: null,
          ),
          (
            toolIndex: 1,
            consumableId: redId,
            costPerKg: null,
            costConfigId: null,
          ),
        ]),
        throwsA(isA<StateError>()),
      );
      final unchanged = await dao.getByTask(taskId);
      expect(unchanged.map((row) => row.consumableId), [redId, blueId]);
    });

    test('shared stock uses combined demand and can be restocked atomically',
        () async {
      final sharedId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'Green PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#00AA55'),
          remainingGrams: const Value(25),
        ),
      );
      final taskId = await db.customInsert('''
        INSERT INTO print_tasks (
          uid, gcode_path, task_name, status, created_at, updated_at
        ) VALUES ('shared-map', 'shared.gcode', 'shared', 'printing', 1, 1)
      ''');
      final dao = PrintTaskConsumableDao(db);
      final now = DateTime(2026, 8, 2);
      await dao.createForTask(taskId, [
        PrintTaskConsumable(
          taskId: taskId,
          printerId: null,
          channelIndex: 0,
          toolIndex: 0,
          estimatedGrams: 12,
          createdAt: now,
          updatedAt: now,
        ),
        PrintTaskConsumable(
          taskId: taskId,
          printerId: null,
          channelIndex: 0,
          toolIndex: 1,
          estimatedGrams: 8,
          createdAt: now,
          updatedAt: now,
        ),
      ]);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      await container
          .read(printTaskOrchestratorProvider.notifier)
          .applyExternalMulticolorPlan(
        taskId: taskId,
        toolConsumableIds: {0: sharedId, 1: sharedId},
      );

      final mapped = await dao.getByTask(taskId);
      expect(mapped.map((row) => row.consumableId), [sharedId, sharedId]);

      final competingTaskId = await db.customInsert('''
        INSERT INTO print_tasks (
          uid, gcode_path, task_name, status, created_at, updated_at
        ) VALUES ('competing-map', 'competing.gcode', 'competing', 'printing', 1, 1)
      ''');
      await dao.createForTask(competingTaskId, [
        PrintTaskConsumable(
          taskId: competingTaskId,
          printerId: null,
          channelIndex: 0,
          toolIndex: 0,
          estimatedGrams: 10,
          createdAt: now,
          updatedAt: now,
        ),
      ]);
      await expectLater(
        container
            .read(printTaskOrchestratorProvider.notifier)
            .applyExternalMulticolorPlan(
          taskId: competingTaskId,
          toolConsumableIds: {0: sharedId},
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('其他任务已占用 20.0g'), contains('还差 5.0g')),
          ),
        ),
      );

      final remaining = await db.consumableDao.addRolls(sharedId, 2);
      expect(remaining, 2025);
    });

    test('shared stock mapping rejects the combined shortage', () async {
      final sharedId = await db.consumableDao.addConsumable(
        ConsumablesCompanion.insert(
          manufacturer: 'Test',
          model: 'Green PLA',
          materialType: const Value('PLA'),
          colorHex: const Value('#00AA55'),
          remainingGrams: const Value(15),
        ),
      );
      final taskId = await db.customInsert('''
        INSERT INTO print_tasks (
          uid, gcode_path, task_name, status, created_at, updated_at
        ) VALUES ('short-map', 'short.gcode', 'short', 'printing', 1, 1)
      ''');
      final dao = PrintTaskConsumableDao(db);
      final now = DateTime(2026, 8, 2);
      await dao.createForTask(taskId, [
        PrintTaskConsumable(
          taskId: taskId,
          printerId: null,
          channelIndex: 0,
          toolIndex: 0,
          estimatedGrams: 12,
          createdAt: now,
          updatedAt: now,
        ),
        PrintTaskConsumable(
          taskId: taskId,
          printerId: null,
          channelIndex: 0,
          toolIndex: 1,
          estimatedGrams: 8,
          createdAt: now,
          updatedAt: now,
        ),
      ]);
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(container.dispose);

      await expectLater(
        container
            .read(printTaskOrchestratorProvider.notifier)
            .applyExternalMulticolorPlan(
          taskId: taskId,
          toolConsumableIds: {0: sharedId, 1: sharedId},
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('还差 5.0g'),
          ),
        ),
      );
      final unchanged = await dao.getByTask(taskId);
      expect(unchanged.every((row) => row.consumableId == null), isTrue);
    });
  });
}
