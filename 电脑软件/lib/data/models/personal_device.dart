/// Device workbench data. It contains no filament identity or printer secrets.
class PersonalDevice {
  const PersonalDevice({
    required this.printerKey,
    required this.deviceToken,
    required this.name,
    required this.model,
    required this.observedAt,
    required this.receivedAt,
    this.online = false,
    this.state = 'unknown',
    this.taskName,
    this.progress,
    this.remainingMinutes,
    this.nozzleTemperature,
    this.bedTemperature,
    this.cameraUrl,
    this.archived = false,
  });
  final String printerKey, deviceToken, name, model, state;
  final String? taskName, cameraUrl;
  final DateTime observedAt, receivedAt;
  final bool online, archived;
  final int? progress, remainingMinutes;
  final double? nozzleTemperature, bedTemperature;

  bool isFresh(DateTime now) =>
      !archived &&
      online &&
      now.difference(observedAt).abs() < const Duration(minutes: 2) &&
      now.difference(receivedAt).abs() < const Duration(minutes: 2);

  factory PersonalDevice.fromJson(Map<String, dynamic> json) => PersonalDevice(
    printerKey: json['printerKey'] as String,
    deviceToken: json['deviceToken'] as String,
    name: json['name'] as String,
    model: json['model'] as String? ?? '',
    observedAt: DateTime.parse(json['observedAt'] as String),
    receivedAt: DateTime.parse(json['receivedAt'] as String),
    online: json['online'] == true,
    archived: json['archived'] == true,
    state: json['state'] as String? ?? 'unknown',
    taskName: json['taskName'] as String?,
    progress: (json['progress'] as num?)?.toInt(),
    remainingMinutes: (json['remainingMinutes'] as num?)?.toInt(),
    nozzleTemperature: (json['nozzleTemperature'] as num?)?.toDouble(),
    bedTemperature: (json['bedTemperature'] as num?)?.toDouble(),
    cameraUrl: json['cameraUrl'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'printerKey': printerKey,
    'deviceToken': deviceToken,
    'name': name,
    'model': model,
    'observedAt': observedAt.toUtc().toIso8601String(),
    'receivedAt': receivedAt.toUtc().toIso8601String(),
    'online': online,
    'state': state,
    'taskName': taskName,
    'progress': progress,
    'remainingMinutes': remainingMinutes,
    'nozzleTemperature': nozzleTemperature,
    'bedTemperature': bedTemperature,
    'cameraUrl': cameraUrl,
    'archived': archived,
  };
}

const deviceMaintenanceTypes = <String, String>{
  'inspection': '设备巡检',
  'cleaning': '清洁',
  'lubrication': '润滑',
  'belt': '皮带检查',
  'nozzle': '喷嘴更换',
  'hotend': '热端更换',
  'repair': '故障处理',
};

class DeviceMaintenanceRecord {
  const DeviceMaintenanceRecord({
    required this.eventId,
    required this.printerKey,
    required this.kind,
    required this.performedAt,
    required this.notes,
    this.nextDueAt,
    this.faultEventId,
    this.pending = false,
  });
  final String eventId, printerKey, kind, notes;
  final String? faultEventId;
  final DateTime performedAt;
  final DateTime? nextDueAt;
  final bool pending;
  String get label => deviceMaintenanceTypes[kind] ?? kind;
  factory DeviceMaintenanceRecord.fromJson(
    Map<String, dynamic> json, {
    bool pending = false,
  }) => DeviceMaintenanceRecord(
    eventId: json['eventId'] as String,
    printerKey: json['printerKey'] as String,
    kind: json['kind'] as String,
    notes: json['notes'] as String? ?? '',
    performedAt: DateTime.parse(json['performedAt'] as String),
    nextDueAt: DateTime.tryParse(json['nextDueAt'] as String? ?? ''),
    faultEventId: json['faultEventId'] as String?,
    pending: pending,
  );
  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'printerKey': printerKey,
    'kind': kind,
    'notes': notes,
    'performedAt': performedAt.toUtc().toIso8601String(),
    'nextDueAt': nextDueAt?.toUtc().toIso8601String(),
    'faultEventId': faultEventId,
  };
}

/// Only the latest maintenance record for a category sets its next reminder.
List<DeviceMaintenanceRecord> dueDeviceMaintenance(
  Iterable<DeviceMaintenanceRecord> records,
  DateTime now,
) {
  final latest = <String, DeviceMaintenanceRecord>{};
  for (final record in records) {
    final key = '${record.printerKey}|${record.kind}';
    final previous = latest[key];
    if (previous == null || record.performedAt.isAfter(previous.performedAt))
      latest[key] = record;
  }
  return latest.values
      .where((r) => r.nextDueAt != null && !r.nextDueAt!.isAfter(now))
      .toList();
}

class DeviceMaintenancePage {
  const DeviceMaintenancePage(this.records, this.cursor, this.hasMore);
  final List<DeviceMaintenanceRecord> records;
  final int cursor;
  final bool hasMore;
  factory DeviceMaintenancePage.fromJson(Map<String, dynamic> json) =>
      DeviceMaintenancePage(
        (json['records'] as List)
            .map(
              (e) =>
                  DeviceMaintenanceRecord.fromJson(e as Map<String, dynamic>),
            )
            .toList(),
        (json['cursor'] as num).toInt(),
        json['hasMore'] == true,
      );
}
