import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/database.dart';

/// 打印机故障事件模型。
///
/// 记录单台打印机上某故障代码的完整生命周期：
/// first_seen_at → last_seen_at → cleared_at。
/// 同一打印机 + 同一代码在活动期（cleared_at IS NULL）只保留一条事件，
/// 清除后再次出现才新建事件。
class PrinterFaultEvent {
  final String id;
  final String eventUid;
  final int? printerId;
  final String printerSerial;
  final int? taskId;
  final String code;
  final String severity;
  final String title;
  final String summary;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final DateTime? clearedAt;
  final DateTime? userConfirmedAt;
  final String? knowledgeBaseVersion;
  final String? rawPayload;

  const PrinterFaultEvent({
    required this.id,
    required this.eventUid,
    required this.printerId,
    required this.printerSerial,
    required this.taskId,
    required this.code,
    required this.severity,
    required this.title,
    required this.summary,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.clearedAt,
    required this.userConfirmedAt,
    required this.knowledgeBaseVersion,
    required this.rawPayload,
  });
}

/// 故障事件生命周期服务。
///
/// 管理 printer_fault_events 表的读写，实现故障去重、清除和历史查询。
/// 通过 [DatabaseAccessor] 访问 drift 数据库，使用 raw SQL 操作。
///
/// **去重逻辑**：同一台打印机 + 同一代码 + 活动状态（cleared_at IS NULL）
/// 只保留一条事件，后续推送更新 last_seen_at 而不新建。
///
/// **清除逻辑**：MQTT 显式发送空 HMS 时只清除 HMS 故障；
/// 字段缺失时不清除（避免误清现有故障）。
class FaultEventLifecycleService extends DatabaseAccessor<AppDatabase> {
  FaultEventLifecycleService(super.db);

  final Uuid _uuid = const Uuid();

  /// 插入或更新故障事件（去重）。
  ///
  /// 若该打印机已有相同 code 的活动事件（cleared_at IS NULL），
  /// 只更新 last_seen_at 和原始负载，不新建事件。
  /// 否则创建新事件，first_seen_at = last_seen_at = 当前时间。
  ///
  /// 返回受影响的故障事件（新建或更新后的）。失败时返回 null。
  Future<PrinterFaultEvent?> upsertFault({
    required String printerSerial,
    required String code,
    required String severity,
    String title = '',
    String summary = '',
    int? printerId,
    int? taskId,
    String? knowledgeBaseVersion,
    String? rawPayload,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    try {
      // 查找同一打印机 + 同一代码的活动事件
      final existing = await customSelect(
        'SELECT * FROM printer_fault_events '
        'WHERE printer_serial = ? AND code = ? AND cleared_at IS NULL '
        'ORDER BY last_seen_at DESC LIMIT 1',
        variables: [Variable(printerSerial), Variable(code)],
      ).get();

      if (existing.isNotEmpty) {
        // 更新现有事件的 last_seen_at
        final row = existing.first;
        final id = row.read<String>('id');
        await customUpdate(
          'UPDATE printer_fault_events SET last_seen_at = ?, '
          'severity = ?, title = ?, summary = ?, raw_payload = ? '
          'WHERE id = ?',
          variables: [
            Variable(now),
            Variable(severity),
            Variable(title),
            Variable(summary),
            Variable(rawPayload),
            Variable(id),
          ],
        );
        final updated = await customSelect(
          'SELECT * FROM printer_fault_events WHERE id = ?',
          variables: [Variable(id)],
        ).getSingle();
        return _rowToEvent(updated);
      }

      // 创建新事件
      final id = _uuid.v4();
      final eventUid = _uuid.v4();
      await customInsert(
        '''INSERT INTO printer_fault_events (
          id, event_uid, printer_id, printer_serial, task_id,
          code, severity, title, summary,
          first_seen_at, last_seen_at, cleared_at, user_confirmed_at,
          knowledge_base_version, raw_payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        variables: [
          Variable(id),
          Variable(eventUid),
          Variable(printerId),
          Variable(printerSerial),
          Variable(taskId),
          Variable(code),
          Variable(severity),
          Variable(title),
          Variable(summary),
          Variable(now),
          Variable(now),
          const Variable(null),
          const Variable(null),
          Variable(knowledgeBaseVersion),
          Variable(rawPayload),
        ],
      );

      return PrinterFaultEvent(
        id: id,
        eventUid: eventUid,
        printerId: printerId,
        printerSerial: printerSerial,
        taskId: taskId,
        code: code,
        severity: severity,
        title: title,
        summary: summary,
        firstSeenAt: DateTime.fromMillisecondsSinceEpoch(now),
        lastSeenAt: DateTime.fromMillisecondsSinceEpoch(now),
        clearedAt: null,
        userConfirmedAt: null,
        knowledgeBaseVersion: knowledgeBaseVersion,
        rawPayload: rawPayload,
      );
    } catch (e) {
      debugPrint('[FaultEventLifecycleService] upsertFault 失败: $e');
      return null;
    }
  }

  /// 清除指定打印机的指定故障代码的活动事件。
  ///
  /// 将 cleared_at 设为当前时间，不删除记录（保留历史）。
  Future<void> clearFault(String printerSerial, String code) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await customUpdate(
        'UPDATE printer_fault_events SET cleared_at = ? '
        'WHERE printer_serial = ? AND code = ? AND cleared_at IS NULL',
        variables: [Variable(now), Variable(printerSerial), Variable(code)],
      );
    } catch (e) {
      debugPrint('[FaultEventLifecycleService] clearFault 失败: $e');
    }
  }

  /// 清除指定打印机的所有活动故障。
  ///
  /// 将 cleared_at 设为当前时间，不删除记录（保留历史）。
  Future<void> clearAllFaults(String printerSerial) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await customUpdate(
        'UPDATE printer_fault_events SET cleared_at = ? '
        'WHERE printer_serial = ? AND cleared_at IS NULL',
        variables: [Variable(now), Variable(printerSerial)],
      );
    } catch (e) {
      debugPrint('[FaultEventLifecycleService] clearAllFaults 失败: $e');
    }
  }

  /// 获取指定打印机的活动故障列表（cleared_at IS NULL）。
  ///
  /// 按 last_seen_at 倒序返回。
  Future<List<PrinterFaultEvent>> getActiveFaults(String printerSerial) async {
    try {
      final rows = await customSelect(
        'SELECT * FROM printer_fault_events '
        'WHERE printer_serial = ? AND cleared_at IS NULL '
        'ORDER BY last_seen_at DESC',
        variables: [Variable(printerSerial)],
      ).get();
      return rows.map(_rowToEvent).toList();
    } catch (e) {
      debugPrint('[FaultEventLifecycleService] getActiveFaults 失败: $e');
      return const [];
    }
  }

  /// 获取指定打印机的故障历史（包括已清除的事件）。
  ///
  /// 可选时间范围过滤（按 last_seen_at）。
  /// 按 last_seen_at 倒序返回。
  Future<List<PrinterFaultEvent>> getFaultHistory(
    String printerSerial, {
    DateTime? since,
  }) async {
    try {
      if (since != null) {
        final rows = await customSelect(
          'SELECT * FROM printer_fault_events '
          'WHERE printer_serial = ? AND last_seen_at >= ? '
          'ORDER BY last_seen_at DESC',
          variables: [
            Variable(printerSerial),
            Variable(since.millisecondsSinceEpoch),
          ],
        ).get();
        return rows.map(_rowToEvent).toList();
      }
      final rows = await customSelect(
        'SELECT * FROM printer_fault_events '
        'WHERE printer_serial = ? '
        'ORDER BY last_seen_at DESC',
        variables: [Variable(printerSerial)],
      ).get();
      return rows.map(_rowToEvent).toList();
    } catch (e) {
      debugPrint('[FaultEventLifecycleService] getFaultHistory 失败: $e');
      return const [];
    }
  }

  /// 用户确认故障事件（设置 user_confirmed_at）。
  Future<void> confirmFault(String eventUid) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      await customUpdate(
        'UPDATE printer_fault_events SET user_confirmed_at = ? '
        'WHERE event_uid = ?',
        variables: [Variable(now), Variable(eventUid)],
      );
    } catch (e) {
      debugPrint('[FaultEventLifecycleService] confirmFault 失败: $e');
    }
  }

  /// 处理 MQTT HMS 负载。
  ///
  /// - [hmsList] 为 null：字段缺失，不做任何操作（不清除现有故障）。
  /// - [hmsList] 为空列表：显式空 HMS，只清除该打印机 HMS 故障。
  /// - [hmsList] 非空：逐条 upsert 故障事件。
  ///
  /// 每个元素为 Map，需包含 `code` 字段，可选 `severity` / `title` / `summary`。
  Future<void> handleHmsPayload(
    String printerSerial,
    List<Map<String, dynamic>>? hmsList, {
    int? printerId,
    int? taskId,
    String? knowledgeBaseVersion,
  }) async {
    if (hmsList == null) return;
    final reported = hmsList.map((e) => e['code']).whereType<String>().toSet();
    for (final old in await getActiveFaults(printerSerial)) {
      // print_error uses an independent 8-digit namespace. Clearing HMS must
      // never dismiss an outstanding print task error.
      if (!RegExp(r'^[0-9A-Fa-f]{8}$').hasMatch(old.code) &&
          !reported.contains(old.code)) {
        await clearFault(printerSerial, old.code);
      }
    }
    for (final hms in hmsList) {
      final code = hms['code'] as String? ?? '';
      if (code.isEmpty) continue;
      final severity = hms['severity'] as String? ?? 'warning';
      final title = hms['title'] as String? ?? '';
      final summary = hms['summary'] as String? ?? '';
      final rawPayload = hms['rawPayload'] as String?;
      await upsertFault(
        printerSerial: printerSerial,
        code: code,
        severity: severity,
        title: title,
        summary: summary,
        printerId: printerId,
        taskId: taskId,
        knowledgeBaseVersion: knowledgeBaseVersion,
        rawPayload: rawPayload,
      );
    }
  }

  /// 把 SQLite 行映射为 [PrinterFaultEvent] 对象。
  PrinterFaultEvent _rowToEvent(QueryRow row, {int? overrideLastSeen}) {
    final firstSeenMs = row.read<int>('first_seen_at');
    final lastSeenMs = overrideLastSeen ?? row.read<int>('last_seen_at');
    final clearedMs = row.read<int?>('cleared_at');
    final confirmedMs = row.read<int?>('user_confirmed_at');

    return PrinterFaultEvent(
      id: row.read<String>('id'),
      eventUid: row.read<String>('event_uid'),
      printerId: row.read<int?>('printer_id'),
      printerSerial: row.read<String>('printer_serial'),
      taskId: row.read<int?>('task_id'),
      code: row.read<String>('code'),
      severity: row.read<String>('severity'),
      title: row.read<String>('title'),
      summary: row.read<String>('summary'),
      firstSeenAt: DateTime.fromMillisecondsSinceEpoch(firstSeenMs),
      lastSeenAt: DateTime.fromMillisecondsSinceEpoch(lastSeenMs),
      clearedAt: clearedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(clearedMs),
      userConfirmedAt: confirmedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(confirmedMs),
      knowledgeBaseVersion: row.read<String?>('knowledge_base_version'),
      rawPayload: row.read<String?>('raw_payload'),
    );
  }
}
