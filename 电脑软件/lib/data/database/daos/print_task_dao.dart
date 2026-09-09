import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database.dart';
import '../models/print_task.dart';

export '../models/print_task.dart' show PrintTask, PrintTaskStatus;

/// 打印任务数据访问层。所有 CRUD 通过 raw SQL 实现。
///
/// 因 drift_dev 2.34 / sqlparser 0.44 不兼容，PrintTasks 表
/// 不走 drift 代码生成。本 DAO 直接用 [customStatement] / [customSelect]
/// 执行 SQL，并通过内部 [StreamController] 在数据变更后手动推送刷新事件，
/// 让 UI 层的 [StreamProvider] 能正确响应。
///
/// 数据库关闭时调用 [dispose] 释放 StreamController。
class PrintTaskDao extends DatabaseAccessor<AppDatabase> {
  PrintTaskDao(super.db);

  // 全局变更广播。任何 CRUD 后调用 _emit()，所有 watch 流都会收到最新结果。
  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  /// 监听数据库变更事件（无 payload，仅作"重新查询"信号）。
  Stream<void> get onChange => _changeController.stream;

  void _emit() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  /// 创建新任务。返回新插入的 id。
  Future<int> create(PrintTask task) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final startedMs = task.startedAt?.millisecondsSinceEpoch;
    final finishedMs = task.finishedAt?.millisecondsSinceEpoch;
    final id = await customInsert(
      '''
      INSERT INTO print_tasks (
        uid, printer_id, consumable_id, gcode_path, task_name,
        estimated_grams, estimated_seconds, actual_grams,
        started_at, finished_at, last_mc_percent, last_layer,
        status, source, per_filament_grams, note, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      variables: [
        Variable(task.uid),
        Variable(task.printerId),
        Variable(task.consumableId),
        Variable(task.gcodePath),
        Variable(task.taskName),
        Variable(task.estimatedGrams),
        Variable(task.estimatedSeconds),
        Variable(task.actualGrams),
        Variable(startedMs),
        Variable(finishedMs),
        Variable(task.lastMcPercent),
        Variable(task.lastLayer),
        Variable(task.status.code),
        Variable(task.source),
        Variable(
          task.perFilamentGrams.isEmpty
              ? null
              : jsonEncode(task.perFilamentGrams),
        ),
        Variable(task.note),
        Variable(task.createdAt.millisecondsSinceEpoch),
        Variable(now),
      ],
    );
    _emit();
    return id;
  }

  /// 按 id 查询单条任务。
  Future<PrintTask?> getById(int id) async {
    final rows = await customSelect(
      'SELECT * FROM print_tasks WHERE id = ?',
      variables: [Variable(id)],
    ).get();
    if (rows.isEmpty) return null;
    return _rowToTask(rows.first);
  }

  /// 查询所有任务，按创建时间倒序。
  Future<List<PrintTask>> getAll() async {
    final rows = await customSelect(
      'SELECT * FROM print_tasks ORDER BY created_at DESC',
    ).get();
    return rows.map(_rowToTask).toList();
  }

  /// 查询活跃任务（非终态）。同时只应有一个，但保留 list 灵活性。
  Future<List<PrintTask>> getActive() async {
    // 状态码从枚举派生：!isTerminal 的状态都算活跃。
    final activeCodes = PrintTaskStatus.values
        .where((s) => s.isActive)
        .map((s) => "'${s.code}'")
        .join(', ');
    final rows = await customSelect(
      'SELECT * FROM print_tasks WHERE status IN ($activeCodes) '
      'ORDER BY created_at DESC',
    ).get();
    return rows.map(_rowToTask).toList();
  }

  /// Terminal tasks with uncommitted material accounting survive app crashes
  /// and can be safely retried using the per-entry consumed_at claim.
  Future<List<PrintTask>> getPendingSettlements() async {
    final rows = await customSelect('''
      SELECT task.* FROM print_tasks task
      WHERE task.status IN ('finished', 'cancelled', 'failed')
        AND EXISTS (
          SELECT 1 FROM print_task_consumables entry
          WHERE entry.task_id = task.id AND entry.consumed_at IS NULL
        )
      ORDER BY task.finished_at ASC, task.id ASC
    ''').get();
    return rows.map(_rowToTask).toList();
  }

  /// 查询指定打印机的活跃任务（非终态）。
  ///
  /// 多打印机隔离用：编排器按当前活跃打印机的 printer_id 取本机任务，
  /// 避免把 A 机的 MQTT 状态喂给 B 机任务导致误取消/重复扣减。
  Future<List<PrintTask>> getActiveByPrinter(int printerId) async {
    final activeCodes = PrintTaskStatus.values
        .where((s) => s.isActive)
        .map((s) => "'${s.code}'")
        .join(', ');
    final rows = await customSelect(
      'SELECT * FROM print_tasks WHERE printer_id = ? '
      'AND status IN ($activeCodes) ORDER BY created_at DESC',
      variables: [Variable(printerId)],
    ).get();
    return rows.map(_rowToTask).toList();
  }

  /// 监听全部任务流（UI 列表用）。
  /// 先发射当前快照，再在数据库变更后重新查询并推送结果。
  ///
  /// try-catch 包裹 await for 防止单次查询异常终止整个流：
  /// - 内层 try-catch 捕获查询异常，debugPrint 后 continue（流不终止）
  /// - 外层 try-catch 兜底捕获流本身异常（如 controller close），优雅关闭
  Stream<List<PrintTask>> watchAll() async* {
    yield await getAll();
    try {
      await for (final _ in _changeController.stream) {
        try {
          yield await getAll();
        } catch (e) {
          debugPrint('[PrintTaskDao] watchAll 查询失败: $e');
          continue;
        }
      }
    } catch (e) {
      debugPrint('[PrintTaskDao] watchAll 流异常: $e');
    }
  }

  /// 监听活跃任务流（仪表板实时卡片用）。
  /// 先发射当前快照，再在数据库变更后重新查询并推送结果。
  ///
  /// try-catch 包裹 await for 防止单次查询异常终止整个流：
  /// - 内层 try-catch 捕获查询异常，debugPrint 后 continue（流不终止）
  /// - 外层 try-catch 兜底捕获流本身异常（如 controller close），优雅关闭
  Stream<List<PrintTask>> watchActive() async* {
    yield await getActive();
    try {
      await for (final _ in _changeController.stream) {
        try {
          yield await getActive();
        } catch (e) {
          debugPrint('[PrintTaskDao] watchActive 查询失败: $e');
          continue;
        }
      }
    } catch (e) {
      debugPrint('[PrintTaskDao] watchActive 流异常: $e');
    }
  }

  /// 监听单条任务（任务详情页用）。
  /// 先发射当前快照，再在数据库变更后重新查询并推送结果。
  ///
  /// try-catch 包裹 await for 防止单次查询异常终止整个流：
  /// - 内层 try-catch 捕获查询异常，debugPrint 后 continue（流不终止）
  /// - 外层 try-catch 兜底捕获流本身异常（如 controller close），优雅关闭
  Stream<PrintTask?> watchById(int id) async* {
    yield await getById(id);
    try {
      await for (final _ in _changeController.stream) {
        try {
          yield await getById(id);
        } catch (e) {
          debugPrint('[PrintTaskDao] watchById($id) 查询失败: $e');
          continue;
        }
      }
    } catch (e) {
      debugPrint('[PrintTaskDao] watchById($id) 流异常: $e');
    }
  }

  /// 更新任务进度快照（实时刷新用）。
  /// 注意：进度更新非常频繁，不触发 _emit（避免 UI 抖动），由 UI 侧轮询或自行刷新。
  Future<int> updateProgress({
    required int id,
    required int mcPercent,
    required int layer,
    required double actualGrams,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return customUpdate(
      '''
      UPDATE print_tasks
      SET last_mc_percent = ?, last_layer = ?, actual_grams = ?, updated_at = ?
      WHERE id = ? AND status IN ('planned', 'printing', 'paused')
      ''',
      variables: [
        Variable(mcPercent),
        Variable(layer),
        Variable(actualGrams),
        Variable(now),
        Variable(id),
      ],
    );
  }

  /// 更新任务状态。
  /// 若新状态为 printing 且任务还没 startedAt，自动补上当前时间。
  /// 若新状态为终态（finished/cancelled/failed），自动补 finishedAt。
  Future<int> updateStatus({
    required int id,
    required PrintTaskStatus status,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    final current = await getById(id);
    final needStart =
        status == PrintTaskStatus.printing && current?.startedAt == null;
    final needFinish = status.isTerminal;

    final setClauses = <String>[];
    final vars = <Variable>[];
    if (needStart) {
      setClauses.add('started_at = ?');
      vars.add(Variable(now));
    }
    if (needFinish) {
      setClauses.add('finished_at = ?');
      vars.add(Variable(now));
    }
    setClauses.add('status = ?');
    vars.add(Variable(status.code));
    setClauses.add('updated_at = ?');
    vars.add(Variable(now));
    vars.add(Variable(id));

    final result = await customUpdate(
      "UPDATE print_tasks SET ${setClauses.join(', ')} "
      "WHERE id = ? AND status IN ('planned', 'printing', 'paused')",
      variables: vars,
    );
    _emit();
    return result;
  }

  /// 任务完成时一次性写入最终实际克数 + 状态。
  Future<int> finish({
    required int id,
    required double actualGrams,
    PrintTaskStatus status = PrintTaskStatus.finished,
    int? lastMcPercent,
    int? lastLayer,
  }) async {
    if (!status.isTerminal) {
      throw ArgumentError.value(status, 'status', '必须是打印任务终态');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final progressClauses = <String>[];
    final variables = <Variable>[
      Variable(actualGrams),
      Variable(status.code),
      Variable(now),
      Variable(now),
    ];
    if (lastMcPercent != null) {
      progressClauses.add('last_mc_percent = ?');
      variables.add(Variable(lastMcPercent));
    }
    if (lastLayer != null) {
      progressClauses.add('last_layer = ?');
      variables.add(Variable(lastLayer));
    }
    variables.add(Variable(id));
    final result = await customUpdate('''
      UPDATE print_tasks
      SET actual_grams = ?, status = ?, finished_at = ?, updated_at = ?
          ${progressClauses.isEmpty ? '' : ', ${progressClauses.join(', ')}'}
      WHERE id = ? AND status IN ('planned', 'printing', 'paused')
      ''', variables: variables);
    _emit();
    return result;
  }

  /// 更新备注
  Future<int> updateNote(int id, String? note) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final result = await customUpdate(
      'UPDATE print_tasks SET note = ?, updated_at = ? WHERE id = ?',
      variables: [Variable(note), Variable(now), Variable(id)],
    );
    _emit();
    return result;
  }

  /// 删除任务
  /// 注意：方法名故意叫 deleteTask 而非 delete，避免和 drift 内置的
  /// `delete(TableInfo)` 方法签名冲突（drift 2.34 DatabaseConnectionUser.delete 返回 DeleteStatement）。
  Future<int> deleteTask(int id) async {
    final result = await customUpdate(
      'DELETE FROM print_tasks WHERE id = ?',
      variables: [Variable(id)],
    );
    _emit();
    return result;
  }

  /// 按时间范围查询任务（started_at 在 [start, end] 之间）。
  /// started_at 为 NULL 的任务（planned 未启动）不计入。
  Future<List<PrintTask>> getByTimeRange({
    required DateTime start,
    required DateTime end,
  }) async {
    final rows = await customSelect(
      'SELECT * FROM print_tasks '
      'WHERE started_at IS NOT NULL '
      'AND started_at >= ? AND started_at <= ? '
      'ORDER BY COALESCE(started_at, created_at) DESC',
      variables: [
        Variable(start.millisecondsSinceEpoch),
        Variable(end.millisecondsSinceEpoch),
      ],
    ).get();
    return rows.map(_rowToTask).toList();
  }

  /// 按状态查询。
  Future<List<PrintTask>> getByStatus(PrintTaskStatus status) async {
    final rows = await customSelect(
      'SELECT * FROM print_tasks WHERE status = ? '
      'ORDER BY COALESCE(started_at, created_at) DESC',
      variables: [Variable(status.code)],
    ).get();
    return rows.map(_rowToTask).toList();
  }

  /// 按打印机查询。
  Future<List<PrintTask>> getByPrinter(int printerId) async {
    final rows = await customSelect(
      'SELECT * FROM print_tasks WHERE printer_id = ? '
      'ORDER BY COALESCE(started_at, created_at) DESC',
      variables: [Variable(printerId)],
    ).get();
    return rows.map(_rowToTask).toList();
  }

  /// 按模型名模糊查询（task_name LIKE '%name%'）。
  Future<List<PrintTask>> getByModelName(String name) async {
    final rows = await customSelect(
      'SELECT * FROM print_tasks WHERE task_name LIKE ? '
      'ORDER BY COALESCE(started_at, created_at) DESC',
      variables: [Variable('%$name%')],
    ).get();
    return rows.map(_rowToTask).toList();
  }

  /// 组合过滤查询（打印历史页用）。任一参数为 null 表示不限制。
  /// 按 COALESCE(started_at, created_at) 倒序返回。
  Future<List<PrintTask>> getFiltered({
    DateTime? start,
    DateTime? end,
    PrintTaskStatus? status,
    int? printerId,
    String? modelName,
  }) async {
    final where = <String>['1=1'];
    final vars = <Variable>[];
    if (start != null) {
      where.add('started_at IS NOT NULL AND started_at >= ?');
      vars.add(Variable(start.millisecondsSinceEpoch));
    }
    if (end != null) {
      where.add('started_at <= ?');
      vars.add(Variable(end.millisecondsSinceEpoch));
    }
    if (status != null) {
      where.add('status = ?');
      vars.add(Variable(status.code));
    }
    if (printerId != null) {
      where.add('printer_id = ?');
      vars.add(Variable(printerId));
    }
    if (modelName != null && modelName.isNotEmpty) {
      where.add('task_name LIKE ?');
      vars.add(Variable('%$modelName%'));
    }
    final rows = await customSelect(
      'SELECT * FROM print_tasks WHERE ${where.join(' AND ')} '
      'ORDER BY COALESCE(started_at, created_at) DESC',
      variables: vars,
    ).get();
    return rows.map(_rowToTask).toList();
  }

  /// 按状态聚合统计：返回 {status: count} 映射。
  /// 可选时间范围（按 started_at 筛选）。
  Future<Map<PrintTaskStatus, int>> countByStatus({
    DateTime? start,
    DateTime? end,
  }) async {
    final where = <String>['1=1'];
    final vars = <Variable>[];
    if (start != null) {
      where.add('started_at IS NOT NULL AND started_at >= ?');
      vars.add(Variable(start.millisecondsSinceEpoch));
    }
    if (end != null) {
      where.add('started_at <= ?');
      vars.add(Variable(end.millisecondsSinceEpoch));
    }
    final rows = await customSelect(
      'SELECT status, COUNT(*) AS cnt FROM print_tasks '
      'WHERE ${where.join(' AND ')} GROUP BY status',
      variables: vars,
    ).get();
    final result = <PrintTaskStatus, int>{};
    for (final row in rows) {
      final code = row.read<String>('status');
      final cnt = row.read<int>('cnt');
      result[PrintTaskStatus.fromCode(code)] = cnt;
    }
    return result;
  }

  /// 按天聚合克数与任务数（折线图用）。
  /// 返回 [DailyStat] 列表，按日期升序。
  /// 仅统计 started_at 非空的任务，按本地时区分天。
  Future<List<DailyStat>> sumGramsByDay({
    required DateTime start,
    required DateTime end,
  }) async {
    final rows = await customSelect(
      '''
      SELECT DATE(started_at/1000, 'unixepoch', 'localtime') AS day,
             SUM(actual_grams) AS grams,
             COUNT(*) AS cnt
      FROM print_tasks
      WHERE started_at IS NOT NULL
        AND started_at >= ? AND started_at <= ?
      GROUP BY day
      ORDER BY day
      ''',
      variables: [
        Variable(start.millisecondsSinceEpoch),
        Variable(end.millisecondsSinceEpoch),
      ],
    ).get();
    final result = <DailyStat>[];
    for (final row in rows) {
      final dayStr = row.read<String?>('day');
      if (dayStr == null) continue;
      final parts = dayStr.split('-');
      if (parts.length != 3) continue;
      final date = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
      result.add(
        DailyStat(
          date: date,
          totalGrams: row.read<double?>('grams') ?? 0.0,
          taskCount: row.read<int?>('cnt') ?? 0,
        ),
      );
    }
    return result;
  }

  /// 释放资源（数据库关闭时调用）。
  void dispose() {
    _changeController.close();
  }

  /// 把 SQLite 行映射为 [PrintTask] 对象。
  PrintTask _rowToTask(QueryRow row) {
    final perFilamentRaw = row.read<String?>('per_filament_grams');
    List<double> perFilament = const [];
    if (perFilamentRaw != null && perFilamentRaw.isNotEmpty) {
      try {
        final list = jsonDecode(perFilamentRaw) as List<dynamic>;
        perFilament = list.map((e) => (e as num).toDouble()).toList();
      } catch (e) {
        // P0 修复：避免每卷耗材消耗数据静默丢失，至少记录日志便于排查
        debugPrint(
          '[PrintTaskDao] 解析 per_filament_grams 失败: $e\n原始值: $perFilamentRaw',
        );
      }
    }

    final startedMs = row.read<int?>('started_at');
    final finishedMs = row.read<int?>('finished_at');
    final createdMs = row.read<int>('created_at');
    final updatedMs = row.read<int>('updated_at');

    return PrintTask(
      id: row.read<int?>('id'),
      uid: row.read<String>('uid'),
      printerId: row.read<int?>('printer_id'),
      consumableId: row.read<int?>('consumable_id'),
      gcodePath: row.read<String>('gcode_path'),
      taskName: row.read<String>('task_name'),
      estimatedGrams: row.read<double>('estimated_grams'),
      estimatedSeconds: row.read<int>('estimated_seconds'),
      actualGrams: row.read<double>('actual_grams'),
      startedAt: startedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(startedMs),
      finishedAt: finishedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(finishedMs),
      lastMcPercent: row.read<int>('last_mc_percent'),
      lastLayer: row.read<int>('last_layer'),
      status: PrintTaskStatus.fromCode(row.read<String>('status')),
      source: row.read<String>('source'),
      perFilamentGrams: perFilament,
      note: row.read<String?>('note'),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdMs),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedMs),
    );
  }
}

/// 按天聚合的统计点（折线图用）。
class DailyStat {
  final DateTime date;
  final double totalGrams;
  final int taskCount;

  const DailyStat({
    required this.date,
    required this.totalGrams,
    required this.taskCount,
  });
}
