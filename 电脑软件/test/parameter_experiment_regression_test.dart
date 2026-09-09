import 'dart:async';
import 'dart:io';

import 'package:consumable_tracker_desktop/core/services/parameter_experiment_service.dart';
import 'package:consumable_tracker_desktop/data/database/daos/experiment_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/preset_result_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_queue_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/experiment_models.dart';
import 'package:consumable_tracker_desktop/data/models/print_parameter.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/gcode_parser.dart';
import 'package:consumable_tracker_desktop/features/parameters/parameter_experiment_panel.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

PrintParameterPreset _preset(String id, String layerHeight) {
  final now = DateTime(2026, 7, 30);
  return PrintParameterPreset(
    id: id,
    name: id,
    plateType: 'texturedPei',
    createdAt: now,
    updatedAt: now,
    quality: PrintQualityParams(layerHeight: layerHeight),
    strength: const PrintStrengthParams(),
    speed: const PrintSpeedParams(),
    support: const PrintSupportParams(),
    other: const PrintOtherParams(),
  );
}

void main() {
  late AppDatabase database;
  late ExperimentDao dao;
  late PresetResultDao resultDao;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    dao = ExperimentDao(database);
    resultDao = PresetResultDao(database);
  });

  tearDown(() async {
    dao.dispose();
    resultDao.dispose();
    await database.close();
  });

  test('实验监听首次订阅立即返回当前快照并继续推送变更', () async {
    final emissions = <List<dynamic>>[];
    final firstEmission = Completer<void>();
    final changedEmission = Completer<void>();
    final subscription = dao.watchAll().listen((experiments) {
      emissions.add(experiments);
      if (!firstEmission.isCompleted) firstEmission.complete();
      if (experiments.isNotEmpty && !changedEmission.isCompleted) {
        changedEmission.complete();
      }
    });

    await firstEmission.future;
    expect(emissions.single, isEmpty);

    await dao.createExperiment(name: '层高 A/B');

    await changedEmission.future;
    expect(emissions.last.single.name, '层高 A/B');
    await subscription.cancel();
  });

  testWidgets('空实验页面结束加载并显示可操作空状态', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: const MaterialApp(
          home: Scaffold(body: ParameterExperimentPanel()),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('暂无参数实验'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('创建实验'), findsWidgets);
  });

  testWidgets('运行计划显示交替的 A/B 变体', (tester) async {
    final service = ParameterExperimentService(
      dao,
      resultDao,
    );
    final experimentId = await service.createExperiment(
      name: '温度 A/B',
      variants: const [
        (label: 'A', snapshotId: null, diffSummary: '基准'),
        (label: 'B', snapshotId: null, diffSummary: '候选'),
      ],
      targetRepeats: 2,
    );
    await service.planRuns(experimentId);
    final variants = await dao.getVariants(experimentId);
    final variantLabels = <String, String>{
      for (final variant in variants) variant.id: variant.label,
    };
    final runs = await dao.getRuns(experimentId);
    expect(
      runs.map((run) => variantLabels[run.variantId]),
      orderedEquals(const ['A', 'B', 'A', 'B']),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: const MaterialApp(
          home: Scaffold(body: ParameterExperimentPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('温度 A/B'));
    await tester.pumpAndSettle();

    expect(find.text('运行（4）'), findsOneWidget);
    expect(find.text('A'), findsWidgets);
    expect(find.text('B'), findsWidgets);
  });

  test('只关联匹配快照的真实结果，并在全部运行结束后自动完成实验', () async {
    final snapshotA = await resultDao.getOrCreateSnapshot(_preset('A', '0.20'));
    final snapshotB = await resultDao.getOrCreateSnapshot(_preset('B', '0.16'));
    final service = ParameterExperimentService(dao, resultDao);
    final experimentId = await service.createExperiment(
      name: '真实结果闭环',
      targetRepeats: 1,
      variants: [
        (label: 'A', snapshotId: snapshotA, diffSummary: '基准'),
        (label: 'B', snapshotId: snapshotB, diffSummary: '候选'),
      ],
    );
    await service.planRuns(experimentId);
    await service.startExperiment(experimentId);
    final runs = await dao.getRuns(experimentId);

    Future<PresetPrintResult> createResult({
      required int ordinal,
      required String snapshotId,
    }) async {
      final taskId = await database.customInsert(
        '''
          INSERT INTO print_tasks(
            uid, gcode_path, task_name, status, created_at, updated_at
          ) VALUES (?, ?, ?, 'finished', ?, ?)
        ''',
        variables: [
          Variable('experiment-task-$ordinal'),
          Variable('experiment-$ordinal.gcode'),
          Variable('experiment-$ordinal'),
          Variable(ordinal),
          Variable(ordinal),
        ],
      );
      final resultId = await resultDao.upsertResultForTask(
        taskId: taskId,
        taskUid: 'experiment-task-$ordinal',
        snapshotId: snapshotId,
        technicalStatus: TechnicalStatus.finished,
        userOutcome: UserOutcome.success,
        actualGrams: ordinal.toDouble(),
        actualSeconds: ordinal * 60,
      );
      return (await resultDao.getById(resultId))!;
    }

    final resultA = await createResult(ordinal: 1, snapshotId: snapshotA);
    final resultB = await createResult(ordinal: 2, snapshotId: snapshotB);
    final candidatesA = await service.getLinkableResults(runs[0].id);
    expect(candidatesA.map((result) => result.id), [resultA.id]);

    await service.linkResultToRun(runId: runs[0].id, resultId: resultA.id);
    await service.linkResultToRun(runId: runs[1].id, resultId: resultB.id);

    expect(
      (await dao.getById(experimentId))!.status,
      ExperimentStatus.completed,
    );
    expect(
      (await dao.getRuns(experimentId)).map((run) => run.status),
      everyElement(RunStatus.completed),
    );
    expect(
      (await service.compareExperiment(experimentId)).allMeetTarget,
      isTrue,
    );
  });

  test('实验运行从真实切片文件入队并自动回写任务结果', () async {
    final tempDir =
        await Directory.systemTemp.createTemp('experiment_queue_test_');
    addTearDown(() => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/experiment-a.gcode');
    await file.writeAsString('''
; HEADER_BLOCK_START
; BambuStudio 02.07.01.57
; total filament weight [g] : 12.5
; total filament length [mm] : 4020
; total layer number: 20
; total estimated time: 12m 5s
; HEADER_BLOCK_END
; CONFIG_BLOCK_START
; print_settings_id = "0.20mm Standard @BBL X1C"
; printer_settings_id = "Bambu Lab X1 Carbon 0.4 nozzle"
; nozzle_diameter = [0.4]
; curr_bed_type = Textured PEI Plate
; filament_type = PLA
; CONFIG_BLOCK_END
G1 X0 Y0
''');

    final snapshotId =
        await resultDao.getOrCreateSnapshot(_preset('A', '0.20'));
    final service = ParameterExperimentService(dao, resultDao);
    final experimentId = await service.createExperiment(
      name: '真实打印自动闭环',
      targetRepeats: 1,
      variants: [
        (label: 'A', snapshotId: snapshotId, diffSummary: '基准'),
      ],
    );
    await service.planRuns(experimentId);
    await service.startExperiment(experimentId);
    final run = (await dao.getRuns(experimentId)).single;

    final parsed = (await GcodeParser.parseFile(file.path))!;
    final applicationId = await resultDao.recordApplication(
      snapshotId: snapshotId,
      displayName: 'A',
      experimentId: experimentId,
      experimentArm: 'A',
    );
    await resultDao.bindSliceArtifact(
      applicationId: applicationId,
      artifactSha256: parsed.artifactSha256!,
      artifactSize: parsed.artifactSize!,
      artifactModifiedAt: parsed.artifactModifiedAt?.millisecondsSinceEpoch,
      localPath: file.path,
    );

    const printer = PrinterConnectionConfig(
      serial: '01S09C123456789',
      host: '192.168.1.100',
      accessCode: '12345678',
      devProductName: 'X1C',
      displayName: '实验室 X1C',
      installedNozzleDiameter: 0.4,
    );
    final check = await service.prepareRunForQueue(
      runId: run.id,
      filePath: file.path,
      printer: printer,
    );

    expect(check.canQueue, isTrue);
    expect(check.attribution, ResultAttribution.exact);
    expect(check.applicationId, applicationId);
    final queueId = await service.enqueueRun(check);
    final queueDao = PrintQueueDao(database);
    final queued = await queueDao.getByExperimentRunId(run.id);
    expect(queued?.id, queueId);
    expect(queued?.artifactSha256, parsed.artifactSha256);
    expect((await dao.getRunById(run.id))?.status, RunStatus.queued);

    final taskId = await database.customInsert(
      '''
        INSERT INTO print_tasks(
          uid, gcode_path, task_name, status, created_at, updated_at
        ) VALUES (?, ?, ?, 'printing', ?, ?)
      ''',
      variables: [
        const Variable('experiment-queue-task'),
        Variable(file.path),
        const Variable('experiment-a'),
        const Variable(1),
        const Variable(1),
      ],
    );
    await service.bindQueuedRunToTask(
      queueItem: queued!,
      taskId: taskId,
      slice: parsed,
    );

    final printingRun = await dao.getRunById(run.id);
    expect(printingRun?.status, RunStatus.printing);
    expect(printingRun?.taskId, taskId);
    final attribution = await resultDao.getTaskAttribution(taskId);
    expect(attribution?['snapshot_id'], snapshotId);
    expect(attribution?['application_id'], applicationId);
    expect(attribution?['attribution'], ResultAttribution.exact.value);

    // MQTT 队列终态可能早于结果落库；稍后的结果必须仍可补齐关联。
    await service.markQueueRunStatus(queued, RunStatus.completed);
    expect((await dao.getRunById(run.id))?.resultId, isNull);

    final resultId = await resultDao.upsertResultForTask(
      taskId: taskId,
      taskUid: 'experiment-queue-task',
      snapshotId: snapshotId,
      applicationId: applicationId,
      attribution: ResultAttribution.exact,
      technicalStatus: TechnicalStatus.finished,
      userOutcome: UserOutcome.success,
      actualGrams: 12.2,
      actualSeconds: 720,
    );
    expect(
      await service.linkTerminalTaskResult(taskId: taskId, resultId: resultId),
      isTrue,
    );
    expect((await dao.getRunById(run.id))?.status, RunStatus.completed);
    expect(
      (await dao.getById(experimentId))?.status,
      ExperimentStatus.completed,
    );
  });
}
