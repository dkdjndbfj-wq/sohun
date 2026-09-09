/// 拓竹 RFID 耗材数字孪生事件模型。
///
/// 记录一卷拓竹原厂 RFID 耗材的完整生命周期事件。
/// 同一 trayUuid 的所有事件形成轨迹，用于位置追踪、余量核对和冲突检测。
///
/// 事件类型：
/// - [migrationSnapshot]：迁移快照（升级时为已有 trayUuid 记录生成）
/// - [discovered]：首次发现（MQTT 推送中检测到新 trayUuid）
/// - [bound]：绑定到库存（用户手动或自动关联）
/// - [moved]：位置移动（换槽、换 AMS、换打印机）
/// - [rfidObserved]：RFID 观测（remain 百分比变化）
/// - [printEstimated]：打印估算扣减
/// - [reconciled]：用户核对修正（采用 RFID 观测值或保留本地估算）
/// - [removed]：从 AMS 移除
/// - [depleted]：卷耗尽（remain == 0）
library;

/// 数字孪生事件类型枚举。
enum TwinEventType {
  migrationSnapshot('migration_snapshot'),
  discovered('discovered'),
  bound('bound'),
  moved('moved'),
  rfidObserved('rfid_observed'),
  printEstimated('print_estimated'),
  reconciled('reconciled'),
  removed('removed'),
  depleted('depleted');

  final String value;
  const TwinEventType(this.value);

  static TwinEventType fromValue(String v) {
    for (final e in TwinEventType.values) {
      if (e.value == v) return e;
    }
    return TwinEventType.rfidObserved;
  }
}

/// 数字孪生事件记录。
class ConsumableTwinEvent {
  final String id;
  final String eventUid;
  final int consumableId;
  final String trayUuid;
  final TwinEventType eventType;
  final int? printerId;
  final String? printerSerial;
  final int? amsId;
  final int? slotIndex;
  final double? beforeGrams;
  final double? afterGrams;
  final int? rfidPercent;
  final double? trayWeight;
  final double? amsHumidity;
  final DateTime observedAt;
  final String source;
  final int? taskId;

  const ConsumableTwinEvent({
    required this.id,
    required this.eventUid,
    required this.consumableId,
    required this.trayUuid,
    required this.eventType,
    this.printerId,
    this.printerSerial,
    this.amsId,
    this.slotIndex,
    this.beforeGrams,
    this.afterGrams,
    this.rfidPercent,
    this.trayWeight,
    this.amsHumidity,
    required this.observedAt,
    this.source = 'mqtt',
    this.taskId,
  });

  factory ConsumableTwinEvent.fromRow(Map<String, dynamic> row) {
    final storedPrinterSerial = row['printer_serial'] as String?;
    return ConsumableTwinEvent(
      id: row['id'] as String,
      eventUid: row['event_uid'] as String,
      consumableId: row['consumable_id'] as int,
      trayUuid: (row['tray_uuid'] as String?) ?? '',
      eventType: TwinEventType.fromValue(row['event_type'] as String? ?? ''),
      printerId: row['printer_id'] as int?,
      printerSerial: storedPrinterSerial == null || storedPrinterSerial.isEmpty
          ? null
          : storedPrinterSerial,
      amsId: row['ams_id'] as int?,
      slotIndex: row['slot_index'] as int?,
      beforeGrams: (row['before_grams'] as num?)?.toDouble(),
      afterGrams: (row['after_grams'] as num?)?.toDouble(),
      rfidPercent: row['rfid_percent'] as int?,
      trayWeight: (row['tray_weight'] as num?)?.toDouble(),
      amsHumidity: (row['ams_humidity'] as num?)?.toDouble(),
      observedAt: DateTime.fromMillisecondsSinceEpoch(
        row['observed_at'] as int,
      ),
      source: (row['source'] as String?) ?? 'mqtt',
      taskId: row['task_id'] as int?,
    );
  }
}

/// 数字孪生当前状态快照。
///
/// 从最新事件和耗材记录派生，用于 UI 展示。
class ConsumableTwinState {
  final int consumableId;
  final String trayUuid;
  final String? printerSerial;
  final int? amsId;
  final int? slotIndex;
  final DateTime? lastSeenAt;
  final int? rfidPercent;
  final double? estimatedGrams;
  final double? amsHumidity;
  final DateTime? amsHumiditySampledAt;
  final bool isDepleted;

  const ConsumableTwinState({
    required this.consumableId,
    required this.trayUuid,
    this.printerSerial,
    this.amsId,
    this.slotIndex,
    this.lastSeenAt,
    this.rfidPercent,
    this.estimatedGrams,
    this.amsHumidity,
    this.amsHumiditySampledAt,
    this.isDepleted = false,
  });

  /// 数据是否过期（超过 1 小时未更新）。
  bool get isStale {
    if (lastSeenAt == null) return true;
    return DateTime.now().difference(lastSeenAt!).inHours > 1;
  }
}

/// 待核对差异记录。
///
/// RFID 观测值与本地估算值差异超过阈值时生成。
class TwinReconciliation {
  final String id;
  final int consumableId;
  final String trayUuid;
  final double localEstimatedGrams;
  final double rfidObservedGrams;
  final double differenceGrams;
  final double thresholdGrams;
  final DateTime detectedAt;
  final String? resolution;
  final DateTime? resolvedAt;

  const TwinReconciliation({
    required this.id,
    required this.consumableId,
    required this.trayUuid,
    required this.localEstimatedGrams,
    required this.rfidObservedGrams,
    required this.differenceGrams,
    required this.thresholdGrams,
    required this.detectedAt,
    this.resolution,
    this.resolvedAt,
  });

  /// 是否已解决。
  bool get isResolved => resolution != null && resolvedAt != null;

  /// 差异方向描述。
  String get differenceDescription {
    if (differenceGrams.abs() < 0.01) return '无差异';
    if (differenceGrams > 0) {
      return 'RFID 观测比本地估算多 ${differenceGrams.toStringAsFixed(1)}g';
    }
    return 'RFID 观测比本地估算少 ${differenceGrams.abs().toStringAsFixed(1)}g';
  }
}
