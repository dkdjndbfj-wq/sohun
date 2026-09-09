// 打印任务 ↔ 耗材卷 关联模型。
//
// 一个工具可以在打印中途换卷，每段分别关联实际消耗的实体卷。
// 本表记录每个任务消耗了哪些卷、每卷的预估/实际消耗克数、以及成本快照。
//
// 数据库表结构事实来源：[AppDatabase._createPrintTaskConsumablesTable] 的 raw SQL
// （见 lib/data/database/database.dart）。本文件字段与该 SQL 保持一致。

/// 打印任务 ↔ 耗材卷 关联记录。
///
/// 一个 [PrintTask] 会产生 1~N 条本记录(单色任务 1 条,4 色 AMS 任务最多 4 条)。
/// 每条记录对应切片 [SliceResult.filaments] 中的一个 [FilamentUsage]。
///
/// **实时扣减+完成修正**策略(用户选定)：
/// - 打印中：按 mcPercent 比例估算每卷消耗 `estimatedGrams × mcPercent / 100`，
///   差额扣减 `consumables.remainingGrams`（乐观扣减，让库存页即时反映）。
/// - 打印完成：按 `actualGrams` 总量按预估比例分配到各卷，修正 `remainingGrams` 差额，
///   并写入 `usage_logs` 作为最终结算。
class PrintTaskConsumable {
  final int? id;
  final int taskId;

  /// 打印机 id（冗余字段，便于按打印机汇总消耗，不必 JOIN print_tasks）
  ///
  /// nullable：表 print_task_consumables.printer_id 外键 printers(id)
  /// ON DELETE SET NULL，删除打印机后会被置空。读取时需判空。
  final int? printerId;

  /// 通道序号（0-based，对应 PrinterChannels.channelIndex）
  final int channelIndex;

  /// 耗材卷 id（外键 consumables.id，ON DELETE SET NULL）
  /// 为 null 表示该通道未绑定耗材（无法扣减库存，只能记估算）
  final int? consumableId;

  /// 工具号（0-based，对应切片 SliceResult.filaments[i].toolIndex / G-code T0/T1）
  final int toolIndex;

  /// 切片预估该卷消耗克数
  final double estimatedGrams;

  /// 同一工具在先前换卷段中已经结算的克数。当前段的预计余量加上
  /// 此偏移仍是该工具的完整预估，避免新卷从任务 0% 开始重扣。
  final double segmentStartGrams;

  double estimatedConsumedAt(int percent) =>
      ((estimatedGrams + segmentStartGrams) * percent.clamp(0, 100) / 100 -
              segmentStartGrams)
          .clamp(0.0, estimatedGrams)
          .toDouble();

  double finalSegmentGrams(double taskGrams, double taskEstimatedGrams) =>
      taskEstimatedGrams <= 0
      ? 0
      : (taskGrams * (estimatedGrams + segmentStartGrams) / taskEstimatedGrams -
                segmentStartGrams)
            .clamp(0.0, double.infinity)
            .toDouble();

  /// 实际消耗克数（任务完成时按 actualGrams 比例分配写入）
  final double consumedGrams;

  /// 实时扣减累计值（用于完成时算差额修正）。
  /// 每次按 mcPercent 估算后更新此值，完成时 `差额 = consumedGrams - lastDeductedGrams`。
  final double lastDeductedGrams;

  /// 成本快照（元/kg，任务创建时从 filament_cost_configs 匹配并冻结）。
  /// 防止用户后期改单价导致历史成本被篡改。
  final double? costPerKgSnapshot;

  /// 匹配到的成本配置 id（null 表示未匹配到，需提示用户去配置单价）
  final int? matchedCostConfigId;

  /// 结算时刻（consumed_at）。null = 尚未结算。
  /// 幂等结算的关键字段：结算时若该字段非空表示已结算过，直接跳过，
  /// 防止 stop() 与 MQTT idle 竞态导致重复写 usage_logs（统计翻倍）。
  final DateTime? consumedAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  const PrintTaskConsumable({
    this.id,
    required this.taskId,
    required this.printerId,
    required this.channelIndex,
    this.consumableId,
    required this.toolIndex,
    required this.estimatedGrams,
    this.segmentStartGrams = 0,
    this.consumedGrams = 0,
    this.lastDeductedGrams = 0,
    this.costPerKgSnapshot,
    this.matchedCostConfigId,
    this.consumedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 该卷的成本（实际消耗 × 快照单价）
  double get cost {
    if (costPerKgSnapshot == null) return 0;
    return consumedGrams / 1000 * costPerKgSnapshot!;
  }

  PrintTaskConsumable copyWith({
    int? id,
    int? taskId,
    int? printerId,
    int? channelIndex,
    int? consumableId,
    int? toolIndex,
    double? estimatedGrams,
    double? segmentStartGrams,
    double? consumedGrams,
    double? lastDeductedGrams,
    double? costPerKgSnapshot,
    int? matchedCostConfigId,
    DateTime? consumedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return PrintTaskConsumable(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      printerId: printerId ?? this.printerId,
      channelIndex: channelIndex ?? this.channelIndex,
      consumableId: consumableId ?? this.consumableId,
      toolIndex: toolIndex ?? this.toolIndex,
      estimatedGrams: estimatedGrams ?? this.estimatedGrams,
      segmentStartGrams: segmentStartGrams ?? this.segmentStartGrams,
      consumedGrams: consumedGrams ?? this.consumedGrams,
      lastDeductedGrams: lastDeductedGrams ?? this.lastDeductedGrams,
      costPerKgSnapshot: costPerKgSnapshot ?? this.costPerKgSnapshot,
      matchedCostConfigId: matchedCostConfigId ?? this.matchedCostConfigId,
      consumedAt: consumedAt ?? this.consumedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'PrintTaskConsumable(task#$taskId T$toolIndex ch$channelIndex: '
      'est=${estimatedGrams.toStringAsFixed(1)}g consumed=${consumedGrams.toStringAsFixed(1)}g)';
}
