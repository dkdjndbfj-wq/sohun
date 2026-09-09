// 调度任务 DAO（raw SQL，不走 drift 代码生成）。
//
// 管理 scheduler_tasks 表的 CRUD + 状态推进 + 排序。
// scheduler_tasks 表是 v15 用 raw SQL 创建的，不在 drift 代码生成范围内，
// 所以全部用 customStatement / customSelect / customInsert / customUpdate + 参数绑定操作。
//
// watchAll 通过内部 StreamController 广播刷新信号，与 PrintTaskDao 模式一致。

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database.dart';
import '../models/scheduler_models.dart';

export '../models/scheduler_models.dart'
    show
        SchedulerTask,
        SchedulerTaskStatus,
        PrinterModelGroup,
        PrinterCandidate;

/// 调度任务数据访问层。所有 CRUD 通过 raw SQL 实现。
///
/// 因 scheduler_tasks 表不走 drift 代码生成（与 print_tasks / print_queue 一致），
/// 本 DAO 直接用 [customStatement] / [customSelect] / [customInsert] / [customUpdate]
/// 执行 SQL，并通过内部 [StreamController] 在数据变更后手动推送刷新事件，
/// 让 UI 层的 [StreamProvider] 能正确响应。
///
/// 数据库关闭时调用 [dispose] 释放 StreamController。
class SchedulerDao extends DatabaseAccessor<AppDatabase> {
  SchedulerDao(super.db);

  // 全局变更广播。任何 CRUD 后调用 _emit()，所有 watch 流都会收到最新结果。
  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  /// 监听数据库变更事件（无 payload，仅作"重新查询"信号）。
  Stream<void> get onChange => _changeController.stream;

  void _emit() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  /// 监听所有调度任务（UI 列表用）。
  ///
  /// 先发射当前快照，再在数据库变更后重新查询并推送结果。
  /// try-catch 包裹 await for 防止单次查询异常终止整个流：
  /// - 内层 try-catch 捕获查询异常，debugPrint 后 continue（流不终止）
  /// - 外层 try-catch 兜底捕获流本身异常（如 controller close），优雅关闭
  Stream<List<SchedulerTask>> watchAll() async* {
    yield await _fetchAll();
    try {
      await for (final _ in _changeController.stream) {
        try {
          yield await _fetchAll();
        } catch (e) {
          debugPrint('[SchedulerDao] watchAll 查询失败: $e');
          continue;
        }
      }
    } catch (e) {
      debugPrint('[SchedulerDao] watchAll 流异常: $e');
    }
  }

  /// 取全部调度任务（状态闭环重新对账用）。
  Future<List<SchedulerTask>> getAll() => _fetchAll();

  /// 取所有 pending 任务按 sortOrder 升序（调度器消费队列用）。
  Future<List<SchedulerTask>> getPendingTasks() async {
    final rows = await customSelect(
      'SELECT t.*, COALESCE(p.name, p.serial) AS assigned_printer_name '
      'FROM scheduler_tasks t '
      'LEFT JOIN printers p ON t.assigned_printer_id = p.id '
      "WHERE t.status = 'pending' "
      'ORDER BY t.sort_order ASC, t.created_at ASC',
    ).get();
    return rows.map(rowToTask).toList();
  }

  /// 按 id 查询单条任务。
  Future<SchedulerTask?> getById(int id) async {
    final rows = await customSelect(
      'SELECT t.*, COALESCE(p.name, p.serial) AS assigned_printer_name '
      'FROM scheduler_tasks t '
      'LEFT JOIN printers p ON t.assigned_printer_id = p.id '
      'WHERE t.id = ?',
      variables: [Variable(id)],
    ).get();
    if (rows.isEmpty) return null;
    return rowToTask(rows.first);
  }

  /// 检查打印机是否已被占用（有 assigned 状态的任务）。
  /// 调度器在 _findCandidates 中用于过滤已分配任务的打印机，避免一台打印机
  /// 被反复分配多个任务。
  Future<bool> isPrinterOccupied(int printerId) async {
    final rows = await customSelect(
      "SELECT COUNT(*) AS cnt FROM scheduler_tasks "
      "WHERE assigned_printer_id = ? AND status = 'assigned'",
      variables: [Variable<int>(printerId)],
    ).get();
    return rows.first.read<int>('cnt') > 0;
  }

  /// 已分配/打印中任务的剩余排队时长近似值，用于忙机预分派评分。
  Future<int> getQueuedEstimatedSeconds(int printerId) async {
    final row = await customSelect(
      "SELECT COALESCE(SUM(estimated_seconds), 0) AS seconds "
      "FROM scheduler_tasks WHERE assigned_printer_id = ? "
      "AND status IN ('assigned', 'printing')",
      variables: [Variable<int>(printerId)],
    ).getSingle();
    return row.read<int>('seconds');
  }

  /// 查询打印机历史成功率（用于调度器评分替换硬编码 0.8）。
  ///
  /// 统计该打印机所有已结束任务（finished/failed/cancelled）中
  /// finished 占比。返回 [0.0, 1.0]。
  ///
  /// - 无任何终态任务：返回 null（调用方用 0.5 中性默认值，避免新打印机被惩罚）
  /// - 有终态任务：finished / (finished + failed + cancelled)
  ///
  /// 可选 [recentDays] 限制统计窗口（默认 90 天），近期表现更反映当前状态。
  Future<double?> getPrinterHistoryRate(
    int printerId, {
    int recentDays = 90,
  }) async {
    final cutoff = DateTime.now()
        .subtract(Duration(days: recentDays))
        .millisecondsSinceEpoch;
    final rows = await customSelect(
      "SELECT "
      "SUM(CASE WHEN status = 'finished' THEN 1 ELSE 0 END) AS success, "
      "SUM(CASE WHEN status IN ('failed', 'cancelled') THEN 1 ELSE 0 END) AS fail "
      "FROM print_tasks "
      "WHERE printer_id = ? AND finished_at IS NOT NULL AND finished_at >= ?",
      variables: [Variable<int>(printerId), Variable<int>(cutoff)],
    ).get();
    if (rows.isEmpty) return null;
    final success = rows.first.read<int?>('success') ?? 0;
    final fail = rows.first.read<int?>('fail') ?? 0;
    final total = success + fail;
    if (total == 0) return null;
    return success / total;
  }

  /// 查询打印机在最近一次同批次任务中的参与记录（批次亲和性评分用）。
  ///
  /// 若该打印机在 [batchId] 批次中已有任务（说明用户已选择此打印机参与此批次），
  /// 返回 true，调度器优先把同批次后续任务分配给该打印机，减少用户手动协调。
  Future<bool> isPrinterInBatch(int printerId, String? batchId) async {
    if (batchId == null || batchId.isEmpty) return false;
    final rows = await customSelect(
      "SELECT COUNT(*) AS cnt FROM print_tasks "
      "WHERE printer_id = ? AND batch_id = ?",
      variables: [Variable<int>(printerId), Variable<String>(batchId)],
    ).get();
    return rows.first.read<int>('cnt') > 0;
  }

  /// 取消任务：显式清空 assigned_printer_id 并写入 completed_at。
  ///
  /// 与 [updateStatus] 不同，本方法会显式 SET assigned_printer_id = NULL。
  /// updateStatus 的 `if (assignedPrinterId != null)` 守卫导致该字段无法置 NULL，
  /// 取消任务时会残留旧的打印机 id，UI 仍会显示"已分配到 XX"。
  Future<void> cancelTask(int id) async {
    await customUpdate(
      'UPDATE scheduler_tasks '
      "SET status = ?, assigned_printer_id = NULL, completed_at = ? "
      'WHERE id = ?',
      variables: [
        Variable<String>(SchedulerTaskStatus.cancelled.name),
        Variable<int>(DateTime.now().millisecondsSinceEpoch),
        Variable<int>(id),
      ],
      updates: {},
    );
    _emit();
  }

  /// 插入新任务，返回新插入的 id。
  /// sort_order 默认取当前最大值 + 1，追加到队尾。
  Future<int> insertTask(SchedulerTask task) async {
    final maxRow = await customSelect(
      'SELECT MAX(sort_order) AS max_sort FROM scheduler_tasks',
    ).getSingle();
    final maxSort = (maxRow.data['max_sort'] as int?) ?? 0;
    final sortOrder = task.sortOrder > 0 ? task.sortOrder : maxSort + 1;
    final id = await customInsert(
      '''
      INSERT INTO scheduler_tasks (
        gcode_path, gcode_filename, model_group, required_material,
        required_color_hex, estimated_grams, estimated_seconds, status,
        assigned_printer_id, sort_order, created_at, assigned_at,
        completed_at, note, target_model, target_nozzle_diameter
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable(task.gcodePath),
        Variable(task.gcodeFilename),
        Variable(task.modelGroup.name),
        Variable(task.requiredMaterial),
        Variable(task.requiredColorHex),
        Variable(task.estimatedGrams),
        Variable(task.estimatedSeconds),
        Variable(task.status.name),
        Variable(task.assignedPrinterId),
        Variable(sortOrder),
        Variable(task.createdAt.millisecondsSinceEpoch),
        Variable(task.assignedAt?.millisecondsSinceEpoch),
        Variable(task.completedAt?.millisecondsSinceEpoch),
        Variable(task.note),
        Variable(task.targetModel),
        Variable(task.targetNozzleDiameter),
      ],
    );
    _emit();
    return id;
  }

  /// 更新任务状态。
  ///
  /// 可选参数按需更新对应字段：
  /// - [assignedPrinterId] / [assignedAt]：分配到打印机时填
  /// - [completedAt]：任务完成时填
  Future<void> updateStatus(
    int id,
    SchedulerTaskStatus status, {
    int? assignedPrinterId,
    DateTime? assignedAt,
    DateTime? completedAt,
  }) async {
    final setParts = <String>['status = ?'];
    final args = <Variable>[Variable(status.name)];
    if (assignedPrinterId != null) {
      setParts.add('assigned_printer_id = ?');
      args.add(Variable(assignedPrinterId));
    }
    if (assignedAt != null) {
      setParts.add('assigned_at = ?');
      args.add(Variable(assignedAt.millisecondsSinceEpoch));
    }
    if (completedAt != null) {
      setParts.add('completed_at = ?');
      args.add(Variable(completedAt.millisecondsSinceEpoch));
    }
    args.add(Variable(id));
    await customUpdate(
      'UPDATE scheduler_tasks SET ${setParts.join(', ')} WHERE id = ?',
      variables: args,
      updates: {},
    );
    _emit();
  }

  /// 批量更新排序（拖拽调整顺序用）。
  /// [taskIds] 按新顺序排列，sort_order 从 1 开始递增。
  /// 修复：循环 UPDATE 用事务包裹，中途失败整体回滚，避免排序部分更新导致顺序混乱。
  Future<void> updateSortOrder(List<int> taskIds) async {
    await transaction(() async {
      for (var i = 0; i < taskIds.length; i++) {
        await customUpdate(
          'UPDATE scheduler_tasks SET sort_order = ? WHERE id = ?',
          variables: [Variable(i + 1), Variable(taskIds[i])],
          updates: {},
        );
      }
    });
    _emit();
  }

  /// 删除任务。
  Future<void> deleteTask(int id) async {
    await customUpdate(
      'DELETE FROM scheduler_tasks WHERE id = ?',
      variables: [Variable(id)],
      updates: {},
    );
    _emit();
  }

  /// 行转模型。
  SchedulerTask rowToTask(QueryRow row) {
    final createdAtMs = row.read<int>('created_at');
    final assignedAtMs = row.read<int?>('assigned_at');
    final completedAtMs = row.read<int?>('completed_at');
    final groupCode = row.read<String>('model_group');
    // LEFT JOIN printers 带出的打印机名称（COALESCE(name, serial)）。
    // pending 任务该字段为 NULL，assigned 任务带出打印机名称供 UI 显示。
    final printerName = row.read<String?>('assigned_printer_name');

    // v21 列：target_model / target_nozzle_diameter
    // 旧库迁移前可能无此列，try-catch 容错
    String? targetModel;
    double? targetNozzleDiameter;
    try {
      targetModel = row.read<String?>('target_model');
      targetNozzleDiameter = row.read<double?>('target_nozzle_diameter');
    } catch (_) {
      // 旧库无此列（理论上 v21 迁移已加列，此处兜底防御）
    }

    return SchedulerTask(
      id: row.read<int?>('id'),
      gcodePath: row.read<String>('gcode_path'),
      gcodeFilename: row.read<String>('gcode_filename'),
      modelGroup: _parseGroup(groupCode),
      requiredMaterial: row.read<String>('required_material'),
      requiredColorHex: row.read<String?>('required_color_hex'),
      estimatedGrams: row.read<double>('estimated_grams'),
      estimatedSeconds: row.read<int?>('estimated_seconds'),
      status: SchedulerTaskStatus.fromCode(row.read<String>('status')),
      assignedPrinterId: row.read<int?>('assigned_printer_id'),
      sortOrder: row.read<int>('sort_order'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
      assignedAt: assignedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(assignedAtMs),
      completedAt: completedAtMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(completedAtMs),
      note: row.read<String?>('note'),
      assignedPrinterName: printerName,
      targetModel: targetModel,
      targetNozzleDiameter: targetNozzleDiameter,
    );
  }

  /// 解析机型组（容错：未知值回退到 a1 组，避免解析异常崩 UI）。
  PrinterModelGroup _parseGroup(String code) {
    for (final g in PrinterModelGroup.values) {
      if (g.name == code) return g;
    }
    return PrinterModelGroup.a1;
  }

  /// 释放资源（数据库关闭时调用）。
  void dispose() {
    _changeController.close();
  }

  Future<List<SchedulerTask>> _fetchAll() async {
    final rows = await customSelect(
      'SELECT t.*, COALESCE(p.name, p.serial) AS assigned_printer_name '
      'FROM scheduler_tasks t '
      'LEFT JOIN printers p ON t.assigned_printer_id = p.id '
      'ORDER BY t.sort_order ASC, t.created_at DESC',
    ).get();
    return rows.map(rowToTask).toList();
  }
}
