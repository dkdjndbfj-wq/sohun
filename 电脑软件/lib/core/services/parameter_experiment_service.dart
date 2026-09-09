// 参数实验服务。
//
// 任务书 Phase D 要求：
// - 实验创建/运行/归档/比较，状态机：draft → running → completed → archived。
// - 默认交替顺序 A-B-A-B；多变体采用确定性轮换。
// - 描述性比较，不做统计显著性推断。
// - 任一组未达到目标或数据缺失时显示"样本未完成"，不显示领先结论。
// - 永远不出现"显著胜出"等统计或保证性文案。
//
// 隐私边界：本服务仅处理本地实验数据，不涉及任何序列号或敏感设备标识上传。

import 'dart:math' show sqrt;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/daos/experiment_dao.dart';
import '../../data/database/daos/preset_result_dao.dart';
import '../../data/database/daos/print_queue_dao.dart';
import '../../data/database/database.dart';
import '../../data/database/models/experiment_models.dart';
import '../../data/database/models/print_queue_item.dart';
import '../../data/external/printer/bambu_printer_models.dart';
import '../../data/external/slicer/slice_isolate_runner.dart';
import '../../data/external/slicer/slice_result.dart';
import '../../data/models/parameter_compatibility.dart';
import '../../data/models/print_parameter.dart';
import '../../providers/database_provider.dart';
import 'parameter_compatibility_service.dart';
import 'preset_diff_service.dart';
import 'slice_artifact_hash_service.dart';

/// 实验详情（record 类型）。
///
/// 包含实验主记录、变体列表和运行列表，供 UI 展示完整详情。
typedef ExperimentDetail = ({
  ParameterExperiment experiment,
  List<ExperimentVariant> variants,
  List<ExperimentRun> runs,
});

typedef _ArtifactResolution = ({
  String? applicationId,
  ResultAttribution attribution,
  bool isUnbound,
  bool isAmbiguous,
  bool isMismatch,
});

class ExperimentQueueCheck {
  final String runId;
  final String experimentId;
  final String variantId;
  final String variantLabel;
  final String snapshotId;
  final String presetName;
  final String filePath;
  final String filename;
  final String printerSerial;
  final String printerLabel;
  final SliceResult slice;
  final CompatibilityAssessment compatibility;
  final String? applicationId;
  final ResultAttribution attribution;
  final List<String> blockers;
  final List<String> warnings;

  const ExperimentQueueCheck({
    required this.runId,
    required this.experimentId,
    required this.variantId,
    required this.variantLabel,
    required this.snapshotId,
    required this.presetName,
    required this.filePath,
    required this.filename,
    required this.printerSerial,
    required this.printerLabel,
    required this.slice,
    required this.compatibility,
    required this.applicationId,
    required this.attribution,
    required this.blockers,
    required this.warnings,
  });

  bool get canQueue => blockers.isEmpty;
}

/// 支持的评价指标。
///
/// 任务书要求：usable_rate（默认）、completion_rate、average_rating、
/// average_actual_seconds、average_actual_grams。
enum EvaluationMetric {
  usableRate('usable_rate', '可用率', true),
  completionRate('completion_rate', '完成率', true),
  averageRating('average_rating', '平均评分', true),
  averageActualSeconds('average_actual_seconds', '耗时均值', false),
  averageActualGrams('average_actual_grams', '克数均值', false);

  /// 数据库存储值。
  final String value;

  /// 中文显示名。
  final String label;

  /// 是否越高越好（true=越高越优；false=越低越优）。
  final bool higherIsBetter;

  const EvaluationMetric(this.value, this.label, this.higherIsBetter);

  /// 从数据库字符串解析。未知值回退到 usable_rate。
  static EvaluationMetric fromString(String? v) {
    return switch (v) {
      'completion_rate' => EvaluationMetric.completionRate,
      'average_rating' => EvaluationMetric.averageRating,
      'average_actual_seconds' => EvaluationMetric.averageActualSeconds,
      'average_actual_grams' => EvaluationMetric.averageActualGrams,
      _ => EvaluationMetric.usableRate,
    };
  }
}

/// 参数实验服务。
///
/// 负责实验创建/运行/归档/比较，通过 [ExperimentDao] 访问三张表，
/// 通过 [PresetResultDao] 获取运行的打印结果用于聚合统计。
///
/// 关键规则：
/// - 状态转换严格校验，非法转换抛 [StateError]。
/// - 比较结果为描述性，不涉及统计显著性推断。
/// - 删除仅允许 draft 状态；已有结果的实验采用归档，保留历史。
class ParameterExperimentService {
  final ExperimentDao _experimentDao;
  final PresetResultDao _presetResultDao;
  final AppDatabase _database;
  final PrintQueueDao _printQueueDao;

  ParameterExperimentService(this._experimentDao, this._presetResultDao)
      : _database = _experimentDao.attachedDatabase,
        _printQueueDao = PrintQueueDao(_experimentDao.attachedDatabase);

  Future<ExperimentQueueCheck> prepareRunForQueue({
    required String runId,
    required String filePath,
    required PrinterConnectionConfig printer,
  }) async {
    final run = await _experimentDao.getRunById(runId);
    if (run == null) throw StateError('实验运行不存在: $runId');
    if (run.status != RunStatus.pending) {
      throw StateError('只有待执行的实验运行可以加入打印队列');
    }
    final experiment = await _experimentDao.getById(run.experimentId);
    if (experiment == null) throw StateError('实验不存在: ${run.experimentId}');
    if (experiment.status != ExperimentStatus.running) {
      throw StateError('请先启动实验，再把运行加入打印队列');
    }
    final variant = await _experimentDao.getVariantById(run.variantId);
    if (variant == null) throw StateError('实验变体不存在: ${run.variantId}');
    final snapshotId = variant.snapshotId;
    if (snapshotId == null || snapshotId.isEmpty) {
      throw StateError('该实验变体没有冻结参数快照，不能执行真实打印');
    }
    final snapshot = await _presetResultDao.getSnapshot(snapshotId);
    final presetJson = snapshot?['preset_json'] as String?;
    if (presetJson == null || presetJson.isEmpty) {
      throw StateError('实验参数快照不存在或内容为空');
    }
    final preset = PrintParameterPreset.fromBbsparamJson(presetJson);
    final slice = await SliceIsolateRunner.parseAuto(filePath);
    if (slice == null) {
      throw StateError('无法解析该 G-code/3MF 文件，请确认文件完整且已完成切片');
    }

    final blockers = <String>[];
    final warnings = <String>[];
    final printerModel = printer.devProductName ?? '';
    final printerNozzle = printer.installedNozzleDiameter;
    final targetModel = slice.printerSettingsId;

    if (printer.mode != BambuConnectionMode.lan) {
      blockers.add('当前打印机不是 LAN 直连模式，无法安全上传并启动本地文件');
    }
    if (!PrinterModelNormalizer.isKnownBambuModel(printerModel)) {
      blockers.add('当前打印机缺少可验证的精确机型');
    }
    if (printerNozzle == null) {
      blockers.add('当前打印机没有记录已安装喷嘴直径');
    }
    if (targetModel == null || targetModel.isEmpty) {
      blockers.add('切片文件没有目标打印机元数据，不能确认设备兼容性');
    }
    if (slice.nozzleDiameter == null) {
      blockers.add('切片文件没有喷嘴直径元数据，不能确认挤出兼容性');
    }
    if (slice.artifactSha256 == null) {
      blockers.add('文件在校验期间仍在变化或为空，无法生成稳定内容哈希');
    }

    final materialName = slice.filaments.isEmpty
        ? (preset.material ?? '')
        : (slice.filaments.first.materialType ?? preset.material ?? '');
    final compatibility = ParameterCompatibilityService.assess(
      CompatibilityContext(
        preset: preset,
        printer: PrinterCapability(
          model: printerModel,
          nozzleDiameter: printerNozzle,
        ),
        material: MaterialCapability.unknown(materialName),
        gcodeTargetPrinterModel: targetModel,
        gcodeTargetNozzleDiameter: slice.nozzleDiameter,
      ),
    );
    blockers.addAll(compatibility.blockers.map((reason) => reason.detail));
    warnings.addAll(compatibility.warnings.map((reason) => reason.detail));
    if (compatibility.status == CompatibilityStatus.unknown) {
      blockers.add('设备或材料事实不足，兼容性评估结果为未知');
    }

    final resolution = await _resolveArtifactAttribution(
      snapshotId,
      slice.artifactSha256,
    );
    if (resolution.isMismatch) {
      blockers.add('该文件的内容哈希已绑定到其他参数快照，与变体 ${variant.label} 不一致');
    } else if (resolution.isUnbound) {
      warnings.add('该文件尚无参数应用记录；确认后会按变体 ${variant.label} 手动归因');
    } else if (resolution.isAmbiguous) {
      warnings.add('同一文件哈希存在多条参数应用记录；确认后按当前实验变体手动归因');
    }

    return ExperimentQueueCheck(
      runId: run.id,
      experimentId: run.experimentId,
      variantId: variant.id,
      variantLabel: variant.label,
      snapshotId: snapshotId,
      presetName: preset.name,
      filePath: filePath,
      filename: filePath.split(RegExp(r'[/\\]')).last,
      printerSerial: printer.serial,
      printerLabel: printer.displayLabel,
      slice: slice,
      compatibility: compatibility,
      applicationId: resolution.applicationId,
      attribution: resolution.attribution,
      blockers: List.unmodifiable(blockers.toSet()),
      warnings: List.unmodifiable(warnings.toSet()),
    );
  }

  Future<int> enqueueRun(ExperimentQueueCheck check) async {
    if (!check.canQueue) throw StateError('兼容性检查未通过，不能加入打印队列');
    final currentArtifact =
        await SliceArtifactHashService.computeStable(check.filePath);
    if (currentArtifact == null ||
        currentArtifact.sha256Hex != check.slice.artifactSha256) {
      throw StateError('文件在确认期间发生变化，请重新选择并检查');
    }

    return _database.transaction(() async {
      final run = await _experimentDao.getRunById(check.runId);
      if (run == null || run.status != RunStatus.pending) {
        throw StateError('实验运行已入队、已开始或已结束');
      }
      if (await _printQueueDao.getByExperimentRunId(check.runId) != null) {
        throw StateError('该实验运行已经存在于打印队列');
      }
      final queueId = await _printQueueDao.enqueue(
        PrintQueueItem(
          printerSerial: check.printerSerial,
          gcodePath: check.filePath,
          filename: check.filename,
          queuedAt: DateTime.now(),
          experimentRunId: check.runId,
          experimentSnapshotId: check.snapshotId,
          experimentApplicationId: check.applicationId,
          experimentAttribution: check.attribution.value,
          artifactSha256: check.slice.artifactSha256,
        ),
      );
      await _experimentDao.markRunQueued(check.runId);
      return queueId;
    });
  }

  Future<void> bindQueuedRunToTask({
    required PrintQueueItem queueItem,
    required int taskId,
    required SliceResult? slice,
  }) async {
    final runId = queueItem.experimentRunId;
    final snapshotId = queueItem.experimentSnapshotId;
    if (runId == null || snapshotId == null || queueItem.id == null) return;
    final run = await _experimentDao.getRunById(runId);
    if (run == null) throw StateError('实验运行不存在: $runId');
    final variant = await _experimentDao.getVariantById(run.variantId);
    if (variant?.snapshotId != snapshotId) {
      throw StateError('队列保存的参数快照与实验变体不一致');
    }
    if (queueItem.artifactSha256 != null &&
        slice?.artifactSha256 != queueItem.artifactSha256) {
      throw StateError('打印任务文件与入队时校验的文件哈希不一致');
    }
    final snapshot = await _presetResultDao.getSnapshot(snapshotId);
    final presetJson = snapshot?['preset_json'] as String?;
    final presetName = presetJson == null
        ? ''
        : PrintParameterPreset.fromBbsparamJson(presetJson).name;
    final firstFilament =
        slice == null || slice.filaments.isEmpty ? null : slice.filaments.first;

    await _database.transaction(() async {
      await _printQueueDao.setStatus(
        queueItem.id!,
        PrintQueueStatus.printing,
        printTaskId: taskId,
      );
      await _experimentDao.bindRunToTask(
        runId,
        taskId,
        status: RunStatus.printing,
      );
      await _presetResultDao.recordTaskAttribution(
        taskId: taskId,
        snapshotId: snapshotId,
        applicationId: queueItem.experimentApplicationId,
        presetDisplayName: presetName,
        attribution: ResultAttribution.fromString(
          queueItem.experimentAttribution,
        ),
        artifactSha256: queueItem.artifactSha256,
        printSettingsId: slice?.printSettingsId,
        printerSettingsId: slice?.printerSettingsId,
        nozzleDiameter: slice?.nozzleDiameter,
        plateType: slice?.plateType,
        materialProfile: firstFilament?.settingsId,
        materialType: firstFilament?.materialType,
      );
    });
  }

  Future<bool> linkTerminalTaskResult({
    required int taskId,
    required String resultId,
  }) async {
    final run = await _experimentDao.getRunByTaskId(taskId);
    if (run == null) return false;
    final result = await _presetResultDao.getById(resultId);
    if (result == null) throw StateError('打印结果不存在: $resultId');
    final variant = await _experimentDao.getVariantById(run.variantId);
    if (variant?.snapshotId == null ||
        result.snapshotId != variant!.snapshotId) {
      throw StateError('打印结果与实验运行的冻结快照不一致');
    }
    final status = switch (result.technicalStatus) {
      TechnicalStatus.finished => RunStatus.completed,
      TechnicalStatus.failed => RunStatus.failed,
      TechnicalStatus.cancelled => RunStatus.cancelled,
    };
    await _experimentDao.linkRunToTerminalResult(
      runId: run.id,
      taskId: taskId,
      resultId: resultId,
      status: status,
    );
    return true;
  }

  Future<void> markQueueRunStatus(
    PrintQueueItem queueItem,
    RunStatus status,
  ) async {
    final runId = queueItem.experimentRunId;
    if (runId == null) return;
    if (status.isTerminal) {
      await _experimentDao.markRunTerminal(runId, status);
      return;
    }
    if (status != RunStatus.queued && status != RunStatus.printing) {
      throw ArgumentError.value(status, 'status', '不支持的队列运行状态');
    }
    await _experimentDao.updateRunStatus(runId, status);
  }

  Future<_ArtifactResolution> _resolveArtifactAttribution(
    String snapshotId,
    String? artifactSha256,
  ) async {
    if (artifactSha256 == null) {
      return (
        applicationId: null,
        attribution: ResultAttribution.unknown,
        isUnbound: true,
        isAmbiguous: false,
        isMismatch: false,
      );
    }
    final candidates =
        await _presetResultDao.getApplicationsByArtifactHash(artifactSha256);
    if (candidates.isEmpty) {
      return (
        applicationId: null,
        attribution: ResultAttribution.manual,
        isUnbound: true,
        isAmbiguous: false,
        isMismatch: false,
      );
    }
    final matches = candidates
        .where((candidate) => candidate['snapshot_id'] == snapshotId)
        .toList(growable: false);
    if (matches.isEmpty) {
      return (
        applicationId: null,
        attribution: ResultAttribution.unknown,
        isUnbound: false,
        isAmbiguous: false,
        isMismatch: true,
      );
    }
    if (candidates.length == 1) {
      return (
        applicationId: matches.single['id'] as String?,
        attribution: ResultAttribution.exact,
        isUnbound: false,
        isAmbiguous: false,
        isMismatch: false,
      );
    }
    return (
      applicationId: matches.first['id'] as String?,
      attribution: ResultAttribution.manual,
      isUnbound: false,
      isAmbiguous: true,
      isMismatch: false,
    );
  }

  // ===== 实验生命周期 =====

  /// 创建实验，并同时创建初始变体列表。
  ///
  /// [variants] 为变体输入列表，每项包含 label、snapshotId、diffSummary。
  /// 返回新创建的实验 ID。
  Future<String> createExperiment({
    required String name,
    String goal = '',
    String? baselineSnapshotId,
    String controlVariables = '',
    String evaluationMetrics = 'usable_rate',
    int targetRepeats = 3,
    List<({String label, String? snapshotId, String diffSummary})> variants =
        const [],
  }) async {
    final experimentId = await _experimentDao.createExperiment(
      name: name,
      goal: goal,
      baselineSnapshotId: baselineSnapshotId,
      controlVariables: controlVariables,
      evaluationMetrics: evaluationMetrics,
      targetRepeats: targetRepeats,
    );
    // 创建初始变体
    for (final v in variants) {
      await _experimentDao.createVariant(
        experimentId: experimentId,
        label: v.label,
        snapshotId: v.snapshotId,
        diffSummary: v.diffSummary,
        revision: 1,
      );
    }
    return experimentId;
  }

  /// 从真实 A/B 参数创建实验，自动冻结快照并保存相对差异。
  Future<String> createExperimentFromPresets({
    required String name,
    required PrintParameterPreset baseline,
    required PrintParameterPreset candidate,
    String goal = '',
    String controlVariables = '',
    String evaluationMetrics = 'usable_rate',
    int targetRepeats = 3,
  }) async {
    final diffs = PresetDiffService.comparePresets(baseline, candidate);
    if (diffs.isEmpty) {
      throw ArgumentError('参数 A 与参数 B 没有实际差异，无法创建对比实验');
    }
    final baselineSnapshotId =
        await _presetResultDao.getOrCreateSnapshot(baseline);
    final candidateSnapshotId =
        await _presetResultDao.getOrCreateSnapshot(candidate);
    return createExperiment(
      name: name,
      goal: goal,
      baselineSnapshotId: baselineSnapshotId,
      controlVariables: controlVariables,
      evaluationMetrics: evaluationMetrics,
      targetRepeats: targetRepeats,
      variants: [
        (
          label: 'A',
          snapshotId: baselineSnapshotId,
          diffSummary: '基准参数：${baseline.name}',
        ),
        (
          label: 'B',
          snapshotId: candidateSnapshotId,
          diffSummary: PresetDiffService.summarize(diffs),
        ),
      ],
    );
  }

  /// 启动实验（draft/paused → running）。
  Future<void> startExperiment(String experimentId) async {
    final exp = await _experimentDao.getById(experimentId);
    if (exp == null) {
      throw StateError('实验不存在: $experimentId');
    }
    if (!exp.status.canStart) {
      throw StateError('当前状态 ${exp.status.value} 无法启动，仅 draft/paused 可启动');
    }
    final runs = await _experimentDao.getRuns(experimentId);
    if (runs.isEmpty) {
      throw StateError('请先生成 A/B 运行计划，再启动实验');
    }
    await _experimentDao.updateStatus(experimentId, ExperimentStatus.running);
  }

  /// 暂停实验（running → paused）。
  Future<void> pauseExperiment(String experimentId) async {
    final exp = await _experimentDao.getById(experimentId);
    if (exp == null) {
      throw StateError('实验不存在: $experimentId');
    }
    if (!exp.status.canPause) {
      throw StateError('当前状态 ${exp.status.value} 无法暂停，仅 running 可暂停');
    }
    await _experimentDao.updateStatus(experimentId, ExperimentStatus.paused);
  }

  /// 归档实验（completed/cancelled → archived，保留历史）。
  Future<void> archiveExperiment(String experimentId) async {
    final exp = await _experimentDao.getById(experimentId);
    if (exp == null) {
      throw StateError('实验不存在: $experimentId');
    }
    if (!exp.status.canArchive) {
      throw StateError(
        '当前状态 ${exp.status.value} 无法归档，仅 completed/cancelled 可归档',
      );
    }
    await _experimentDao.updateStatus(
      experimentId,
      ExperimentStatus.archived,
      archivedAt: DateTime.now(),
    );
  }

  /// 取消实验（running/paused → cancelled）。
  Future<void> cancelExperiment(String experimentId) async {
    final exp = await _experimentDao.getById(experimentId);
    if (exp == null) {
      throw StateError('实验不存在: $experimentId');
    }
    final s = exp.status;
    if (s != ExperimentStatus.running && s != ExperimentStatus.paused) {
      throw StateError('当前状态 ${s.value} 无法取消，仅 running/paused 可取消');
    }
    await _experimentDao.updateStatus(experimentId, ExperimentStatus.cancelled);
  }

  /// 删除实验（仅允许 draft 状态；已有结果的采用归档）。
  Future<void> deleteExperimentIfDraft(String experimentId) async {
    final exp = await _experimentDao.getById(experimentId);
    if (exp == null) {
      throw StateError('实验不存在: $experimentId');
    }
    if (exp.status != ExperimentStatus.draft) {
      throw StateError(
        '当前状态 ${exp.status.value} 无法删除，仅 draft 可删除；已有结果的实验请使用归档',
      );
    }
    await _experimentDao.deleteExperiment(experimentId);
  }

  // ===== 变体管理 =====

  /// 添加变体。
  ///
  /// 若 [label] 已存在，则创建新 revision（revision+1）；
  /// 否则创建新变体（revision=1）。返回变体 ID。
  Future<String> addVariant({
    required String experimentId,
    required String label,
    String? snapshotId,
    String diffSummary = '',
  }) async {
    final latestRevision =
        await _experimentDao.getLatestRevision(experimentId, label);
    final revision = latestRevision + 1;
    return _experimentDao.createVariant(
      experimentId: experimentId,
      label: label,
      snapshotId: snapshotId,
      diffSummary: diffSummary,
      revision: revision,
    );
  }

  // ===== 运行计划 =====

  /// 按 A-B-A-B 交替顺序生成运行计划。
  ///
  /// 基于变体数量和 [repeatCount]（默认取实验的 targetRepeats）生成运行。
  /// 若已有运行记录，不重复创建（幂等）。返回创建的运行数量。
  Future<int> planRuns(String experimentId, {int? repeatCount}) async {
    final exp = await _experimentDao.getById(experimentId);
    if (exp == null) {
      throw StateError('实验不存在: $experimentId');
    }
    if (exp.status != ExperimentStatus.draft) {
      throw StateError('仅草稿实验可以生成运行计划');
    }
    final variants = await _experimentDao.getVariants(experimentId);
    if (variants.isEmpty) {
      throw StateError('实验无变体，无法生成运行计划');
    }

    // 幂等：已有运行则不重复创建
    final existingRuns = await _experimentDao.getRuns(experimentId);
    if (existingRuns.isNotEmpty) {
      return 0;
    }

    final repeats = repeatCount ?? exp.targetRepeats;
    if (repeats <= 0) return 0;

    // A-B-A-B 交替顺序：第 i 个运行 = variants[i % variantCount]
    final variantCount = variants.length;
    final totalRuns = variantCount * repeats;
    for (var i = 0; i < totalRuns; i++) {
      final variant = variants[i % variantCount];
      await _experimentDao.createRun(
        experimentId: experimentId,
        variantId: variant.id,
        runOrder: i + 1,
      );
    }
    return totalRuns;
  }

  /// 查询可关联到某次运行的真实打印结果。
  ///
  /// 只返回与该变体冻结快照一致、且未被其他实验运行占用的终态结果。
  Future<List<PresetPrintResult>> getLinkableResults(String runId) async {
    final run = await _experimentDao.getRunById(runId);
    if (run == null) throw StateError('实验运行不存在: $runId');
    if (run.status != RunStatus.pending) return const [];

    final variants = await _experimentDao.getVariants(run.experimentId);
    final variant = variants.where((item) => item.id == run.variantId).first;
    final snapshotId = variant.snapshotId;
    if (snapshotId == null || snapshotId.isEmpty) return const [];

    final usedTaskIds = await _experimentDao.getLinkedTaskIds();
    final results = await _presetResultDao.getBySnapshot(snapshotId);
    return results
        .where((result) => !usedTaskIds.contains(result.taskId))
        .toList(growable: false);
  }

  /// 将数据库中的真实打印结果关联到实验运行。
  Future<void> linkResultToRun({
    required String runId,
    required String resultId,
  }) async {
    final run = await _experimentDao.getRunById(runId);
    if (run == null) throw StateError('实验运行不存在: $runId');
    final result = await _presetResultDao.getById(resultId);
    if (result == null) throw StateError('打印结果不存在: $resultId');

    final variants = await _experimentDao.getVariants(run.experimentId);
    final variant = variants.where((item) => item.id == run.variantId).first;
    if (variant.snapshotId == null ||
        result.snapshotId == null ||
        variant.snapshotId != result.snapshotId) {
      throw StateError('打印结果与该运行的冻结参数快照不匹配');
    }

    final runStatus = switch (result.technicalStatus) {
      TechnicalStatus.finished => RunStatus.completed,
      TechnicalStatus.failed => RunStatus.failed,
      TechnicalStatus.cancelled => RunStatus.cancelled,
    };
    await _experimentDao.linkRunToTerminalResult(
      runId: runId,
      taskId: result.taskId,
      resultId: result.id,
      status: runStatus,
    );
  }

  // ===== 查询 =====

  /// 获取实验详情（实验主记录 + 变体列表 + 运行列表）。
  ///
  /// 若实验不存在抛 [StateError]。
  Future<ExperimentDetail> getExperimentDetail(String experimentId) async {
    final exp = await _experimentDao.getById(experimentId);
    if (exp == null) {
      throw StateError('实验不存在: $experimentId');
    }
    final variants = await _experimentDao.getVariants(experimentId);
    final runs = await _experimentDao.getRuns(experimentId);
    return (
      experiment: exp,
      variants: variants,
      runs: runs,
    );
  }

  // ===== 描述性比较 =====

  /// 比较实验各变体的结果。
  ///
  /// 描述性比较规则（任务书 9.4）：
  /// - 任一变体未达到目标重复次数 → allMeetTarget=false，显示"样本未完成"。
  /// - 所有变体达到目标且数据齐全 → 判断"当前指标领先"（含绝对差、百分比、样本数、离散程度）。
  /// - 并列时 leadingVariantId=null 且 isTied=true。
  /// - 永远不出现"显著胜出"。
  Future<ExperimentComparison> compareExperiment(
    String experimentId,
  ) async {
    final exp = await _experimentDao.getById(experimentId);
    if (exp == null) {
      throw StateError('实验不存在: $experimentId');
    }

    final metric = EvaluationMetric.fromString(exp.evaluationMetrics);
    final variants = await _experimentDao.getVariants(experimentId);

    // 构建每个变体的汇总
    final summaries = <VariantResultSummary>[];
    for (final variant in variants) {
      final runs = await _experimentDao.getRunsByVariant(variant.id);
      final summary = await _buildVariantSummary(
        variant: variant,
        runs: runs,
        targetRepeats: exp.targetRepeats,
      );
      summaries.add(summary);
    }

    // 按 label 排序
    summaries.sort((a, b) => a.label.compareTo(b.label));

    final allMeetTarget =
        summaries.isNotEmpty && summaries.every((s) => s.meetsTarget);

    // 不足 2 个变体或未全部达标 → 无法判断领先
    if (!allMeetTarget || summaries.length < 2) {
      return ExperimentComparison(
        variants: summaries,
        allMeetTarget: allMeetTarget,
        evaluationMetric: metric.value,
        leadingVariantId: null,
        leadingDescription: null,
        isTied: false,
      );
    }

    // 查找当前指标领先的变体
    final result = _findLeading(summaries, metric);
    return ExperimentComparison(
      variants: summaries,
      allMeetTarget: true,
      evaluationMetric: metric.value,
      leadingVariantId: result.leadingId,
      leadingDescription: result.description,
      isTied: result.isTied,
    );
  }

  // ===== 内部辅助：变体汇总 =====

  /// 构建单个变体的结果汇总。
  ///
  /// 通过 [PresetResultDao.getByTaskId] 获取每个完成运行的打印结果，
  /// 聚合完成数、可用率、耗时/克数均值和标准差、平均评分等。
  Future<VariantResultSummary> _buildVariantSummary({
    required ExperimentVariant variant,
    required List<ExperimentRun> runs,
    required int targetRepeats,
  }) async {
    var completedCount = 0;
    var failedCount = 0;
    var skippedCount = 0;

    final completedResults = <PresetPrintResult>[];

    for (final run in runs) {
      switch (run.status) {
        case RunStatus.completed:
          completedCount++;
          PresetPrintResult? result;
          if (run.resultId != null) {
            result = await _presetResultDao.getById(run.resultId!);
          }
          if (result == null && run.taskId != null) {
            result = await _presetResultDao.getByTaskId(run.taskId!);
          }
          if (result != null) {
            completedResults.add(result);
          }
          break;
        case RunStatus.failed:
          failedCount++;
          break;
        case RunStatus.skipped:
          skippedCount++;
          break;
        default:
          // pending/queued/printing 不计入终态统计
          break;
      }
    }

    final totalRuns = runs.length;
    final completionRate = totalRuns > 0 ? completedCount / totalRuns : null;

    // 可用率：分母为 user_outcome 非 null 的样本
    final userOutcomes =
        completedResults.where((r) => r.userOutcome != null).toList();
    final double? usableRate;
    if (userOutcomes.isEmpty) {
      usableRate = null;
    } else {
      final usable = userOutcomes
          .where(
            (r) =>
                r.userOutcome == UserOutcome.success ||
                r.userOutcome == UserOutcome.usable,
          )
          .length;
      usableRate = usable / userOutcomes.length;
    }

    // 耗时均值和标准差（仅 actualSeconds > 0 的完成样本）
    final secondsValues = completedResults
        .where((r) => r.actualSeconds > 0)
        .map((r) => r.actualSeconds.toDouble())
        .toList();
    final averageActualSeconds = secondsValues.isEmpty
        ? null
        : secondsValues.reduce((a, b) => a + b) / secondsValues.length;
    final stdDevActualSeconds =
        (averageActualSeconds != null && secondsValues.length >= 2)
            ? _stdDev(secondsValues, averageActualSeconds)
            : null;

    // 克数均值和标准差（仅 actualGrams > 0 的完成样本）
    final gramsValues = completedResults
        .where((r) => r.actualGrams > 0)
        .map((r) => r.actualGrams)
        .toList();
    final averageActualGrams = gramsValues.isEmpty
        ? null
        : gramsValues.reduce((a, b) => a + b) / gramsValues.length;
    final stdDevActualGrams =
        (averageActualGrams != null && gramsValues.length >= 2)
            ? _stdDev(gramsValues, averageActualGrams)
            : null;

    // 平均评分（仅 rating 非 null）
    final ratings = completedResults
        .where((r) => r.rating != null)
        .map((r) => r.rating!.toDouble())
        .toList();
    final averageRating = ratings.isEmpty
        ? null
        : ratings.reduce((a, b) => a + b) / ratings.length;
    final ratingCount = ratings.length;

    final meetsTarget = completedCount >= targetRepeats;

    return VariantResultSummary(
      variantId: variant.id,
      label: variant.label,
      completedCount: completedCount,
      failedCount: failedCount,
      skippedCount: skippedCount,
      totalRuns: totalRuns,
      completionRate: completionRate,
      usableRate: usableRate,
      averageActualSeconds: averageActualSeconds,
      stdDevActualSeconds: stdDevActualSeconds,
      averageActualGrams: averageActualGrams,
      stdDevActualGrams: stdDevActualGrams,
      averageRating: averageRating,
      ratingCount: ratingCount,
      meetsTarget: meetsTarget,
    );
  }

  // ===== 内部辅助：比较逻辑 =====

  /// 查找当前指标领先的变体。
  ///
  /// 返回 (leadingId, description, isTied)。
  /// - 所有变体必须 meetTarget=true（调用方已校验）。
  /// - 提取各变体指标值，按方向排序找最优。
  /// - 最优值相同（绝对差 < epsilon）→ 并列。
  ({String? leadingId, String? description, bool isTied}) _findLeading(
    List<VariantResultSummary> summaries,
    EvaluationMetric metric,
  ) {
    // 提取有指标值的变体
    final withValues =
        summaries.where((s) => _getMetricValue(s, metric) != null).toList();

    if (withValues.length < 2) {
      return (leadingId: null, description: null, isTied: false);
    }

    // 按指标方向排序：higherIsBetter → 降序；否则升序
    withValues.sort((a, b) {
      final av = _getMetricValue(a, metric)!;
      final bv = _getMetricValue(b, metric)!;
      return metric.higherIsBetter ? bv.compareTo(av) : av.compareTo(bv);
    });

    final leading = withValues.first;
    final second = withValues[1];
    final leadingValue = _getMetricValue(leading, metric)!;
    final secondValue = _getMetricValue(second, metric)!;

    // 并列检测：绝对差小于 epsilon
    const epsilon = 1e-9;
    if ((leadingValue - secondValue).abs() < epsilon) {
      return (leadingId: null, description: null, isTied: true);
    }

    final description = _buildLeadingDescription(
      leading: leading,
      second: second,
      metric: metric,
      leadingValue: leadingValue,
      secondValue: secondValue,
    );

    return (
      leadingId: leading.variantId,
      description: description,
      isTied: false,
    );
  }

  /// 获取变体在指定指标下的值。null 表示无数据。
  double? _getMetricValue(VariantResultSummary s, EvaluationMetric metric) {
    return switch (metric) {
      EvaluationMetric.usableRate => s.usableRate,
      EvaluationMetric.completionRate => s.completionRate,
      EvaluationMetric.averageRating => s.averageRating,
      EvaluationMetric.averageActualSeconds => s.averageActualSeconds,
      EvaluationMetric.averageActualGrams => s.averageActualGrams,
    };
  }

  /// 构建领先描述（含绝对差、百分比、样本数、离散程度）。
  ///
  /// 文案遵守任务书要求：不使用"显著""胜出""最佳参数""推荐方案"等统计或保证性用语。
  String _buildLeadingDescription({
    required VariantResultSummary leading,
    required VariantResultSummary second,
    required EvaluationMetric metric,
    required double leadingValue,
    required double secondValue,
  }) {
    final absDiff = (leadingValue - secondValue).abs();
    final pctDiff =
        secondValue.abs() > 0 ? (absDiff / secondValue.abs() * 100) : null;

    // 离散程度：耗时/克数有标准差；比率类无离散程度
    final stdDev = switch (metric) {
      EvaluationMetric.averageActualSeconds => leading.stdDevActualSeconds,
      EvaluationMetric.averageActualGrams => leading.stdDevActualGrams,
      _ => null,
    };

    final parts = <String>[
      '变体 ${leading.label} 当前指标领先于变体 ${second.label}',
      '绝对差 ${_formatValue(absDiff, metric)}',
      if (pctDiff != null) '相对差 ${pctDiff.toStringAsFixed(1)}%',
      '样本数 ${leading.completedCount}',
      if (stdDev != null) '离散程度 ${_formatValue(stdDev, metric)}',
    ];

    return parts.join('，');
  }

  /// 按指标类型格式化数值。
  String _formatValue(double value, EvaluationMetric metric) {
    return switch (metric) {
      EvaluationMetric.usableRate ||
      EvaluationMetric.completionRate =>
        '${(value * 100).toStringAsFixed(1)}%',
      EvaluationMetric.averageRating => value.toStringAsFixed(2),
      EvaluationMetric.averageActualSeconds => '${value.toStringAsFixed(1)}秒',
      EvaluationMetric.averageActualGrams => '${value.toStringAsFixed(2)}克',
    };
  }

  /// 计算标准差。
  ///
  /// 公式：sqrt(sum((x-mean)^2)/n)。
  /// n < 2 时返回 null（不显示离散程度）。
  double? _stdDev(List<double> values, double mean) {
    if (values.length < 2) return null;
    final sumSquaredDiff = values.fold<double>(
      0,
      (sum, x) => sum + (x - mean) * (x - mean),
    );
    return sqrt(sumSquaredDiff / values.length);
  }
}

// ===== Providers =====

/// ExperimentDao 单例。
///
/// 不走 drift 代码生成，手动实例化。dispose 时释放内部 StreamController。
final experimentDaoProvider = Provider<ExperimentDao>((ref) {
  final db = ref.watch(databaseProvider);
  final dao = ExperimentDao(db);
  ref.onDispose(dao.dispose);
  return dao;
});

/// 参数实验服务 Provider。
///
/// 复用 [experimentDaoProvider] 和 [databaseProvider]（PresetResultDao），
/// 不在 Service 内自行实例化 DAO。
final experimentServiceProvider = Provider<ParameterExperimentService>((ref) {
  final experimentDao = ref.watch(experimentDaoProvider);
  final presetResultDao = PresetResultDao(ref.watch(databaseProvider));
  ref.onDispose(presetResultDao.dispose);
  return ParameterExperimentService(experimentDao, presetResultDao);
});

/// 所有实验列表（按创建时间倒序，StreamProvider）。
///
/// ExperimentDao 内部的 onChange 流会在数据变化时自动推送。
final experimentsListProvider =
    StreamProvider<List<ParameterExperiment>>((ref) {
  return ref.watch(experimentDaoProvider).watchAll();
});

/// 实验详情（FutureProvider.autoDispose.family）。
///
/// 包含实验主记录 + 变体列表 + 运行列表。
final experimentDetailProvider =
    FutureProvider.autoDispose.family<ExperimentDetail, String>((ref, id) {
  return ref.watch(experimentServiceProvider).getExperimentDetail(id);
});

/// 实验比较结果（FutureProvider.autoDispose.family）。
///
/// 返回描述性比较，不做统计显著性推断。
final experimentComparisonProvider =
    FutureProvider.autoDispose.family<ExperimentComparison, String>((ref, id) {
  return ref.watch(experimentServiceProvider).compareExperiment(id);
});
