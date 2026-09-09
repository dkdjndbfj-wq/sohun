/// 参数实验平台数据模型。
///
/// 任务书 Phase D 要求：
/// - parameter_experiments：实验名称、目标、基础参数、控制变量说明、评价指标、状态。
/// - experiment_variants：A/B/更多变体、不可变参数快照、指纹、相对基线 diff。
/// - experiment_runs：变体、运行序号、打印任务、打印机、耗材、结果、顺序、状态。
/// - 外键删除策略必须保留历史。删除当前参数预设不能删除已执行实验的快照。
///
/// 公平性规则（任务书 9.4）：
/// - 默认交替顺序 A-B-A-B；多变体可采用确定性轮换。
/// - 每次运行锁定参数 fingerprint，参数被修改后必须创建新变体 revision。
/// - 自动结果来自 preset_print_results，用户评分从同一结果表读取。
/// - 任一组未达到目标或数据缺失时显示"样本未完成"，不显示领先结论。
/// - 本期 UI 禁止使用"显著""胜出""最佳参数""推荐方案"等统计或保证性文案。
library;

import 'package:flutter/foundation.dart';

/// 实验状态。
enum ExperimentStatus {
  /// 草稿（未启动）。
  draft('draft'),

  /// 进行中（已生成运行计划）。
  running('running'),

  /// 已暂停（用户手动暂停）。
  paused('paused'),

  /// 已完成（所有运行结束）。
  completed('completed'),

  /// 已归档（不再活跃，但保留历史）。
  archived('archived'),

  /// 已取消。
  cancelled('cancelled');

  final String value;
  const ExperimentStatus(this.value);

  static ExperimentStatus fromString(String? v) {
    return switch (v) {
      'running' => ExperimentStatus.running,
      'paused' => ExperimentStatus.paused,
      'completed' => ExperimentStatus.completed,
      'archived' => ExperimentStatus.archived,
      'cancelled' => ExperimentStatus.cancelled,
      _ => ExperimentStatus.draft,
    };
  }

  /// 是否可启动/恢复。
  bool get canStart =>
      this == ExperimentStatus.draft || this == ExperimentStatus.paused;

  /// 是否可暂停。
  bool get canPause => this == ExperimentStatus.running;

  /// 是否可归档。
  bool get canArchive =>
      this == ExperimentStatus.completed || this == ExperimentStatus.cancelled;

  /// 是否终态。
  bool get isTerminal =>
      this == ExperimentStatus.archived || this == ExperimentStatus.cancelled;
}

/// 实验运行状态。
enum RunStatus {
  pending('pending'),
  queued('queued'),
  printing('printing'),
  completed('completed'),
  failed('failed'),
  cancelled('cancelled'),
  skipped('skipped');

  final String value;
  const RunStatus(this.value);

  static RunStatus fromString(String? v) {
    return switch (v) {
      'queued' => RunStatus.queued,
      'printing' => RunStatus.printing,
      'completed' => RunStatus.completed,
      'failed' => RunStatus.failed,
      'cancelled' => RunStatus.cancelled,
      'skipped' => RunStatus.skipped,
      _ => RunStatus.pending,
    };
  }

  /// 是否终态（运行已结束）。
  bool get isTerminal =>
      this == RunStatus.completed ||
      this == RunStatus.failed ||
      this == RunStatus.cancelled ||
      this == RunStatus.skipped;

  /// 是否成功完成（用于结果聚合）。
  bool get isSuccessful => this == RunStatus.completed;
}

/// 参数实验主记录。
@immutable
class ParameterExperiment {
  final String id;
  final String experimentUid;
  final String name;
  final String goal;
  final String? baselineSnapshotId;
  final String controlVariables;
  final String evaluationMetrics;
  final ExperimentStatus status;
  final int targetRepeats;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? archivedAt;

  const ParameterExperiment({
    required this.id,
    required this.experimentUid,
    required this.name,
    required this.goal,
    required this.baselineSnapshotId,
    required this.controlVariables,
    required this.evaluationMetrics,
    required this.status,
    required this.targetRepeats,
    required this.createdAt,
    required this.updatedAt,
    required this.archivedAt,
  });

  factory ParameterExperiment.fromRow(Map<String, dynamic> row) {
    return ParameterExperiment(
      id: row['id'] as String,
      experimentUid: row['experiment_uid'] as String,
      name: row['name'] as String,
      goal: (row['goal'] as String?) ?? '',
      baselineSnapshotId: row['baseline_snapshot_id'] as String?,
      controlVariables: (row['control_variables'] as String?) ?? '',
      evaluationMetrics: (row['evaluation_metrics'] as String?) ?? '',
      status: ExperimentStatus.fromString(row['status'] as String?),
      targetRepeats: (row['target_repeats'] as int?) ?? 3,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      archivedAt: row['archived_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['archived_at'] as int),
    );
  }
}

/// 实验变体（A/B/更多）。
@immutable
class ExperimentVariant {
  final String id;
  final String variantUid;
  final String experimentId;
  final String label; // A / B / C ...
  final String? snapshotId;
  final String diffSummary;
  final int revision;
  final DateTime createdAt;

  const ExperimentVariant({
    required this.id,
    required this.variantUid,
    required this.experimentId,
    required this.label,
    required this.snapshotId,
    required this.diffSummary,
    required this.revision,
    required this.createdAt,
  });

  factory ExperimentVariant.fromRow(Map<String, dynamic> row) {
    return ExperimentVariant(
      id: row['id'] as String,
      variantUid: row['variant_uid'] as String,
      experimentId: row['experiment_id'] as String,
      label: (row['label'] as String?) ?? 'A',
      snapshotId: row['snapshot_id'] as String?,
      diffSummary: (row['diff_summary'] as String?) ?? '',
      revision: (row['revision'] as int?) ?? 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    );
  }
}

/// 实验运行（单次打印任务执行）。
@immutable
class ExperimentRun {
  final String id;
  final String runUid;
  final String experimentId;
  final String variantId;
  final int runOrder; // 交替顺序：1=A, 2=B, 3=A, 4=B...
  final int? taskId; // 关联 print_tasks
  final String? resultId; // 关联 preset_print_results
  final RunStatus status;
  final DateTime createdAt;
  final DateTime? completedAt;

  const ExperimentRun({
    required this.id,
    required this.runUid,
    required this.experimentId,
    required this.variantId,
    required this.runOrder,
    required this.taskId,
    required this.resultId,
    required this.status,
    required this.createdAt,
    required this.completedAt,
  });

  factory ExperimentRun.fromRow(Map<String, dynamic> row) {
    return ExperimentRun(
      id: row['id'] as String,
      runUid: row['run_uid'] as String,
      experimentId: row['experiment_id'] as String,
      variantId: row['variant_id'] as String,
      runOrder: (row['run_order'] as int?) ?? 0,
      taskId: row['task_id'] as int?,
      resultId: row['result_id'] as String?,
      status: RunStatus.fromString(row['status'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      completedAt: row['completed_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['completed_at'] as int),
    );
  }
}

/// 变体结果汇总（描述性比较，不做统计显著性推断）。
@immutable
class VariantResultSummary {
  final String variantId;
  final String label;

  /// 完成数（status == completed）。
  final int completedCount;

  /// 失败数（status == failed）。
  final int failedCount;

  /// 跳过数（status == skipped）。
  final int skippedCount;

  /// 总运行数。
  final int totalRuns;

  /// 完成率（completedCount / totalRuns）。totalRuns=0 时为 null。
  final double? completionRate;

  /// 用户可用率（来自 preset_print_results.user_outcome）。
  /// 分母为 user_outcome 非 null 的样本，无样本时为 null。
  final double? usableRate;

  /// 耗时均值（秒，仅 completed 运行）。
  final double? averageActualSeconds;

  /// 耗时标准差（秒，仅 completed 运行，描述性离散程度）。
  final double? stdDevActualSeconds;

  /// 克数均值（克，仅 completed 运行）。
  final double? averageActualGrams;

  /// 克数标准差（克，仅 completed 运行，描述性离散程度）。
  final double? stdDevActualGrams;

  /// 平均评分（仅非空 rating）。
  final double? averageRating;

  /// 评分人数。
  final int ratingCount;

  /// 是否达到目标重复次数（completedCount >= targetRepeats）。
  final bool meetsTarget;

  /// 完成样本数（用于比较判断）。
  int get effectiveSampleCount => completedCount;

  const VariantResultSummary({
    required this.variantId,
    required this.label,
    required this.completedCount,
    required this.failedCount,
    required this.skippedCount,
    required this.totalRuns,
    required this.completionRate,
    required this.usableRate,
    required this.averageActualSeconds,
    required this.stdDevActualSeconds,
    required this.averageActualGrams,
    required this.stdDevActualGrams,
    required this.averageRating,
    required this.ratingCount,
    required this.meetsTarget,
  });
}

/// 实验比较结果（描述性，不做统计显著性推断）。
///
/// 任务书要求：
/// - 任一组未达到目标或数据缺失时显示"样本未完成"，不显示领先结论。
/// - 达到目标且控制条件一致时可显示"当前指标领先"，注明描述性结果，
///   必须展示绝对差、百分比、样本数和离散程度。
/// - 永远不出现"显著胜出"。
@immutable
class ExperimentComparison {
  /// 比较的变体列表（按 label 排序）。
  final List<VariantResultSummary> variants;

  /// 是否所有变体都达到目标。
  final bool allMeetTarget;

  /// 评价指标（来自实验配置）。
  final String evaluationMetric;

  /// 当前指标领先的变体 ID（描述性，非显著性）。
  /// null 表示无法判断（样本不足或并列）。
  final String? leadingVariantId;

  /// 领先变体的描述性说明（绝对差、百分比、样本数、离散程度）。
  final String? leadingDescription;

  /// 是否可用率并列。
  final bool isTied;

  const ExperimentComparison({
    required this.variants,
    required this.allMeetTarget,
    required this.evaluationMetric,
    required this.leadingVariantId,
    required this.leadingDescription,
    required this.isTied,
  });
}
