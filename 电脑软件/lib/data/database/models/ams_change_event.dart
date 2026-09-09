// AMS 换料事件模型。
//
// 多色 AMS 打印任务执行过程中会触发多次换料（trayNow 变化）。
// 每次换料事件记录：
// - 物理通道（channel_index）：对应 PrinterChannels.channelIndex
// - G-code 工具号（tool_index）：从 trayNow 解析
// - 关联的耗材卷（consumable_id）：换料前该通道绑定的耗材
// - 事件类型（switch / empty / refill）
// - previous_remaining_grams：换料前剩余克数
// - consumed_grams_at_event：该次换料时本卷已消耗克数
//
// 数据库表结构事实来源：[AppDatabase._createAmsChangeEventsTable] 的 raw SQL
// （见 lib/data/database/database.dart）。本文件字段与该 SQL 保持一致。

/// AMS 换料事件类型。
///
/// - [switch_]：普通换料（trayNow 真实变化）
/// - [empty]：耗材已用完（业务后续可扩展）
/// - [refill]：耗材补充（业务后续可扩展）
///
/// 当前实现仅自动记录 [switch_] 事件（trayNow 变化时触发）。
/// [empty] / [refill] 预留给未来 UI 主动写入。
enum AmsChangeEventType {
  switch_('switch'),
  empty('empty'),
  refill('refill');

  final String code;
  const AmsChangeEventType(this.code);

  static AmsChangeEventType fromCode(String code) {
    for (final t in AmsChangeEventType.values) {
      if (t.code == code) return t;
    }
    return AmsChangeEventType.switch_;
  }
}

/// AMS 换料事件记录。
///
/// 一次 [AmsChangeEvent] 对应一次 trayNow 变化（普通换料）。
/// 通过 [AmsChangeEventDao.create] 写入数据库。
class AmsChangeEvent {
  final int? id;

  /// 打印机 id（外键 printers.id，ON DELETE SET NULL）。
  final int? printerId;

  /// 打印任务 id（外键 print_tasks.id，ON DELETE CASCADE）。
  /// 关联到当前活跃任务（从 PrintTaskDao.getActive() 取首条）。
  final int? taskId;

  /// 物理通道索引（amsId * 4 + slot）。
  /// 对应 PrinterChannels.channelIndex，用于查找绑定的耗材。
  final int channelIndex;

  /// G-code 工具索引（trayNow 转换得到）。
  /// 通常与 channelIndex 相同（单 AMS 默认映射），多 AMS 场景可单独区分。
  final int toolIndex;

  /// 关联耗材卷 id（外键 consumables.id，ON DELETE SET NULL）。
  /// 为 null 表示该通道未绑定耗材（无法精确归属）。
  final int? consumableId;

  /// 事件类型。
  final AmsChangeEventType eventType;

  /// 换料前剩余克数（从 consumables.remainingGrams 读取）。
  final double? previousRemainingGrams;

  /// 该次换料时本卷已消耗克数（默认 0，后续可由业务计算）。
  final double consumedGramsAtEvent;

  /// 事件发生时间。
  final DateTime occurredAt;

  /// 备注。
  final String? note;

  /// 换色目标颜色 HEX（如 "#FF0000"）。
  ///
  /// v16 新增字段，用于记录每次换色的目标颜色，便于回溯。
  /// 来源：G-code 头部 `filament_colour` 列表，按 [toolIndex] 索引。
  /// 外挂料多色打印场景下，记录用户手动换上的耗材颜色。
  final String? colorHex;

  const AmsChangeEvent({
    this.id,
    this.printerId,
    this.taskId,
    required this.channelIndex,
    required this.toolIndex,
    this.consumableId,
    required this.eventType,
    this.previousRemainingGrams,
    this.consumedGramsAtEvent = 0,
    required this.occurredAt,
    this.note,
    this.colorHex,
  });

  AmsChangeEvent copyWith({
    int? id,
    int? printerId,
    int? taskId,
    int? channelIndex,
    int? toolIndex,
    int? consumableId,
    AmsChangeEventType? eventType,
    double? previousRemainingGrams,
    double? consumedGramsAtEvent,
    DateTime? occurredAt,
    String? note,
    String? colorHex,
  }) {
    return AmsChangeEvent(
      id: id ?? this.id,
      printerId: printerId ?? this.printerId,
      taskId: taskId ?? this.taskId,
      channelIndex: channelIndex ?? this.channelIndex,
      toolIndex: toolIndex ?? this.toolIndex,
      consumableId: consumableId ?? this.consumableId,
      eventType: eventType ?? this.eventType,
      previousRemainingGrams:
          previousRemainingGrams ?? this.previousRemainingGrams,
      consumedGramsAtEvent: consumedGramsAtEvent ?? this.consumedGramsAtEvent,
      occurredAt: occurredAt ?? this.occurredAt,
      note: note ?? this.note,
      colorHex: colorHex ?? this.colorHex,
    );
  }

  @override
  String toString() =>
      'AmsChangeEvent(task#$taskId T$toolIndex ch$channelIndex: '
      '${eventType.code} @ $occurredAt, color=$colorHex)';
}
