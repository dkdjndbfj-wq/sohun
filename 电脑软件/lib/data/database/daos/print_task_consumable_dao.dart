import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../database.dart';
import '../models/print_task_consumable.dart';

export '../models/print_task_consumable.dart' show PrintTaskConsumable;

/// 打印任务 ↔ 耗材卷 关联数据访问层。raw SQL 实现（不走 drift 代码生成）。
///
/// 配合 [PrintTaskOrchestrator] 的「实时扣减+完成修正」策略：
/// - 创建任务时：[createForTask] 按 SliceResult.filaments 建立多条关联
/// - 打印中：[updateDeducted] 更新实时扣减累计值（不写 consumedGrams）
/// - 完成时：[finalize] 写入最终 consumedGrams + 更新 lastDeductedGrams
class PrintTaskConsumableDao extends DatabaseAccessor<AppDatabase> {
  PrintTaskConsumableDao(super.db);

  void _emit() {
    attachedDatabase.notifyUpdates({
      const TableUpdate('print_task_consumables'),
    });
  }

  /// 变更广播流（供 StreamProvider 监听，实现汇总自动刷新）。
  Stream<void> get changeStream => attachedDatabase
      .tableUpdates(TableUpdateQuery.onTableName('print_task_consumables'))
      .map((_) {});

  /// 按任务创建关联记录（批量）。
  /// 通常在 [PrintTaskOrchestrator.createTask] 后调用一次。
  ///
  /// 返回带数据库 id 的记录列表（C1 修复：插入后重新查询，确保 id 不为 null，
  /// 后续 updateDeducted/finalize 才能正确按 id 更新）。
  /// 修复：循环 INSERT 用事务包裹，中途失败整体回滚，避免留下部分关联记录
  /// 导致任务结算时数据不一致。
  Future<List<PrintTaskConsumable>> createForTask(
    int taskId,
    List<PrintTaskConsumable> entries,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      for (final e in entries) {
        await customInsert(
          '''
          INSERT INTO print_task_consumables (
            task_id, printer_id, channel_index, consumable_id, tool_index,
            estimated_grams, consumed_grams, last_deducted_grams, segment_start_grams,
            cost_per_kg_snapshot, matched_cost_config_id,
            created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          variables: [
            Variable(taskId),
            Variable(e.printerId),
            Variable(e.channelIndex),
            Variable(e.consumableId),
            Variable(e.toolIndex),
            Variable(e.estimatedGrams),
            Variable(e.consumedGrams),
            Variable(e.lastDeductedGrams),
            Variable(e.segmentStartGrams),
            Variable(e.costPerKgSnapshot),
            Variable(e.matchedCostConfigId),
            Variable(now),
            Variable(now),
          ],
        );
      }
    });
    _emit();
    // C1 修复：插入后重新查询，返回带数据库 id 的记录给调用方更新缓存
    return getByTask(taskId);
  }

  /// 查询任务的所有关联记录。
  Future<List<PrintTaskConsumable>> getByTask(int taskId) async {
    final rows = await customSelect(
      'SELECT * FROM print_task_consumables WHERE task_id = ? '
      'ORDER BY tool_index ASC, id ASC',
      variables: [Variable(taskId)],
    ).get();
    return rows.map(_rowToEntry).toList();
  }

  /// 未结算任务对各库存耗材的剩余预计占用量。
  ///
  /// 实时扣减会同时降低库存余量和待占用量，因此二者相减后的可用量保持稳定。
  /// 外挂方案提交时用它避免多台打印机重复承诺同一份库存。
  Future<Map<int, double>> getOutstandingDemandByConsumable({
    int? excludingTaskId,
  }) async {
    final excludeSql = excludingTaskId == null ? '' : 'AND task_id <> ? ';
    final rows = await customSelect(
      'SELECT consumable_id, '
      'SUM(CASE WHEN estimated_grams > last_deducted_grams '
      'THEN estimated_grams - last_deducted_grams ELSE 0 END) AS demand '
      'FROM print_task_consumables '
      'WHERE consumed_at IS NULL AND consumable_id IS NOT NULL '
      '$excludeSql'
      'GROUP BY consumable_id',
      variables: [if (excludingTaskId != null) Variable<int>(excludingTaskId)],
    ).get();
    return {
      for (final row in rows)
        row.read<int>('consumable_id'): row.read<double>('demand'),
    };
  }

  /// Atomically maps each external color/tool to an inventory spool.
  ///
  /// Unsettled rows only: once a task has been finalized its historical
  /// consumption ledger must not be rewritten by a late dialog response.
  Future<int> updateExternalMappings(
    int taskId,
    List<
      ({int toolIndex, int consumableId, double? costPerKg, int? costConfigId})
    >
    mappings,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = 0;
    await transaction(() async {
      for (final mapping in mappings) {
        changed += await customUpdate(
          'UPDATE print_task_consumables SET consumable_id = ?, '
          'cost_per_kg_snapshot = ?, '
          'matched_cost_config_id = ?, updated_at = ? '
          'WHERE task_id = ? AND tool_index = ? AND consumed_at IS NULL '
          'AND last_deducted_grams = 0 AND segment_start_grams = 0',
          variables: [
            Variable(mapping.consumableId),
            Variable(mapping.costPerKg),
            Variable(mapping.costConfigId),
            Variable(now),
            Variable(taskId),
            Variable(mapping.toolIndex),
          ],
        );
      }
      if (changed != mappings.length) {
        throw StateError('任务耗材方案已过期，请刷新任务后重试');
      }
    });
    if (changed > 0) _emit();
    return changed;
  }

  /// 监听任务的所有关联记录（实时面板用）。
  /// 先发射当前数据，再监听变更流（避免初始 loading 卡死）。
  ///
  /// try-catch 包裹 await for 防止单次查询异常终止整个流：
  /// - 内层 try-catch 捕获查询异常，debugPrint 后 continue（流不终止）
  /// - 外层 try-catch 兜底捕获流本身异常（如 controller close），优雅关闭
  Stream<List<PrintTaskConsumable>> watchByTask(int taskId) async* {
    yield await getByTask(taskId);
    try {
      await for (final _ in changeStream) {
        try {
          yield await getByTask(taskId);
        } catch (e) {
          debugPrint('[PrintTaskConsumableDao] watchByTask($taskId) 查询失败: $e');
          continue;
        }
      }
    } catch (e) {
      debugPrint('[PrintTaskConsumableDao] watchByTask($taskId) 流异常: $e');
    }
  }

  /// 更新实时扣减累计值。上层已按 5 秒节流，更新后广播一次让实时面板
  /// 能区分“视觉估算”与“库存已同步”数值。
  /// M1 修复：不更新 consumed_at（实时扣减非最终消耗时刻），只更新 updated_at +
  /// last_deducted_grams。consumed_at 只在 [finalize] 时写入（任务结算时刻）。
  Future<bool> updateDeducted(
    int id,
    double lastDeductedGrams, {
    double? expectedPrevious,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = await customUpdate(
      'UPDATE print_task_consumables SET last_deducted_grams = ?, '
      'updated_at = ? WHERE id = ? AND consumed_at IS NULL '
      "AND EXISTS (SELECT 1 FROM print_tasks WHERE id = task_id "
      "AND status IN ('planned', 'printing', 'paused')) "
      '${expectedPrevious == null ? '' : 'AND last_deducted_grams = ?'}',
      variables: [
        Variable(lastDeductedGrams),
        Variable(now),
        Variable(id),
        if (expectedPrevious != null) Variable(expectedPrevious),
      ],
    );
    if (updated > 0) _emit();
    return updated > 0;
  }

  /// 任务完成时写入最终消耗克数（触发 _emit 让 UI 刷新）。
  /// consumed_at 更新为结算时刻。
  Future<bool> finalize(int id, double consumedGrams) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = await customUpdate(
      'UPDATE print_task_consumables SET consumed_grams = ?, '
      'last_deducted_grams = ?, updated_at = ?, consumed_at = ? '
      'WHERE id = ? AND consumed_at IS NULL',
      variables: [
        Variable(consumedGrams),
        Variable(consumedGrams),
        Variable(now),
        Variable(now),
        Variable(id),
      ],
    );
    if (updated > 0) _emit();
    return updated > 0;
  }

  /// 在同一结算事务内用实际库存变更量校正最终台账值。
  Future<void> updateFinalizedAmount(int id, double consumedGrams) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await customUpdate(
      'UPDATE print_task_consumables SET consumed_grams = ?, '
      'last_deducted_grams = ?, updated_at = ? '
      'WHERE id = ? AND consumed_at IS NOT NULL',
      variables: [
        Variable(consumedGrams),
        Variable(consumedGrams),
        Variable(now),
        Variable(id),
      ],
    );
  }

  /// 汇总指定时间范围内的耗材消耗（成本页汇总卡片用）。
  ///
  /// 按 (vendor, materialType, colorHex, costPerKgSnapshot) 分组聚合，
  /// 返回每组总克数 + 总成本。关联 consumables 表取耗材元信息。
  Future<List<ConsumptionSummaryRow>> getSummary({
    required DateTime start,
    required DateTime end,
  }) async {
    final rows = await customSelect(
      '''
      SELECT
        c.manufacturer AS vendor,
        c.material_type,
        c.color_hex,
        c.color_name,
        ptc.cost_per_kg_snapshot,
        SUM(ptc.consumed_grams) AS total_grams,
        SUM(ptc.consumed_grams / 1000.0 * ptc.cost_per_kg_snapshot) AS total_cost
      FROM print_task_consumables ptc
      LEFT JOIN consumables c ON c.id = ptc.consumable_id
      WHERE ptc.consumed_at BETWEEN ? AND ?
        AND ptc.consumed_grams > 0
      GROUP BY c.manufacturer, c.material_type, c.color_hex, ptc.cost_per_kg_snapshot
      ORDER BY total_cost DESC
      ''',
      variables: [
        Variable(start.millisecondsSinceEpoch),
        Variable(end.millisecondsSinceEpoch),
      ],
    ).get();
    return rows
        .map(
          (r) => ConsumptionSummaryRow(
            vendor: r.read<String?>('vendor') ?? '',
            materialType: r.read<String?>('material_type') ?? '',
            colorHex: r.read<String?>('color_hex') ?? '',
            colorName: r.read<String?>('color_name'),
            costPerKg: r.read<double?>('cost_per_kg_snapshot') ?? 0,
            totalGrams: r.read<double>('total_grams'),
            totalCost: r.read<double?>('total_cost') ?? 0,
          ),
        )
        .toList();
  }

  /// 汇总指定时间范围内的总消耗克数 + 总成本（汇总卡片顶部用）。
  Future<({double totalGrams, double totalCost})> getTotalSummary({
    required DateTime start,
    required DateTime end,
  }) async {
    final rows = await customSelect(
      '''
      SELECT
        SUM(consumed_grams) AS total_grams,
        SUM(consumed_grams / 1000.0 * cost_per_kg_snapshot) AS total_cost
      FROM print_task_consumables
      WHERE consumed_at BETWEEN ? AND ?
        AND consumed_grams > 0
      ''',
      variables: [
        Variable(start.millisecondsSinceEpoch),
        Variable(end.millisecondsSinceEpoch),
      ],
    ).get();
    if (rows.isEmpty) return (totalGrams: 0.0, totalCost: 0.0);
    return (
      totalGrams: rows.first.read<double?>('total_grams') ?? 0,
      totalCost: rows.first.read<double?>('total_cost') ?? 0,
    );
  }

  /// 查询指定耗材卷在所有任务中的累计消耗克数（库存页/耗材详情用）。
  Future<double> getConsumedGramsForConsumable(int consumableId) async {
    final rows = await customSelect(
      'SELECT SUM(consumed_grams) AS total FROM print_task_consumables '
      'WHERE consumable_id = ? AND consumed_grams > 0',
      variables: [Variable(consumableId)],
    ).get();
    if (rows.isEmpty) return 0;
    return rows.first.read<double?>('total') ?? 0;
  }

  /// 查询同材质耗材卷的近期消耗克数列表（创新2: Z-score 异常检测用）。
  ///
  /// 排除当前任务（excludeTaskId），只查 finished 状态（consumed_at 非空）的记录。
  /// 用于统计同材质耗材卷历史消耗的均值与标准差，判断当前任务消耗是否异常。
  ///
  /// [materialType] 材质关键字（如 'PLA'、'PETG'），按 LIKE 模糊匹配
  /// [excludeTaskId] 排除的当前任务 id（避免自身影响统计）
  /// [limit] 最多返回的记录数（默认 20 条，足够算 Z-score）
  Future<List<double>> getRecentConsumedGramsByMaterial({
    required String materialType,
    required int excludeTaskId,
    int limit = 20,
  }) async {
    if (materialType.isEmpty) return const [];
    final rows = await customSelect(
      '''
      SELECT ptc.consumed_grams AS grams
      FROM print_task_consumables ptc
      LEFT JOIN consumables c ON c.id = ptc.consumable_id
      WHERE ptc.consumed_grams > 0
        AND ptc.consumed_at IS NOT NULL
        AND ptc.task_id != ?
        AND c.material_type LIKE ?
      ORDER BY ptc.consumed_at DESC
      LIMIT ?
      ''',
      variables: [
        Variable(excludeTaskId),
        Variable('%$materialType%'),
        Variable(limit),
      ],
    ).get();
    return rows.map((r) => r.read<double?>('grams') ?? 0.0).toList();
  }

  /// 查询同耗材卷的近期消耗克数列表（创新2: Z-score 异常检测用）。
  ///
  /// 比 [getRecentConsumedGramsByMaterial] 粒度更细，针对单卷耗材的历史消耗。
  /// 当同卷历史记录 < 5 条时（统计样本不足），调用方应回退到材质维度统计。
  Future<List<double>> getRecentConsumedGramsForConsumable({
    required int consumableId,
    required int excludeTaskId,
    int limit = 20,
  }) async {
    final rows = await customSelect(
      '''
      SELECT consumed_grams AS grams
      FROM print_task_consumables
      WHERE consumed_grams > 0
        AND consumed_at IS NOT NULL
        AND consumable_id = ?
        AND task_id != ?
      ORDER BY consumed_at DESC
      LIMIT ?
      ''',
      variables: [
        Variable(consumableId),
        Variable(excludeTaskId),
        Variable(limit),
      ],
    ).get();
    return rows.map((r) => r.read<double?>('grams') ?? 0.0).toList();
  }

  /// 按时间粒度查询消耗时间序列（折线图用）。
  ///
  /// [start] 起始时间，[end] 结束时间，[intervalSeconds] 每个点的时间间隔（秒）。
  /// 返回每个时间段的累计消耗克数。用 consumed_at 做时间过滤（消耗实际发生时间）。
  /// 单条 SQL 分桶聚合，避免 N+1 查询（N9 修复）+ 修复越界（N4 修复）。
  Future<List<({DateTime time, double grams})>> getTimeline({
    required DateTime start,
    required DateTime end,
    required int intervalSeconds,
  }) async {
    final startMs = start.millisecondsSinceEpoch;
    final endMs = end.millisecondsSinceEpoch;
    final intervalMs = intervalSeconds * 1000;

    // 单条 SQL 按时间分桶聚合
    final rows = await customSelect(
      '''
      SELECT
        (consumed_at - ?) / ? AS bucket,
        SUM(consumed_grams) AS grams
      FROM print_task_consumables
      WHERE consumed_at >= ? AND consumed_at <= ?
        AND consumed_grams > 0
      GROUP BY bucket
      ''',
      variables: [
        Variable(startMs),
        Variable(intervalMs),
        Variable(startMs),
        Variable(endMs),
      ],
    ).get();

    // 构建分桶 Map
    final bucketMap = <int, double>{};
    for (final r in rows) {
      final bucket = r.read<int?>('bucket');
      if (bucket != null) {
        bucketMap[bucket] = r.read<double?>('grams') ?? 0;
      }
    }

    // 生成完整时间点列表（N4 修复：用 < endMs 避免越界）
    final points = <({DateTime time, double grams})>[];
    for (var t = startMs; t < endMs; t += intervalMs) {
      final bucket = (t - startMs) ~/ intervalMs;
      points.add((
        time: DateTime.fromMillisecondsSinceEpoch(t),
        grams: bucketMap[bucket] ?? 0,
      ));
    }
    return points;
  }

  /// 释放资源。
  void dispose() {
    // The database owns change notifications, including channel handoffs.
  }

  PrintTaskConsumable _rowToEntry(QueryRow row) {
    final createdMs = row.read<int>('created_at');
    final updatedMs = row.read<int>('updated_at');
    final consumedMs = row.read<int?>('consumed_at');
    return PrintTaskConsumable(
      id: row.read<int?>('id'),
      taskId: row.read<int>('task_id'),
      printerId: row.read<int?>('printer_id'),
      channelIndex: row.read<int>('channel_index'),
      consumableId: row.read<int?>('consumable_id'),
      toolIndex: row.read<int>('tool_index'),
      estimatedGrams: row.read<double>('estimated_grams'),
      segmentStartGrams: row.read<double>('segment_start_grams'),
      consumedGrams: row.read<double>('consumed_grams'),
      lastDeductedGrams: row.read<double>('last_deducted_grams'),
      costPerKgSnapshot: row.read<double?>('cost_per_kg_snapshot'),
      matchedCostConfigId: row.read<int?>('matched_cost_config_id'),
      // 幂等结算判据：consumed_at 非空 = 已结算过
      consumedAt: consumedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(consumedMs),
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdMs),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedMs),
    );
  }
}

/// 消耗汇总行（按耗材元信息分组）。
class ConsumptionSummaryRow {
  final String vendor;
  final String materialType;
  final String colorHex;
  final String? colorName;
  final double costPerKg;
  final double totalGrams;
  final double totalCost;

  const ConsumptionSummaryRow({
    required this.vendor,
    required this.materialType,
    required this.colorHex,
    required this.colorName,
    required this.costPerKg,
    required this.totalGrams,
    required this.totalCost,
  });
}
