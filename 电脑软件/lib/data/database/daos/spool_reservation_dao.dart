// 耗材卷预留 DAO（raw SQL，不走 drift 代码生成）。
//
// 管理 spool_reservations 表的 CRUD：
// - 排队任务先预留耗材；两个任务不能同时把同一卷剩余量各算一遍。
// - 表结构在 v19 已创建（database.dart _createSpoolReservationsTable）。
// - 状态机：active → released（任务完成）/ cancelled（任务取消/失败）
//
// 关键约束：getAvailableGrams 必须扣除所有 active 预留，
// 调度器在评分阶段调用此方法得到真实可用余量。

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../models/scheduler_models.dart';

/// 耗材卷预留 DAO。
///
/// 全部用 [customStatement] / [customSelect] / [customInsert] / [customUpdate]
/// 执行 raw SQL，与 [SchedulerDao] / [SchedulerMaterialDao] 模式一致。
class SpoolReservationDao extends DatabaseAccessor<AppDatabase> {
  SpoolReservationDao(super.db);

  final Uuid _uuid = const Uuid();

  /// 创建预留。返回新插入的预留 id（UUID）。
  ///
  /// 调用方应在事务内调用此方法（与任务分配 + 队列入队一起原子化）。
  /// 若该卷已有 active 预留导致余量不足，由调用方在事务前用
  /// [getAvailableGrams] 校验，避免事务内回滚。
  Future<String> reserve({
    required int schedulerTaskId,
    required int consumableId,
    required int toolIndex,
    required double grams,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    await customInsert(
      '''
      INSERT INTO spool_reservations (
        id, scheduler_task_id, consumable_id, tool_index,
        reserved_grams, reserved_at, status
      ) VALUES (?, ?, ?, ?, ?, ?, 'active')
      ''',
      variables: [
        Variable<String>(id),
        Variable<int>(schedulerTaskId),
        Variable<int>(consumableId),
        Variable<int>(toolIndex),
        Variable<double>(grams),
        Variable<int>(now),
      ],
    );
    return id;
  }

  /// 释放指定调度任务的所有 active 预留（标记为 released）。
  ///
  /// 调用时机：
  /// - 任务完成：调度器推进到 completed 时调用
  /// - 任务取消：调度器推进到 cancelled 时调用
  /// - 任务失败：调度器推进到 failed 时调用
  /// - 调度回滚：原子事务失败时调用，释放本次分配的预留
  Future<int> releaseForTask(int schedulerTaskId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final affected = await customUpdate(
      "UPDATE spool_reservations "
      "SET status = 'released', released_at = ? "
      "WHERE scheduler_task_id = ? AND status = 'active'",
      variables: [Variable<int>(now), Variable<int>(schedulerTaskId)],
      updates: {},
    );
    return affected;
  }

  /// 取消指定调度任务的所有 active 预留（标记为 cancelled）。
  ///
  /// 与 [releaseForTask] 语义区别：
  /// - released：任务正常结束（完成/失败），预留转为实际消耗
  /// - cancelled：任务被取消/回滚，预留直接作废
  Future<int> cancelForTask(int schedulerTaskId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final affected = await customUpdate(
      "UPDATE spool_reservations "
      "SET status = 'cancelled', released_at = ? "
      "WHERE scheduler_task_id = ? AND status = 'active'",
      variables: [Variable<int>(now), Variable<int>(schedulerTaskId)],
      updates: {},
    );
    return affected;
  }

  /// 查询指定耗材卷的所有 active 预留（按预留时间升序）。
  Future<List<SpoolReservation>> getActiveReservationsForConsumable(
    int consumableId,
  ) async {
    final rows = await customSelect(
      "SELECT * FROM spool_reservations "
      "WHERE consumable_id = ? AND status = 'active' "
      "ORDER BY reserved_at ASC",
      variables: [Variable<int>(consumableId)],
    ).get();
    return rows.map((r) => SpoolReservation.fromMap(r.data)).toList();
  }

  /// 查询指定调度任务的所有预留（含历史 released/cancelled，用于审计）。
  Future<List<SpoolReservation>> getReservationsForTask(
    int schedulerTaskId,
  ) async {
    final rows = await customSelect(
      'SELECT * FROM spool_reservations '
      'WHERE scheduler_task_id = ? ORDER BY reserved_at ASC',
      variables: [Variable<int>(schedulerTaskId)],
    ).get();
    return rows.map((r) => SpoolReservation.fromMap(r.data)).toList();
  }

  /// 查询指定调度任务的 active 预留数量（用于校验是否还有未释放的预留）。
  Future<int> countActiveReservationsForTask(int schedulerTaskId) async {
    final rows = await customSelect(
      "SELECT COUNT(*) AS cnt FROM spool_reservations "
      "WHERE scheduler_task_id = ? AND status = 'active'",
      variables: [Variable<int>(schedulerTaskId)],
    ).get();
    return rows.first.read<int>('cnt');
  }

  /// 计算指定耗材卷的可用余量 = 库存余量 - 所有 active 预留总和。
  ///
  /// 调度器在评分阶段调用此方法，确保两个排队任务不会同时把
  /// 同一卷剩余量各算一遍。
  ///
  /// 返回 (availableGrams, totalRemainingGrams, totalReservedGrams)：
  /// - availableGrams：扣除活动预留后的真实可用量
  /// - totalRemainingGrams：库存表中的 remaining_grams
  /// - totalReservedGrams：该卷所有 active 预留总和
  Future<
      ({
        double availableGrams,
        double totalRemainingGrams,
        double totalReservedGrams
      })> getAvailableGrams(int consumableId) async {
    // 查库存余量
    final consumableRows = await customSelect(
      'SELECT remaining_grams FROM consumables WHERE id = ?',
      variables: [Variable<int>(consumableId)],
    ).get();
    if (consumableRows.isEmpty) {
      return (
        availableGrams: 0.0,
        totalRemainingGrams: 0.0,
        totalReservedGrams: 0.0,
      );
    }
    final remaining =
        (consumableRows.first.data['remaining_grams'] as num?)?.toDouble() ??
            0.0;

    // 查活动预留总和
    final reserveRows = await customSelect(
      "SELECT COALESCE(SUM(reserved_grams), 0) AS total_reserved "
      "FROM spool_reservations "
      "WHERE consumable_id = ? AND status = 'active'",
      variables: [Variable<int>(consumableId)],
    ).get();
    final reserved =
        (reserveRows.first.data['total_reserved'] as num?)?.toDouble() ?? 0.0;

    final available = remaining - reserved;
    return (
      availableGrams: available < 0 ? 0.0 : available,
      totalRemainingGrams: remaining,
      totalReservedGrams: reserved,
    );
  }

  /// 校验：在指定耗材卷上新增 [grams] 预留是否会超额。
  ///
  /// 调用方在事务前调用此方法做前置校验，避免事务内回滚的开销。
  /// 返回 true 表示可以安全预留，false 表示余量不足。
  Future<bool> canReserve({
    required int consumableId,
    required double grams,
    required double safetyBuffer,
  }) async {
    final info = await getAvailableGrams(consumableId);
    return info.availableGrams >= grams + safetyBuffer;
  }

  /// 调试日志：打印指定任务的所有预留。
  void debugPrintReservations(int schedulerTaskId) async {
    try {
      final list = await getReservationsForTask(schedulerTaskId);
      for (final r in list) {
        debugPrint(
          '[SpoolReservation] task=$schedulerTaskId '
          'consumable=${r.consumableId} T${r.toolIndex} '
          '${r.reservedGrams}g status=${r.status.code}',
        );
      }
    } catch (_) {
      // 调试用，吞异常
    }
  }
}
