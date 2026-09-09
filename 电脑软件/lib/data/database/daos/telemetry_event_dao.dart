import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../database.dart';
import '../models/telemetry_event.dart';

export '../models/telemetry_event.dart'
    show TelemetryEvent, TelemetryUploadStatus, TelemetryAggregateRow;

/// 遥测事件数据访问层。raw SQL 实现（不走 drift 代码生成）。
///
/// 配合 [TelemetryService]：
/// - [insert]：写入单条事件（INSERT OR IGNORE 幂等）
/// - [queryPending]：拉取待上传批次
/// - [markSynced] / [markFailed] / [incrementAttempt]：上传结果回写
/// - [clearOldEvents]：保留期清理（30 天 + 上限 10000 条）
/// - [countByStatus]：仪表盘统计
///
/// 表结构事实来源：[AppDatabase._createTelemetryEventsTable] 的 raw SQL
/// （见 lib/data/database/database.dart，schema v19）。
class TelemetryEventDao extends DatabaseAccessor<AppDatabase> {
  TelemetryEventDao(super.db);

  /// 写入单条遥测事件。INSERT OR IGNORE 保证按 event_uid 幂等。
  /// 返回受影响行数（0 表示因 UNIQUE 冲突被忽略）。
  Future<int> insert(TelemetryEvent event) async {
    try {
      return await customInsert(
        '''
        INSERT OR IGNORE INTO telemetry_events (
          id, event_uid, event_name, result_category, duration_ms,
          attributes, recorded_at, upload_status, attempt_count, next_retry_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        variables: [
          Variable(event.id),
          Variable(event.eventUid),
          Variable(event.eventName),
          Variable(event.resultCategory),
          Variable(event.durationMs),
          Variable(_encodeAttributes(event.attributes)),
          Variable(event.recordedAt.millisecondsSinceEpoch),
          Variable(event.uploadStatus.code),
          Variable(event.attemptCount),
          Variable(event.nextRetryAt?.millisecondsSinceEpoch),
        ],
      );
    } catch (e) {
      debugPrint('[TelemetryEventDao] insert 失败: $e');
      return 0;
    }
  }

  /// 查询待上传事件批次。
  ///
  /// 筛选条件：
  /// - upload_status='pending'
  /// - next_retry_at IS NULL（从未失败）或 next_retry_at <= now（退避已到期）
  ///
  /// 按 recorded_at 升序，保证先入先出。
  Future<List<TelemetryEvent>> queryPending({int limit = 50}) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rows = await customSelect(
      '''
      SELECT * FROM telemetry_events
      WHERE upload_status = 'pending'
        AND (next_retry_at IS NULL OR next_retry_at <= ?)
      ORDER BY recorded_at ASC
      LIMIT ?
      ''',
      variables: [Variable(nowMs), Variable(limit)],
    ).get();
    return rows.map(_rowToEvent).toList();
  }

  /// 标记一批事件为已上传。空列表直接返回，避免生成非法 SQL。
  Future<void> markSynced(List<String> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(', ');
    await customUpdate(
      'UPDATE telemetry_events SET upload_status = \'synced\' '
      'WHERE id IN ($placeholders)',
      variables: ids.map(Variable.new).toList(),
    );
  }

  /// 标记单条事件为永久失败（401/403 等不可重试场景）。
  /// attempt_count 自增。[nextRetryAt] 可选，通常为 null（不再重试）。
  Future<void> markFailed(String id, {int? nextRetryAt}) async {
    await customUpdate(
      '''
      UPDATE telemetry_events
      SET upload_status = 'failed',
          attempt_count = attempt_count + 1,
          next_retry_at = ?
      WHERE id = ?
      ''',
      variables: [
        Variable(nextRetryAt),
        Variable(id),
      ],
    );
  }

  /// 自增尝试次数并设置下次重试时间（网络错误退避场景）。
  /// 状态保持 pending，等退避到期后由 [queryPending] 再次拉取。
  Future<void> incrementAttempt(String id, {int? nextRetryAt}) async {
    await customUpdate(
      '''
      UPDATE telemetry_events
      SET attempt_count = attempt_count + 1,
          next_retry_at = ?
      WHERE id = ?
      ''',
      variables: [
        Variable(nextRetryAt),
        Variable(id),
      ],
    );
  }

  /// 统计待上传事件数量。
  Future<int> countPending() async {
    final rows = await customSelect(
      "SELECT COUNT(*) AS cnt FROM telemetry_events "
      "WHERE upload_status = 'pending'",
    ).get();
    if (rows.isEmpty) return 0;
    return rows.first.read<int?>('cnt') ?? 0;
  }

  /// 按保留策略清理旧事件。
  ///
  /// 1. 删除 [before] 之前的事件（默认 30 天前）。
  /// 2. 若剩余总数超过 [maxRetained]，按 recorded_at 升序删除非崩溃事件
  ///    （event_name != 'app.crash'）直到达标；若仍超额，再删除最旧的
  ///    崩溃事件。崩溃事件优先保留以便事后排查。
  Future<void> clearOldEvents({
    DateTime? before,
    int maxRetained = 10000,
  }) async {
    final cutoff = before ?? DateTime.now().subtract(const Duration(days: 30));
    // 注意：时间清理只删 synced/failed 事件，保留 pending 以便后续上传。
    // 任务书 11.4：清理策略不会删除仍需上传的数据。
    await customUpdate(
      'DELETE FROM telemetry_events WHERE recorded_at < ? '
      'AND upload_status != ?',
      variables: [
        Variable(cutoff.millisecondsSinceEpoch),
        Variable(TelemetryUploadStatus.pending.code),
      ],
    );

    final total = await _countAll();
    if (total <= maxRetained) return;

    var excess = total - maxRetained;
    // 先删非崩溃事件中最旧的
    excess = await _deleteOldest(excess, preserveCrash: true);
    if (excess > 0) {
      // 仍超额则连崩溃事件一起删
      await _deleteOldest(excess, preserveCrash: false);
    }
  }

  /// 清理 pending 队列：最多保留 [maxPending] 条或 [maxAge] 内的事件。
  ///
  /// 任务书 11.4：未发送队列最多 1000 条或 7 天；超限先删最旧非崩溃聚合事件。
  /// 与 [clearOldEvents] 不同，此方法仅作用于 upload_status='pending' 的事件，
  /// 不会删除已 synced/failed 的历史聚合数据。
  Future<void> clearOldPendingEvents({
    int maxPending = 1000,
    Duration maxAge = const Duration(days: 7),
  }) async {
    // 1. 删除超过 maxAge 的 pending 事件（断网场景下堆积的旧数据）
    final ageCutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    await customUpdate(
      'DELETE FROM telemetry_events '
      'WHERE upload_status = ? AND recorded_at < ?',
      variables: [
        Variable(TelemetryUploadStatus.pending.code),
        Variable(ageCutoff),
      ],
    );

    // 2. 超 maxPending 条时，先删最旧的非崩溃 pending 事件
    final pendingCount = await _countByStatus(
      TelemetryUploadStatus.pending,
    );
    if (pendingCount <= maxPending) return;

    var excess = pendingCount - maxPending;
    excess = await _deleteOldest(
      excess,
      preserveCrash: true,
      onlyPending: true,
    );
    if (excess > 0) {
      // 仍超额则连崩溃 pending 事件一起删
      await _deleteOldest(
        excess,
        preserveCrash: false,
        onlyPending: true,
      );
    }
  }

  /// 按事件名查询（指标汇总用）。可选时间下限 [since]，默认最近 [limit] 条。
  Future<List<TelemetryEvent>> queryByEventName(
    String eventName, {
    DateTime? since,
    int limit = 100,
  }) async {
    final where = <String>['event_name = ?'];
    final vars = <Variable>[Variable(eventName)];
    if (since != null) {
      where.add('recorded_at >= ?');
      vars.add(Variable(since.millisecondsSinceEpoch));
    }
    final rows = await customSelect(
      'SELECT * FROM telemetry_events '
      'WHERE ${where.join(' AND ')} '
      'ORDER BY recorded_at DESC LIMIT ?',
      variables: [...vars, Variable(limit)],
    ).get();
    return rows.map(_rowToEvent).toList();
  }

  /// 清空全部事件（用户主动清空）。
  Future<void> clearAll() async {
    await customUpdate('DELETE FROM telemetry_events');
  }

  /// 仅清空 pending 队列，保留 synced/failed 历史聚合数据。
  ///
  /// 任务书 11.5：关闭匿名诊断开关后停止上传并清空未发送队列，
  /// 但不删除用户主动保留的本地错误日志（error_logs 表）和已上传的遥测历史。
  Future<void> clearPending() async {
    await customUpdate(
      'DELETE FROM telemetry_events WHERE upload_status = ?',
      variables: [Variable(TelemetryUploadStatus.pending.code)],
    );
  }

  /// 按上传状态聚合统计。返回 {pending, synced, failed} 计数。
  /// 缺失的状态默认 0。
  Future<Map<String, int>> countByStatus() async {
    final rows = await customSelect(
      'SELECT upload_status AS status, COUNT(*) AS cnt '
      'FROM telemetry_events GROUP BY upload_status',
    ).get();
    final result = <String, int>{
      'pending': 0,
      'synced': 0,
      'failed': 0,
    };
    for (final row in rows) {
      final status = row.read<String?>('status') ?? 'pending';
      final cnt = row.read<int?>('cnt') ?? 0;
      result[status] = cnt;
    }
    return result;
  }

  /// 按事件名 + 结果类别聚合统计，用于运行指标页签。
  ///
  /// 返回每个 (eventName, resultCategory) 的：
  /// - count：事件次数
  /// - avgDurationMs：平均耗时（NULL 表示无 duration 字段）
  /// - lastRecordedAt：最近一次发生时间
  ///
  /// [since] 可选时间下限，默认最近 7 天。
  Future<List<TelemetryAggregateRow>> aggregateByEvent({
    DateTime? since,
  }) async {
    final cutoff = (since ?? DateTime.now().subtract(const Duration(days: 7)))
        .millisecondsSinceEpoch;
    final rows = await customSelect(
      '''
      SELECT
        event_name AS event_name,
        COALESCE(result_category, '') AS result_category,
        COUNT(*) AS cnt,
        AVG(duration_ms) AS avg_duration,
        MAX(recorded_at) AS last_recorded_at
      FROM telemetry_events
      WHERE recorded_at >= ?
      GROUP BY event_name, COALESCE(result_category, '')
      ORDER BY event_name ASC, result_category ASC
      ''',
      variables: [Variable(cutoff)],
    ).get();
    return rows.map((row) {
      final avgDuration = row.read<double?>('avg_duration');
      return TelemetryAggregateRow(
        eventName: row.read<String>('event_name'),
        resultCategory: row.read<String?>('result_category') ?? '',
        count: row.read<int?>('cnt') ?? 0,
        avgDurationMs: avgDuration?.round(),
        lastRecordedAt: DateTime.fromMillisecondsSinceEpoch(
          row.read<int>('last_recorded_at'),
        ),
      );
    }).toList();
  }

  /// 查询最近 [limit] 条事件（运行指标页签的"最近事件"列表用）。
  Future<List<TelemetryEvent>> queryRecent({int limit = 100}) async {
    final rows = await customSelect(
      'SELECT * FROM telemetry_events ORDER BY recorded_at DESC LIMIT ?',
      variables: [Variable(limit)],
    ).get();
    return rows.map(_rowToEvent).toList();
  }

  /// 释放资源（数据库关闭时调用）。
  void dispose() {
    // 当前 DAO 无 StreamController，预留以便未来扩展 watch 流时统一释放。
  }

  // -- 内部辅助 -------------------------------------------------------------

  Future<int> _countAll() async {
    final rows = await customSelect(
      'SELECT COUNT(*) AS cnt FROM telemetry_events',
    ).get();
    if (rows.isEmpty) return 0;
    return rows.first.read<int?>('cnt') ?? 0;
  }

  /// 删除最旧的 [count] 条事件。[preserveCrash]=true 时跳过 app.crash 事件。
  /// [onlyPending]=true 时仅删除 upload_status='pending' 的事件。
  /// 返回仍未删除的数量（当可删除事件不足时 > 0）。
  Future<int> _deleteOldest(
    int count, {
    required bool preserveCrash,
    bool onlyPending = false,
  }) async {
    if (count <= 0) return 0;
    final whereParts = <String>[];
    if (preserveCrash) whereParts.add("event_name != 'app.crash'");
    if (onlyPending) {
      whereParts.add("upload_status = '${TelemetryUploadStatus.pending.code}'");
    }
    final whereClause =
        whereParts.isEmpty ? '' : 'WHERE ${whereParts.join(' AND ')}';
    // 先查出待删除的 id，再按 id 删除（SQLite 不支持 LIMIT 子查询直接 DELETE）
    final rows = await customSelect(
      'SELECT id FROM telemetry_events $whereClause '
      'ORDER BY recorded_at ASC LIMIT ?',
      variables: [Variable(count)],
    ).get();
    if (rows.isEmpty) return count;
    final ids = rows.map((r) => r.read<String>('id')).toList();
    final placeholders = List.filled(ids.length, '?').join(', ');
    await customUpdate(
      'DELETE FROM telemetry_events WHERE id IN ($placeholders)',
      variables: ids.map(Variable.new).toList(),
    );
    return count - ids.length;
  }

  /// 按上传状态计数。
  Future<int> _countByStatus(TelemetryUploadStatus status) async {
    final rows = await customSelect(
      'SELECT COUNT(*) AS cnt FROM telemetry_events WHERE upload_status = ?',
      variables: [Variable(status.code)],
    ).get();
    if (rows.isEmpty) return 0;
    return rows.first.read<int?>('cnt') ?? 0;
  }

  String _encodeAttributes(Map<String, dynamic> attributes) {
    if (attributes.isEmpty) return '{}';
    try {
      return jsonEncode(attributes);
    } catch (_) {
      return '{}';
    }
  }

  TelemetryEvent _rowToEvent(QueryRow row) {
    return TelemetryEvent.fromMap({
      'id': row.read<String>('id'),
      'event_uid': row.read<String>('event_uid'),
      'event_name': row.read<String>('event_name'),
      'result_category': row.read<String?>('result_category'),
      'duration_ms': row.read<int?>('duration_ms'),
      'attributes': row.read<String>('attributes'),
      'recorded_at': row.read<int>('recorded_at'),
      'upload_status': row.read<String>('upload_status'),
      'attempt_count': row.read<int>('attempt_count'),
      'next_retry_at': row.read<int?>('next_retry_at'),
    });
  }
}
