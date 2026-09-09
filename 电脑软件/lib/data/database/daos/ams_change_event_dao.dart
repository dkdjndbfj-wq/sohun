import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../database.dart';
import '../models/ams_change_event.dart';

export '../models/ams_change_event.dart'
    show AmsChangeEvent, AmsChangeEventType;

/// AMS 换料事件数据访问层。raw SQL 实现（不走 drift 代码生成）。
///
/// 配合 [PrinterConnectionProvider._maybeRecordAmsChange]：
/// - 打印中 trayNow 变化时调用 [create] 记录一次换料事件
/// - 任务详情页可查 [getByTask] / [watchByTask] 看历史换料记录
/// - 耗材卷详情页可查 [getByConsumable] 看该卷被换上/换下的历史
class AmsChangeEventDao extends DatabaseAccessor<AppDatabase> {
  AmsChangeEventDao(super.db);

  // 全局变更广播。任何 CRUD 后调用 _emit()，所有 watch 流都会收到最新结果。
  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  void _emit() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  /// 监听数据库变更事件（无 payload，仅作"重新查询"信号）。
  Stream<void> get changeStream => _changeController.stream;

  /// 创建换料事件。返回新插入的 id。
  Future<int> create(AmsChangeEvent event) async {
    final id = await customInsert(
      '''
      INSERT INTO ams_change_events (
        printer_id, task_id, channel_index, tool_index, consumable_id,
        event_type, previous_remaining_grams, consumed_grams_at_event,
        occurred_at, note, color_hex
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable(event.printerId),
        Variable(event.taskId),
        Variable(event.channelIndex),
        Variable(event.toolIndex),
        Variable(event.consumableId),
        Variable(event.eventType.code),
        Variable(event.previousRemainingGrams),
        Variable(event.consumedGramsAtEvent),
        Variable(event.occurredAt.millisecondsSinceEpoch),
        Variable(event.note),
        Variable(event.colorHex),
      ],
    );
    _emit();
    return id;
  }

  /// 查询任务的所有换料事件（按时间正序）。
  Future<List<AmsChangeEvent>> getByTask(int taskId) async {
    final rows = await customSelect(
      'SELECT * FROM ams_change_events WHERE task_id = ? '
      'ORDER BY occurred_at ASC',
      variables: [Variable(taskId)],
    ).get();
    return rows.map(_rowToEvent).toList();
  }

  /// 查询耗材卷的所有换料事件（按时间倒序）。
  Future<List<AmsChangeEvent>> getByConsumable(int consumableId) async {
    final rows = await customSelect(
      'SELECT * FROM ams_change_events WHERE consumable_id = ? '
      'ORDER BY occurred_at DESC',
      variables: [Variable(consumableId)],
    ).get();
    return rows.map(_rowToEvent).toList();
  }

  /// 监听任务的换料事件流（任务详情页用）。
  /// 先发射当前数据，再监听变更流（避免初始 loading 卡死）。
  ///
  /// try-catch 包裹 await for 防止单次查询异常终止整个流：
  /// - 内层 try-catch 捕获查询异常，debugPrint 后 continue（流不终止）
  /// - 外层 try-catch 兜底捕获流本身异常（如 controller close），优雅关闭
  Stream<List<AmsChangeEvent>> watchByTask(int taskId) async* {
    yield await getByTask(taskId);
    try {
      await for (final _ in _changeController.stream) {
        try {
          yield await getByTask(taskId);
        } catch (e) {
          debugPrint('[AmsChangeEventDao] watchByTask($taskId) 查询失败: $e');
          continue;
        }
      }
    } catch (e) {
      debugPrint('[AmsChangeEventDao] watchByTask($taskId) 流异常: $e');
    }
  }

  /// 查询任务的换料次数（仅统计 switch 类型）。
  /// 用于任务卡片/详情页显示"换料 N 次"。
  Future<int> getChangeCountByTask(int taskId) async {
    final rows = await customSelect(
      "SELECT COUNT(*) AS cnt FROM ams_change_events "
      "WHERE task_id = ? AND event_type = 'switch'",
      variables: [Variable(taskId)],
    ).get();
    if (rows.isEmpty) return 0;
    return rows.first.read<int?>('cnt') ?? 0;
  }

  /// 释放资源（数据库关闭时调用）。
  void dispose() {
    _changeController.close();
  }

  /// 把 SQLite 行映射为 [AmsChangeEvent] 对象。
  AmsChangeEvent _rowToEvent(QueryRow row) {
    final occurredMs = row.read<int>('occurred_at');
    return AmsChangeEvent(
      id: row.read<int?>('id'),
      printerId: row.read<int?>('printer_id'),
      taskId: row.read<int?>('task_id'),
      channelIndex: row.read<int>('channel_index'),
      toolIndex: row.read<int>('tool_index'),
      consumableId: row.read<int?>('consumable_id'),
      eventType: AmsChangeEventType.fromCode(row.read<String>('event_type')),
      previousRemainingGrams: row.read<double?>('previous_remaining_grams'),
      consumedGramsAtEvent: row.read<double?>('consumed_grams_at_event') ?? 0,
      occurredAt: DateTime.fromMillisecondsSinceEpoch(occurredMs),
      note: row.read<String?>('note'),
      colorHex: row.read<String?>('color_hex'),
    );
  }
}
