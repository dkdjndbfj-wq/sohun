/// 参数兼容性评估模型。
///
/// 评估结果包含：
/// - [status]：兼容/注意/不兼容/未知
/// - [score]：0-100 分（与 confidence 分开）
/// - [confidence]：0-100 置信度（缺少数据时降低）
/// - [blockers]：硬性阻断项（存在时禁止发送打印）
/// - [warnings]：警告项（用户可二次确认继续）
/// - [matchedFacts]：已匹配的事实（用于解释）
/// - [missingFacts]：缺失数据列表（用于降低 confidence）
///
/// 评分与置信度必须分开。缺少喷嘴或打印机能力数据时不能假装高分，
/// 而应降低 confidence 或返回 unknown。
library;

/// 兼容性状态枚举。
enum CompatibilityStatus {
  /// 兼容：无 blocker、无 warning，confidence 足够。
  compatible('compatible'),

  /// 注意：无 blocker 但有 warning 或 confidence 偏低。
  caution('caution'),

  /// 不兼容：存在硬性阻断项，禁止发送打印。
  incompatible('incompatible'),

  /// 未知：关键数据缺失，无法评估。
  unknown('unknown');

  final String value;
  const CompatibilityStatus(this.value);

  /// 是否允许发送打印（硬性阻断时不允许）。
  bool get canSend =>
      this == CompatibilityStatus.compatible ||
      this == CompatibilityStatus.caution;

  /// 是否存在硬性阻断。
  bool get isBlocked => this == CompatibilityStatus.incompatible;

  /// 中文标签。
  String get label {
    switch (this) {
      case CompatibilityStatus.compatible:
        return '兼容';
      case CompatibilityStatus.caution:
        return '注意';
      case CompatibilityStatus.incompatible:
        return '不兼容';
      case CompatibilityStatus.unknown:
        return '未知';
    }
  }
}

/// 兼容性原因：一条命中的规则或缺失的数据。
class CompatibilityReason {
  /// 规则 ID（稳定标识，用于测试和日志）。
  final String ruleId;

  /// 中文标题。
  final String title;

  /// 中文详细说明。
  final String detail;

  /// 命中的事实值（用于解释，如 "参数要求喷嘴 0.6mm，当前喷嘴 0.4mm"）。
  final String? matchedValue;

  /// 规则来源版本（用于追溯）。
  final String? ruleVersion;

  const CompatibilityReason({
    required this.ruleId,
    required this.title,
    required this.detail,
    this.matchedValue,
    this.ruleVersion,
  });

  @override
  String toString() => 'CompatibilityReason($ruleId: $title)';
}

/// 兼容性评估结果。
class CompatibilityAssessment {
  /// 评估状态。
  final CompatibilityStatus status;

  /// 综合评分（0-100）。
  ///
  /// 与 [confidence] 分开：score 反映"如果数据准确，参数有多兼容"，
  /// confidence 反映"我们对这个评分有多确定"。
  final int score;

  /// 置信度（0-100）。
  ///
  /// 缺少喷嘴、打印机能力或材料数据时降低。
  /// confidence < 50 时 status 应为 unknown。
  final int confidence;

  /// 硬性阻断项列表。
  ///
  /// 存在任一 blocker 时 [status] 为 incompatible，禁止发送打印。
  final List<CompatibilityReason> blockers;

  /// 警告项列表。
  ///
  /// 用户可看完原因后二次确认继续，并在本地记录 override 原因。
  final List<CompatibilityReason> warnings;

  /// 已匹配的事实列表（用于解释评分依据）。
  final List<CompatibilityReason> matchedFacts;

  /// 缺失数据列表（字段名，用于降低 confidence）。
  final List<String> missingFacts;

  /// 规则版本（用于追溯评估使用的规则集版本）。
  final String ruleVersion;

  const CompatibilityAssessment({
    required this.status,
    required this.score,
    required this.confidence,
    required this.blockers,
    required this.warnings,
    required this.matchedFacts,
    required this.missingFacts,
    this.ruleVersion = '1.0.0',
  });

  /// 未知评估（数据严重不足）。
  static const CompatibilityAssessment unknown = CompatibilityAssessment(
    status: CompatibilityStatus.unknown,
    score: 0,
    confidence: 0,
    blockers: [],
    warnings: [],
    matchedFacts: [],
    missingFacts: ['printer_model', 'nozzle_diameter', 'material_profile'],
  );

  /// 是否允许发送打印。
  bool get canSend => status.canSend;

  /// 是否存在硬性阻断。
  bool get isBlocked => status.isBlocked;

  @override
  String toString() =>
      'CompatibilityAssessment(status=$status, score=$score, confidence=$confidence, '
      'blockers=${blockers.length}, warnings=${warnings.length})';
}

/// 运行准备度评估（RunReadinessAssessment）。
///
/// 与 [CompatibilityAssessment] 分开：
/// 兼容性只评估"参数与设备/材料是否匹配"，不评估库存余量、打印机离线、机器忙碌等运行时状态。
/// 运行准备度评估库存、设备状态和文件可用性，调度器组合两个评估结果。
class RunReadinessAssessment {
  /// 是否就绪可发送。
  final bool ready;

  /// 阻断原因列表（库存不足、打印机离线、文件丢失等）。
  final List<CompatibilityReason> blockers;

  /// 警告原因列表。
  final List<CompatibilityReason> warnings;

  const RunReadinessAssessment({
    required this.ready,
    required this.blockers,
    required this.warnings,
  });

  static const RunReadinessAssessment unknown = RunReadinessAssessment(
    ready: false,
    blockers: [],
    warnings: [],
  );

  @override
  String toString() =>
      'RunReadinessAssessment(ready=$ready, blockers=${blockers.length})';
}
