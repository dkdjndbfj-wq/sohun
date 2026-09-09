/// 跨打印机智能调度数据模型。
///
/// 调度器把任务分配到精确匹配机型 + 喷嘴直径的打印机。
/// 机型组（[PrinterModelGroup]）只用于 UI 分组或候选提示，
/// **不能**作为发送现成 G-code 的安全依据。
///
/// 配套 DAO 见 [SchedulerDao]，调度算法见 [SchedulerNotifier]。
library;

import '../../../core/services/printer_model_normalizer.dart';

/// 机型兼容性分组（仅用于 UI 分组或候选提示）。
///
/// **重要约束**：拓竹同机型组内 G-code **不一定**通用。
/// 例如 A1 组包含 A1 和 A1 mini，但两者的 G-code 不互通。
/// 此枚举仅用于 UI 折叠分组，调度器匹配必须用
/// [PrinterModelNormalizer.sameModel] 精确匹配 canonical 型号
/// + 喷嘴直径。
enum PrinterModelGroup {
  a1('A1 组', ['A1', 'A1 mini']),
  p1('P1 组', ['P1S', 'P1P']),
  x1('X1 组', ['X1C', 'X1E']),
  h2d('H2D 组', ['H2D']);

  final String label;
  final List<String> models;
  const PrinterModelGroup(this.label, this.models);

  /// 按打印机型号字符串解析机型组（仅用于 UI 分组）。
  ///
  /// **警告**：返回值非 null 不代表任务可安全发往该组任一打印机。
  /// 任务分配必须用 PrinterModelNormalizer.sameModel 精确匹配。
  static PrinterModelGroup? fromModel(String model) {
    final n = PrinterModelNormalizer.normalize(model);
    if (n.isEmpty) return null;
    for (final g in PrinterModelGroup.values) {
      // 对 models 列表中的每个值也做规范化后再比较，
      // 避免 'A1 mini'（带空格）与 normalize 返回的 'A1mini'（无空格）不匹配。
      if (g.models.any((x) => n == PrinterModelNormalizer.normalize(x))) {
        return g;
      }
    }
    return null;
  }
}

/// 调度任务状态。
enum SchedulerTaskStatus {
  pending('待分配'),
  assigned('已分配'),
  printing('打印中'),
  completed('已完成'),
  cancelled('已取消'),
  failed('已失败'),
  blocked('已阻塞');

  final String label;
  const SchedulerTaskStatus(this.label);

  /// 从数据库存储字符串解析状态。
  static SchedulerTaskStatus fromCode(String code) {
    for (final s in SchedulerTaskStatus.values) {
      if (s.name == code) return s;
    }
    return SchedulerTaskStatus.pending;
  }

  /// 是否处于终态（任务结束，不再推进）。
  bool get isTerminal =>
      this == SchedulerTaskStatus.completed ||
      this == SchedulerTaskStatus.cancelled ||
      this == SchedulerTaskStatus.failed;

  /// 是否可重新调度（取消/阻塞/失败后允许重置回 pending）。
  bool get canReschedule =>
      this == SchedulerTaskStatus.cancelled ||
      this == SchedulerTaskStatus.blocked ||
      this == SchedulerTaskStatus.failed;
}

/// 调度任务。对应 scheduler_tasks 表一行。
class SchedulerTask {
  final int? id;
  final String gcodePath;
  final String gcodeFilename;
  final PrinterModelGroup modelGroup; // UI 分组用，不作为调度安全依据
  final String requiredMaterial; // 单材质任务（多材质走 scheduler_task_materials）
  final String? requiredColorHex; // 单色任务（多色走 scheduler_task_materials）
  final double estimatedGrams; // 预估耗材克数（单色任务总数）
  final int? estimatedSeconds; // 预估打印时长（秒）
  final SchedulerTaskStatus status;
  final int? assignedPrinterId; // 已分配到的打印机
  final int sortOrder; // 排序
  final DateTime createdAt;
  final DateTime? assignedAt;
  final DateTime? completedAt;
  final String? note;
  // 已分配打印机的名称（LEFT JOIN printers 带 out，非持久化字段）。
  // 仅用于 UI 显示，不参与 insert/update。
  final String? assignedPrinterName;
  // 调度失败/阻塞原因（assigned 失败回退 pending/blocked 时填）。
  // 非持久化字段，由调度器在内存中临时填入，供 UI 展示。
  final String? lastRejectReason;

  /// v21：精确目标机型 canonical ID（如 "X1C"、"A1mini"）。
  /// 任务书要求：不能把宽泛机型组作为发送现成 G-code 的安全依据。
  /// 旧任务无此信息时为 null，调度器回退到 model_group + 默认喷嘴。
  final String? targetModel;

  /// v21：目标喷嘴直径（mm，如 0.4）。
  /// 0.4mm G-code 不能发到 0.6mm 喷嘴的机器。
  /// 旧任务无此信息时为 null，调度器默认 0.4mm。
  final double? targetNozzleDiameter;

  SchedulerTask({
    this.id,
    required this.gcodePath,
    required this.gcodeFilename,
    required this.modelGroup,
    required this.requiredMaterial,
    this.requiredColorHex,
    required this.estimatedGrams,
    this.estimatedSeconds,
    this.status = SchedulerTaskStatus.pending,
    this.assignedPrinterId,
    this.sortOrder = 0,
    required this.createdAt,
    this.assignedAt,
    this.completedAt,
    this.note,
    this.assignedPrinterName,
    this.lastRejectReason,
    this.targetModel,
    this.targetNozzleDiameter,
  });

  /// 任务的目标机型 spec（用于精确匹配）。
  /// 若 [targetModel] 为空，返回 null（调度器回退到 model_group）。
  PrinterModelSpec? get targetSpec {
    if (targetModel == null || targetModel!.isEmpty) return null;
    return PrinterModelSpec(
      canonicalModel: targetModel!,
      nozzleDiameter: targetNozzleDiameter ?? 0.4,
    );
  }

  SchedulerTask copyWith({
    int? id,
    String? gcodePath,
    String? gcodeFilename,
    PrinterModelGroup? modelGroup,
    String? requiredMaterial,
    String? requiredColorHex,
    double? estimatedGrams,
    int? estimatedSeconds,
    SchedulerTaskStatus? status,
    int? assignedPrinterId,
    int? sortOrder,
    DateTime? assignedAt,
    DateTime? completedAt,
    String? note,
    String? assignedPrinterName,
    String? lastRejectReason,
    String? targetModel,
    double? targetNozzleDiameter,
  }) {
    return SchedulerTask(
      id: id ?? this.id,
      gcodePath: gcodePath ?? this.gcodePath,
      gcodeFilename: gcodeFilename ?? this.gcodeFilename,
      modelGroup: modelGroup ?? this.modelGroup,
      requiredMaterial: requiredMaterial ?? this.requiredMaterial,
      requiredColorHex: requiredColorHex ?? this.requiredColorHex,
      estimatedGrams: estimatedGrams ?? this.estimatedGrams,
      estimatedSeconds: estimatedSeconds ?? this.estimatedSeconds,
      status: status ?? this.status,
      assignedPrinterId: assignedPrinterId ?? this.assignedPrinterId,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
      assignedAt: assignedAt ?? this.assignedAt,
      completedAt: completedAt ?? this.completedAt,
      note: note ?? this.note,
      assignedPrinterName: assignedPrinterName ?? this.assignedPrinterName,
      lastRejectReason: lastRejectReason ?? this.lastRejectReason,
      targetModel: targetModel ?? this.targetModel,
      targetNozzleDiameter: targetNozzleDiameter ?? this.targetNozzleDiameter,
    );
  }
}

/// 打印机精确型号规范（任务目标机型 + 喷嘴直径 + 打印板类型）。
///
/// 这是任务分配的安全匹配依据，与 [PrinterModelGroup]（仅 UI 分组）相对。
/// G-code 是为特定机型 + 喷嘴直径切片的，发错机器会撞机或不执行。
class PrinterModelSpec {
  /// canonical 型号 ID（如 "X1C"、"A1mini"）。
  /// 由 [PrinterModelNormalizer.normalize] 规范化后的值。
  final String canonicalModel;

  /// 喷嘴直径（mm，如 0.4）。
  /// 0.4mm G-code 不能发到 0.6mm 喷嘴的机器。
  final double nozzleDiameter;

  /// 打印板类型（如 "textured_pei_plate"）。
  /// null 表示切片未指定或兼容所有打印板。
  final String? plateType;

  /// G-code 头部声明的目标机型原始字符串（用于回查/调试）。
  final String? rawModel;

  const PrinterModelSpec({
    required this.canonicalModel,
    required this.nozzleDiameter,
    this.plateType,
    this.rawModel,
  });

  /// 是否与另一规格精确匹配（机型 + 喷嘴直径必须相同）。
  ///
  /// 打印板类型是软约束：任务指定打印板时优先匹配，未指定则不阻塞。
  /// 此方法只检查硬约束（机型 + 喷嘴）。
  bool matchesSpec(PrinterModelSpec other) {
    if (!PrinterModelNormalizer.sameModel(
      canonicalModel,
      other.canonicalModel,
    )) {
      return false;
    }
    // 喷嘴直径允许 0.001mm 误差（浮点比较）
    return (nozzleDiameter - other.nozzleDiameter).abs() < 0.001;
  }

  @override
  String toString() => 'PrinterModelSpec($canonicalModel, ${nozzleDiameter}mm'
      '${plateType != null ? ', plate=$plateType' : ''})';
}

/// 调度任务材料需求子表（scheduler_task_materials）的模型。
///
/// 多色任务必须逐个工具匹配材料和余量。不能把多色任务压成一个
/// required_material 字段（旧 schema 的限制）。
class SchedulerTaskMaterial {
  final int? id;
  final int schedulerTaskId;
  final int toolIndex; // T0/T1/T2...
  final String materialProfile; // 完整耗材 profile 名（如 "Bambu PLA Silk"）
  final String materialType; // 材质粗类（PLA/PETG/ABS...）
  final String? requiredColorHex; // 期望颜色（可选，软约束）
  final double estimatedGrams; // 该工具预计消耗克数
  final int? assignedConsumableId; // 调度器分配后填入的耗材卷 id

  const SchedulerTaskMaterial({
    this.id,
    required this.schedulerTaskId,
    required this.toolIndex,
    required this.materialProfile,
    required this.materialType,
    this.requiredColorHex,
    required this.estimatedGrams,
    this.assignedConsumableId,
  });

  SchedulerTaskMaterial copyWith({
    int? id,
    int? schedulerTaskId,
    int? toolIndex,
    String? materialProfile,
    String? materialType,
    String? requiredColorHex,
    double? estimatedGrams,
    int? assignedConsumableId,
  }) {
    return SchedulerTaskMaterial(
      id: id ?? this.id,
      schedulerTaskId: schedulerTaskId ?? this.schedulerTaskId,
      toolIndex: toolIndex ?? this.toolIndex,
      materialProfile: materialProfile ?? this.materialProfile,
      materialType: materialType ?? this.materialType,
      requiredColorHex: requiredColorHex ?? this.requiredColorHex,
      estimatedGrams: estimatedGrams ?? this.estimatedGrams,
      assignedConsumableId: assignedConsumableId ?? this.assignedConsumableId,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'scheduler_task_id': schedulerTaskId,
        'tool_index': toolIndex,
        'material_profile': materialProfile,
        'material_type': materialType,
        'required_color_hex': requiredColorHex,
        'estimated_grams': estimatedGrams,
        'assigned_consumable_id': assignedConsumableId,
      };

  static SchedulerTaskMaterial fromMap(Map<String, dynamic> map) {
    return SchedulerTaskMaterial(
      id: map['id'] as int?,
      schedulerTaskId: map['scheduler_task_id'] as int,
      toolIndex: map['tool_index'] as int,
      materialProfile: map['material_profile'] as String? ?? '',
      materialType: map['material_type'] as String? ?? '',
      requiredColorHex: map['required_color_hex'] as String?,
      estimatedGrams: (map['estimated_grams'] as num?)?.toDouble() ?? 0.0,
      assignedConsumableId: map['assigned_consumable_id'] as int?,
    );
  }
}

/// 耗材卷预留（spool_reservations 表）的模型。
///
/// 排队任务先预留耗材；两个任务不能同时把同一卷剩余量各算一遍。
/// 任务完成/失败/取消时调用 release 释放预留。
class SpoolReservation {
  final String id; // UUID
  final int schedulerTaskId;
  final int consumableId;
  final int toolIndex;
  final double reservedGrams;
  final DateTime reservedAt;
  final DateTime? releasedAt;
  final SpoolReservationStatus status;

  const SpoolReservation({
    required this.id,
    required this.schedulerTaskId,
    required this.consumableId,
    required this.toolIndex,
    required this.reservedGrams,
    required this.reservedAt,
    this.releasedAt,
    this.status = SpoolReservationStatus.active,
  });

  SpoolReservation copyWith({
    String? id,
    int? schedulerTaskId,
    int? consumableId,
    int? toolIndex,
    double? reservedGrams,
    DateTime? reservedAt,
    DateTime? releasedAt,
    SpoolReservationStatus? status,
  }) {
    return SpoolReservation(
      id: id ?? this.id,
      schedulerTaskId: schedulerTaskId ?? this.schedulerTaskId,
      consumableId: consumableId ?? this.consumableId,
      toolIndex: toolIndex ?? this.toolIndex,
      reservedGrams: reservedGrams ?? this.reservedGrams,
      reservedAt: reservedAt ?? this.reservedAt,
      releasedAt: releasedAt ?? this.releasedAt,
      status: status ?? this.status,
    );
  }

  static SpoolReservation fromMap(Map<String, dynamic> map) {
    return SpoolReservation(
      id: map['id'] as String,
      schedulerTaskId: map['scheduler_task_id'] as int,
      consumableId: map['consumable_id'] as int,
      toolIndex: (map['tool_index'] as num?)?.toInt() ?? 0,
      reservedGrams: (map['reserved_grams'] as num?)?.toDouble() ?? 0.0,
      reservedAt:
          DateTime.fromMillisecondsSinceEpoch(map['reserved_at'] as int),
      releasedAt: map['released_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(map['released_at'] as int),
      status: SpoolReservationStatus.fromCode(
        (map['status'] as String?) ?? 'active',
      ),
    );
  }
}

/// 预留状态。
enum SpoolReservationStatus {
  active('active'),
  released('released'),
  cancelled('cancelled');

  final String code;
  const SpoolReservationStatus(this.code);

  static SpoolReservationStatus fromCode(String code) {
    for (final s in SpoolReservationStatus.values) {
      if (s.code == code) return s;
    }
    return SpoolReservationStatus.active;
  }

  bool get isActive => this == SpoolReservationStatus.active;
}

/// 打印机调度候选评分（增强版）。
///
/// 由调度算法为每个候选打印机产出，包含每一项分值和拒绝原因列表。
/// 评分维度见 [SchedulingWeights]。
class PrinterCandidate {
  final int printerId;
  final String printerName;
  final PrinterModelGroup modelGroup; // UI 分组用

  /// 综合评分 0-100。
  final double score;

  /// 硬约束是否全部满足（任一硬约束不满足即淘汰，不参与排序）。
  final bool eligible;

  /// 逐项分值（仅 eligible=true 时有意义）
  final double earliestFinishScore; // 预计最早完工 35%
  final double materialColorScore; // 材料/颜色匹配 25%
  final double historyRateScore; // 最近 90 天同类任务成功率 15%
  final double changeCostScore; // 耗材换卷成本与余量利用 10%
  final double healthScore; // 设备健康和最近故障 10%
  final double batchAffinityScore; // 同批次连续性 5%

  /// 拒绝原因列表（eligible=false 时填，UI 展示 + 调度日志）。
  final List<String> rejectReasons;

  /// 关联的耗材匹配结果（多色任务逐工具匹配结果）。
  /// 索引对应 SchedulerTaskMaterial.toolIndex。
  final List<MaterialMatchResult> materialMatches;

  /// 状态新鲜度信息（过期状态不参与自动下发）。
  final PrinterStateFreshness? freshness;

  /// 是否仅云连接（无法自动下发，只能监控/排队）。
  final bool cloudOnly;

  /// 预计最早完工时间（综合评分用）。
  final DateTime? earliestFinishAt;

  /// 该机匹配通道的剩余克数（兼容旧字段，单色任务用）。
  final double? remainingGrams;

  /// 历史成功率（0.0-1.0）。
  final double? historySuccessRate;

  /// 预估时长（秒）。
  final int? estimatedSeconds;

  PrinterCandidate({
    required this.printerId,
    required this.printerName,
    required this.modelGroup,
    required this.score,
    required this.eligible,
    this.earliestFinishScore = 0,
    this.materialColorScore = 0,
    this.historyRateScore = 0,
    this.changeCostScore = 0,
    this.healthScore = 0,
    this.batchAffinityScore = 0,
    List<String>? rejectReasons,
    List<MaterialMatchResult>? materialMatches,
    this.freshness,
    this.cloudOnly = false,
    this.earliestFinishAt,
    this.remainingGrams,
    this.historySuccessRate,
    this.estimatedSeconds,
  })  : rejectReasons = rejectReasons ?? const [],
        materialMatches = materialMatches ?? const [];

  /// 旧字段兼容：materialMatched 等价于 eligible && materialMatches 全部成功。
  bool get materialMatched =>
      eligible &&
      materialMatches.isNotEmpty &&
      materialMatches.every((m) => m.matched);
}

/// 单个工具的材料匹配结果（多色任务逐工具匹配）。
class MaterialMatchResult {
  final int toolIndex;
  final String requiredMaterialType;
  final String? requiredColorHex;
  final double requiredGrams;
  final int? matchedConsumableId;
  final double matchedAvailableGrams; // 该卷扣除其他活动预留后的可用量
  final bool materialMatched;
  final bool colorMatched;
  final bool sufficient; // 余量是否足够（含安全缓冲）
  final String? rejectReason;

  const MaterialMatchResult({
    required this.toolIndex,
    required this.requiredMaterialType,
    this.requiredColorHex,
    required this.requiredGrams,
    this.matchedConsumableId,
    this.matchedAvailableGrams = 0,
    required this.materialMatched,
    required this.colorMatched,
    required this.sufficient,
    this.rejectReason,
  });

  bool get matched =>
      materialMatched &&
      sufficient &&
      matchedConsumableId != null &&
      (requiredColorHex == null || colorMatched);
}

/// 打印机状态新鲜度信息。
class PrinterStateFreshness {
  /// 状态最后更新时间（来自 status_updated_at）。
  final DateTime? statusUpdatedAt;

  /// 当前状态是否过期（超过 [SchedulingConfig.staleStatusThreshold]）。
  final bool stale;

  /// 是否为 LAN 可达（仅云连接设备 cloudOnly=true，无法自动下发）。
  final bool lanCapable;

  /// 打印机当前是否处于错误/维护/升级等不可下发状态。
  final bool printerBusy;

  /// 不可下发原因（printerBusy=true 时填）。
  final String? busyReason;

  const PrinterStateFreshness({
    this.statusUpdatedAt,
    required this.stale,
    required this.lanCapable,
    required this.printerBusy,
    this.busyReason,
  });

  /// 是否可用于自动下发：未过期 + LAN 可达 + 不在错误/维护/升级状态。
  bool get canAutoDispatch => !stale && lanCapable && !printerBusy;
}

/// 评分权重集中定义。
///
/// 任务书要求：
/// - 预计最早完工时间 35%
/// - 材料/颜色匹配 25%
/// - 最近 90 天同类任务成功率 15%
/// - 耗材换卷成本与余量利用 10%
/// - 设备健康和最近故障 10%
/// - 同批次连续性 5%
///
/// 总和必须等于 100。修改时需同步更新 [validateSum] 测试。
class SchedulingWeights {
  final double earliestFinish; // 35
  final double materialColor; // 25
  final double historyRate; // 15
  final double changeCost; // 10
  final double health; // 10
  final double batchAffinity; // 5

  const SchedulingWeights({
    this.earliestFinish = 35,
    this.materialColor = 25,
    this.historyRate = 15,
    this.changeCost = 10,
    this.health = 10,
    this.batchAffinity = 5,
  });

  /// 默认权重实例。
  static const SchedulingWeights defaults = SchedulingWeights();

  /// 权重总和（必须等于 100）。
  double get sum =>
      earliestFinish +
      materialColor +
      historyRate +
      changeCost +
      health +
      batchAffinity;

  /// 校验权重总和是否合法（100.0 ± 0.001）。
  bool get isValid => (sum - 100).abs() < 0.001;

  /// 把每项归一化到 0-1，再按权重加权得到综合分（0-100）。
  ///
  /// 每项输入应是 0-1 的归一化分值。
  double combine({
    required double earliestFinishNormalized,
    required double materialColorNormalized,
    required double historyRateNormalized,
    required double changeCostNormalized,
    required double healthNormalized,
    required double batchAffinityNormalized,
  }) {
    return earliestFinish * earliestFinishNormalized +
        materialColor * materialColorNormalized +
        historyRate * historyRateNormalized +
        changeCost * changeCostNormalized +
        health * healthNormalized +
        batchAffinity * batchAffinityNormalized;
  }
}

/// 调度器集中配置。
class SchedulingConfig {
  /// 余量安全缓冲：max(5g, 预计克数的 10%)。
  final double minBufferGrams;
  final double bufferRatio;

  /// 状态过期阈值（状态更新时间超过此阈值则不参与自动下发）。
  final Duration staleStatusThreshold;

  /// 历史成功率统计窗口（90 天）。
  final int historyRateWindowDays;

  /// 批次亲和性时间窗口（同批次认定窗口）。
  final Duration batchAffinityWindow;

  /// 最大并发连接数（PrinterFleetConnectionManager 用）。
  final int maxConcurrentConnections;

  /// 每台打印机最多保留的活动队列项（含正在打印和等待取件）。
  final int maxQueuedTasksPerPrinter;

  /// 调度器是否启用自动调度（持久化到 SharedPreferences，默认关闭）。
  final bool autoScheduleEnabledDefault;

  const SchedulingConfig({
    this.minBufferGrams = 5,
    this.bufferRatio = 0.10,
    this.staleStatusThreshold = const Duration(minutes: 5),
    this.historyRateWindowDays = 90,
    this.batchAffinityWindow = const Duration(minutes: 10),
    this.maxConcurrentConnections = 16,
    this.maxQueuedTasksPerPrinter = 5,
    this.autoScheduleEnabledDefault = false,
  });

  /// 默认配置实例。
  static const SchedulingConfig defaults = SchedulingConfig();

  /// 计算给定预计克数的安全缓冲。
  ///
  /// 任务书硬性要求：max(5g, 预计克数的 10%)。
  double safetyBuffer(double estimatedGrams) {
    final ratio = estimatedGrams * bufferRatio;
    return ratio > minBufferGrams ? ratio : minBufferGrams;
  }

  /// 判断状态时间戳是否过期。
  bool isStale(DateTime? statusUpdatedAt) {
    if (statusUpdatedAt == null) return true;
    return DateTime.now().difference(statusUpdatedAt) > staleStatusThreshold;
  }
}
