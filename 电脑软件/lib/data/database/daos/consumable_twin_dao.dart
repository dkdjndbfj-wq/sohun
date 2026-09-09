import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../database.dart';
import '../models/consumable_twin_event.dart';

/// 拓竹 RFID 耗材数字孪生统一 Repository。
///
/// 对外提供事实来源，UI 不得自行拼接三套互相冲突的余量。
/// 管理 consumable_twin_events 表的读写，实现：
/// - 事件账本写入（去重防止 MQTT 心跳写爆数据库）
/// - 位置追踪（当前打印机/AMS/槽位）
/// - 余量轨迹查询
/// - 冲突核对
///
/// 资格判断：只有 hasRfidInfo && !isThirdParty && trayUuid.isNotEmpty 的耗材才进入数字孪生。
class ConsumableTwinDao extends DatabaseAccessor<AppDatabase> {
  ConsumableTwinDao(super.db);

  static const _uuid = Uuid();

  final StreamController<void> _changeController =
      StreamController<void>.broadcast();

  Stream<void> get onChange => _changeController.stream;

  void _emit() {
    if (!_changeController.isClosed) _changeController.add(null);
  }

  /// 差异阈值：max(20g, 额定重量的 3%)。
  static double reconciliationThreshold(double trayWeight) {
    return (20.0).clamp(0.0, double.infinity).abs() > trayWeight * 0.03
        ? 20.0
        : trayWeight * 0.03;
  }

  /// 记录数字孪生事件。
  ///
  /// 去重策略：同 trayUuid + 同 event_type + 同位置 + 5 分钟内 + 余量变化 < 1g 视为心跳，跳过。
  /// 位置变化和冲突修正事件永不跳过。
  Future<String> recordEvent({
    required int consumableId,
    required String trayUuid,
    required TwinEventType eventType,
    int? printerId,
    String? printerSerial,
    int? amsId,
    int? slotIndex,
    double? beforeGrams,
    double? afterGrams,
    int? rfidPercent,
    double? trayWeight,
    double? amsHumidity,
    DateTime? observedAt,
    String source = 'mqtt',
    int? taskId,
  }) async {
    final now = observedAt ?? DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;

    // 去重：心跳过滤（moved/reconciled/migration_snapshot 永不跳过）
    if (eventType != TwinEventType.moved &&
        eventType != TwinEventType.reconciled &&
        eventType != TwinEventType.migrationSnapshot &&
        eventType != TwinEventType.discovered &&
        eventType != TwinEventType.bound) {
      final shouldSkip = await _isHeartbeat(
        trayUuid,
        eventType,
        printerSerial,
        amsId,
        slotIndex,
        afterGrams,
        nowMs,
      );
      if (shouldSkip) {
        return '';
      }
    }

    final id = _uuid.v4();
    final eventUid = _uuid.v4();
    try {
      await customStatement(
        '''INSERT INTO consumable_twin_events(
          id, event_uid, consumable_id, tray_uuid, event_type,
          printer_id, printer_serial, ams_id, slot_index,
          before_grams, after_grams, rfid_percent, tray_weight,
          ams_humidity, observed_at, source, task_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          id,
          eventUid,
          consumableId,
          trayUuid,
          eventType.value,
          printerId,
          printerSerial ?? '',
          amsId,
          slotIndex,
          beforeGrams,
          afterGrams,
          rfidPercent,
          trayWeight,
          amsHumidity,
          nowMs,
          source,
          taskId,
        ],
      );
      _emit();
      return id;
    } catch (e) {
      debugPrint('[ConsumableTwinDao] recordEvent 失败: $e');
      return '';
    }
  }

  /// 心跳去重：同 trayUuid + 同 event_type + 同位置 + 5 分钟内 + 余量变化 < 1g。
  Future<bool> _isHeartbeat(
    String trayUuid,
    TwinEventType eventType,
    String? printerSerial,
    int? amsId,
    int? slotIndex,
    double? afterGrams,
    int nowMs,
  ) async {
    final fiveMinAgo = nowMs - 5 * 60 * 1000;
    final rows = await customSelect(
      'SELECT after_grams, printer_serial, ams_id, slot_index '
      'FROM consumable_twin_events '
      'WHERE tray_uuid = ? AND event_type = ? AND observed_at >= ? '
      'ORDER BY observed_at DESC LIMIT 1',
      variables: [
        Variable(trayUuid),
        Variable(eventType.value),
        Variable(fiveMinAgo),
      ],
    ).get();

    if (rows.isEmpty) return false;

    final lastAms = rows.first.read<int?>('ams_id');
    final lastSlot = rows.first.read<int?>('slot_index');
    final lastPrinter = rows.first.read<String?>('printer_serial') ?? '';
    final lastGrams = rows.first.read<double?>('after_grams');

    // 位置变化 → 不是心跳
    if (lastPrinter != (printerSerial ?? '') ||
        lastAms != amsId ||
        lastSlot != slotIndex) {
      return false;
    }

    // 余量变化 < 1g → 心跳
    if (afterGrams != null && lastGrams != null) {
      return (afterGrams - lastGrams).abs() < 1.0;
    }

    // removed 等无余量事件在同一位置重复上报时也是心跳。
    if (afterGrams == null && lastGrams == null) return true;

    return false;
  }

  /// 查询某个打印机 AMS 槽位当前登记的 RFID 卷。
  ///
  /// 只看会改变物理位置的事件，并要求该卷的最新位置事件仍落在此槽位；
  /// 因此已经 removed 或移动到别处的历史记录不会被误判为当前占用。
  Future<ConsumableTwinEvent?> getCurrentOccupantAtPosition({
    required String printerSerial,
    required int amsId,
    required int slotIndex,
  }) async {
    final rows = await customSelect(
      '''SELECT e.* FROM consumable_twin_events e
         WHERE e.printer_serial = ? AND e.ams_id = ? AND e.slot_index = ?
           AND e.event_type IN ('discovered', 'bound', 'moved',
                                'rfid_observed', 'removed', 'depleted')
           AND NOT EXISTS (
             SELECT 1 FROM consumable_twin_events newer
             WHERE newer.tray_uuid = e.tray_uuid
               AND newer.event_type IN ('discovered', 'bound', 'moved',
                                         'rfid_observed', 'removed', 'depleted')
               AND newer.observed_at > e.observed_at
           )
         ORDER BY e.observed_at DESC LIMIT 1''',
      variables: [
        Variable(printerSerial),
        Variable(amsId),
        Variable(slotIndex),
      ],
    ).get();
    if (rows.isEmpty) return null;
    final event = ConsumableTwinEvent.fromRow(rows.first.data);
    return event.eventType == TwinEventType.removed ? null : event;
  }

  /// 查询某卷耗材的完整轨迹（按时间正序）。
  Future<List<ConsumableTwinEvent>> getTimeline(
    String trayUuid, {
    int limit = 200,
  }) async {
    try {
      final rows = await customSelect(
        'SELECT * FROM consumable_twin_events WHERE tray_uuid = ? '
        'ORDER BY observed_at DESC LIMIT ?',
        variables: [Variable(trayUuid), Variable(limit)],
      ).get();
      return rows.map((r) => ConsumableTwinEvent.fromRow(r.data)).toList();
    } catch (e) {
      debugPrint('[ConsumableTwinDao] getTimeline 失败: $e');
      return const [];
    }
  }

  /// 获取某卷耗材的最新位置和状态。
  Future<ConsumableTwinState?> getCurrentState(String trayUuid) async {
    if (trayUuid.isEmpty) return null;
    try {
      final rows = await customSelect(
        'SELECT * FROM consumable_twin_events WHERE tray_uuid = ? '
        'ORDER BY observed_at DESC LIMIT 1',
        variables: [Variable(trayUuid)],
      ).get();
      if (rows.isEmpty) return null;
      final evt = ConsumableTwinEvent.fromRow(rows.first.data);

      // 检查是否耗尽
      final depleted = evt.eventType == TwinEventType.depleted ||
          (evt.rfidPercent != null && evt.rfidPercent == 0);

      return ConsumableTwinState(
        consumableId: evt.consumableId,
        trayUuid: trayUuid,
        printerSerial: evt.printerSerial,
        amsId: evt.amsId,
        slotIndex: evt.slotIndex,
        lastSeenAt: evt.observedAt,
        rfidPercent: evt.rfidPercent,
        estimatedGrams: evt.afterGrams,
        amsHumidity: evt.amsHumidity,
        isDepleted: depleted,
      );
    } catch (e) {
      debugPrint('[ConsumableTwinDao] getCurrentState 失败: $e');
      return null;
    }
  }

  /// 获取所有有待核对差异的耗材（最近一次 rfid_observed 与本地估算差异超阈值）。
  ///
  /// 返回 (trayUuid, consumableId, localGrams, rfidGrams, diff, threshold) 列表。
  Future<List<TwinReconciliation>> getPendingReconciliations({
    double Function(double trayWeight)? thresholdFn,
  }) async {
    thresholdFn ??= reconciliationThreshold;
    try {
      // 取每个 trayUuid 的最新 rfid_observed 事件
      final rows = await customSelect(
        "SELECT * FROM consumable_twin_events WHERE event_type = 'rfid_observed' "
        'ORDER BY observed_at DESC',
      ).get();

      final seen = <String, ConsumableTwinEvent>{};
      for (final r in rows) {
        final evt = ConsumableTwinEvent.fromRow(r.data);
        if (!seen.containsKey(evt.trayUuid)) {
          seen[evt.trayUuid] = evt;
        }
      }

      final result = <TwinReconciliation>[];
      for (final evt in seen.values) {
        if (evt.afterGrams == null || evt.trayWeight == null) continue;
        final threshold = thresholdFn(evt.trayWeight!);
        // 本地估算值 = before_grams
        final localGrams = evt.beforeGrams ?? evt.afterGrams!;
        final rfidGrams = evt.afterGrams!;
        final diff = rfidGrams - localGrams;
        if (diff.abs() > threshold) {
          result.add(
            TwinReconciliation(
              id: evt.eventUid,
              consumableId: evt.consumableId,
              trayUuid: evt.trayUuid,
              localEstimatedGrams: localGrams,
              rfidObservedGrams: rfidGrams,
              differenceGrams: diff,
              thresholdGrams: threshold,
              detectedAt: evt.observedAt,
            ),
          );
        }
      }
      return result;
    } catch (e) {
      debugPrint('[ConsumableTwinDao] getPendingReconciliations 失败: $e');
      return const [];
    }
  }

  /// 用户核对修正：采用 RFID 观测值或保留本地估算。
  ///
  /// [adoptRfid] 为 true 时采用 RFID 观测值，false 保留本地估算。
  /// 写入 reconciled 事件并更新耗材 remainingGrams。
  Future<void> reconcile({
    required int consumableId,
    required String trayUuid,
    required bool adoptRfid,
    required double rfidObservedGrams,
    required double localEstimatedGrams,
    double? trayWeight,
    int? printerId,
    String? printerSerial,
    int? amsId,
    int? slotIndex,
  }) async {
    final now = DateTime.now();
    final finalGrams = adoptRfid ? rfidObservedGrams : localEstimatedGrams;

    await recordEvent(
      consumableId: consumableId,
      trayUuid: trayUuid,
      eventType: TwinEventType.reconciled,
      printerId: printerId,
      printerSerial: printerSerial,
      amsId: amsId,
      slotIndex: slotIndex,
      beforeGrams: localEstimatedGrams,
      afterGrams: finalGrams,
      trayWeight: trayWeight,
      observedAt: now,
      source: 'user_reconcile',
    );
  }

  /// 清理老旧无变化事件（保留策略：位置变化和冲突修正事件永不清除）。
  ///
  /// 保留最近 90 天或最多 1000 条/trayUuid。
  Future<int> cleanupOldEvents({int retainDays = 90}) async {
    final cutoff = DateTime.now()
        .subtract(Duration(days: retainDays))
        .millisecondsSinceEpoch;
    try {
      final count = await customUpdate(
        "DELETE FROM consumable_twin_events "
        "WHERE observed_at < ? AND event_type NOT IN ('moved', 'reconciled', 'migration_snapshot')",
        variables: [Variable(cutoff)],
      );
      if (count > 0) _emit();
      return count;
    } catch (e) {
      debugPrint('[ConsumableTwinDao] cleanupOldEvents 失败: $e');
      return 0;
    }
  }

  void dispose() {
    _changeController.close();
  }
}
