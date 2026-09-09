import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/preset_result_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_task_dao.dart';
import 'package:consumable_tracker_desktop/data/models/print_parameter.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

PrintParameterPreset _preset(String id, String layerHeight) {
  final now = DateTime(2026, 7, 28);
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
  late AppDatabase db;
  late PresetResultDao dao;
  late PrintTaskDao taskDao;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = PresetResultDao(db);
    taskDao = PrintTaskDao(db);
  });

  tearDown(() async {
    dao.dispose();
    taskDao.dispose();
    await db.close();
  });

  test('同一产物的多个应用保留为歧义，不静默归给第一条', () async {
    final snapshotA = await dao.getOrCreateSnapshot(_preset('A', '0.20'));
    final snapshotB = await dao.getOrCreateSnapshot(_preset('B', '0.24'));
    final appA = await dao.recordApplication(
      snapshotId: snapshotA,
      displayName: 'A',
      slicerProcessSettingsId: 'shared-setting',
    );
    final appB = await dao.recordApplication(
      snapshotId: snapshotB,
      displayName: 'B',
      slicerProcessSettingsId: 'shared-setting',
    );

    await dao.bindSliceArtifact(
      applicationId: appA,
      artifactSha256: 'same-hash',
      artifactSize: 10,
    );
    await dao.bindSliceArtifact(
      applicationId: appB,
      artifactSha256: 'same-hash',
      artifactSize: 10,
    );
    await dao.bindSliceArtifact(
      applicationId: appA,
      artifactSha256: 'same-hash',
      artifactSize: 10,
    );

    expect(await dao.getApplicationsByArtifactHash('same-hash'), hasLength(2));
    expect(await dao.getApplicationByArtifactHash('same-hash'), isNull);
  });

  test('任务归因冻结且终态结果幂等，不覆盖用户评价', () async {
    final now = DateTime(2026, 7, 28, 5);
    final taskId = await taskDao.create(
      PrintTask(
        uid: 'task-uid',
        gcodePath: 'sample.gcode',
        taskName: 'sample',
        estimatedGrams: 10,
        estimatedSeconds: 60,
        actualGrams: 0,
        lastMcPercent: 0,
        lastLayer: 0,
        status: PrintTaskStatus.planned,
        source: 'test',
        createdAt: now,
        updatedAt: now,
      ),
    );
    await dao.recordTaskAttribution(
      taskId: taskId,
      presetDisplayName: '测试参数',
      attribution: ResultAttribution.exact,
      artifactSha256: 'hash',
      nozzleDiameter: 0.4,
      plateType: 'texturedPei',
    );

    final firstId = await dao.upsertResultForTask(
      taskId: taskId,
      taskUid: 'task-uid',
      presetDisplayName: '测试参数',
      attribution: ResultAttribution.exact,
      technicalStatus: TechnicalStatus.finished,
      actualGrams: 9.5,
    );
    await dao.updateUserOutcome(
      resultId: firstId,
      userOutcome: UserOutcome.usable,
      rating: 4,
    );
    final secondId = await dao.upsertResultForTask(
      taskId: taskId,
      taskUid: 'task-uid',
      presetDisplayName: '测试参数',
      attribution: ResultAttribution.exact,
      technicalStatus: TechnicalStatus.finished,
      actualGrams: 9.7,
    );

    expect(secondId, firstId);
    final result = await dao.getByTaskId(taskId);
    expect(result!.rating, 4);
    expect(result.userOutcome, UserOutcome.usable);
    expect(result.actualGrams, 9.7);
    expect(
      (await dao.getTaskAttribution(taskId))!['plate_type'],
      'texturedPei',
    );
  });
}
