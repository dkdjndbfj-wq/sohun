// 打印任务状态枚举 + 数据模型。
//
// 从 `print_task_dao.dart` 拆分而来，让 `gram_calculator.dart`、
// `print_task_state_machine.dart` 等"仅需模型"的模块不必导入 DAO 文件，
// 降低耦合。
//
// 数据库表结构事实来源：[AppDatabase._createPrintTasksTable] 的 raw SQL
// （见 lib/data/database/database.dart）。本文件字段与该 SQL 保持一致。

/// 打印任务状态枚举。对应 print_tasks.status 列。
///
/// 状态机：
/// ```
/// planned → printing → paused ⇄ printing → finished
///                 │              │
///                 └──→ cancelled ←┘
///                 └──→ failed
/// ```
/// - planned: 已创建任务但未发送到打印机
/// - printing: 打印机正在执行
/// - paused: 用户主动暂停
/// - finished: 正常完成（mc_percent=100）
/// - cancelled: 用户主动停止
/// - failed: 打印机报错（gcode_state=FAILED）
enum PrintTaskStatus {
  planned('planned', '已规划'),
  printing('printing', '打印中'),
  paused('paused', '已暂停'),
  finished('finished', '已完成'),
  cancelled('cancelled', '已取消'),
  failed('failed', '已失败');

  final String code;
  final String label;
  const PrintTaskStatus(this.code, this.label);

  static PrintTaskStatus fromCode(String code) {
    for (final s in PrintTaskStatus.values) {
      if (s.code == code) return s;
    }
    return PrintTaskStatus.planned;
  }

  /// 是否处于终态（任务结束）
  bool get isTerminal =>
      this == PrintTaskStatus.finished ||
      this == PrintTaskStatus.cancelled ||
      this == PrintTaskStatus.failed;

  /// 是否处于活跃状态（未结束，仍可推进/控制）。
  /// 与 [isTerminal] 互斥。SQL getActive() 用此谓词派生 IN 子句。
  bool get isActive => !isTerminal;

  /// 是否处于活跃状态（在消耗耗材）
  bool get isConsuming => this == PrintTaskStatus.printing;

  /// 是否可暂停
  bool get canPause => this == PrintTaskStatus.printing;

  /// 是否可恢复
  bool get canResume => this == PrintTaskStatus.paused;

  /// 是否可停止
  bool get canStop =>
      this == PrintTaskStatus.printing || this == PrintTaskStatus.paused;
}

/// 打印任务数据类。对应 print_tasks 表的行。
///
/// 不走 drift 代码生成（因 drift_dev 2.34 与 sqlparser 0.44 不兼容），
/// 手写字段映射。所有 CRUD 通过 [PrintTaskDao] 的 raw SQL 实现。
class PrintTask {
  final int? id;
  final String uid;
  final int? printerId;
  final int? consumableId;
  final String gcodePath;
  final String taskName;
  final double estimatedGrams;
  final int estimatedSeconds;
  final double actualGrams;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int lastMcPercent;
  final int lastLayer;
  final PrintTaskStatus status;
  final String source;
  final List<double> perFilamentGrams;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  const PrintTask({
    this.id,
    required this.uid,
    this.printerId,
    this.consumableId,
    required this.gcodePath,
    required this.taskName,
    required this.estimatedGrams,
    required this.estimatedSeconds,
    required this.actualGrams,
    this.startedAt,
    this.finishedAt,
    required this.lastMcPercent,
    required this.lastLayer,
    required this.status,
    required this.source,
    this.perFilamentGrams = const [],
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 预计总克数 → 已消耗克数百分比（0-100）
  double get consumedPercent {
    if (estimatedGrams <= 0) return 0;
    return (actualGrams / estimatedGrams * 100).clamp(0, 100);
  }

  /// 剩余克数
  double get remainingGrams {
    final r = estimatedGrams - actualGrams;
    return r < 0 ? 0 : r;
  }

  /// 已用时长（秒）。任务未完成时取 now - startedAt
  int get elapsedSeconds {
    final start = startedAt;
    if (start == null) return 0;
    final end = finishedAt ?? DateTime.now();
    return end.difference(start).inSeconds;
  }

  PrintTask copyWith({
    int? id,
    String? uid,
    int? printerId,
    int? consumableId,
    String? gcodePath,
    String? taskName,
    double? estimatedGrams,
    int? estimatedSeconds,
    double? actualGrams,
    DateTime? startedAt,
    DateTime? finishedAt,
    int? lastMcPercent,
    int? lastLayer,
    PrintTaskStatus? status,
    String? source,
    List<double>? perFilamentGrams,
    String? note,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return PrintTask(
      id: id ?? this.id,
      uid: uid ?? this.uid,
      printerId: printerId ?? this.printerId,
      consumableId: consumableId ?? this.consumableId,
      gcodePath: gcodePath ?? this.gcodePath,
      taskName: taskName ?? this.taskName,
      estimatedGrams: estimatedGrams ?? this.estimatedGrams,
      estimatedSeconds: estimatedSeconds ?? this.estimatedSeconds,
      actualGrams: actualGrams ?? this.actualGrams,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      lastMcPercent: lastMcPercent ?? this.lastMcPercent,
      lastLayer: lastLayer ?? this.lastLayer,
      status: status ?? this.status,
      source: source ?? this.source,
      perFilamentGrams: perFilamentGrams ?? this.perFilamentGrams,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'PrintTask($taskName: ${status.label}, ${actualGrams.toStringAsFixed(1)}/${estimatedGrams.toStringAsFixed(1)}g, $lastMcPercent%)';
}
