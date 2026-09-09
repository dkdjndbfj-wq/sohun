import 'rfid_tag_identity.dart';

/// A safe, account-scoped event used to replicate the personal spool ledger.
///
/// The event deliberately contains no raw NFC blocks, keys, signatures,
/// printer credentials, or file paths.  Inventory rows answer the current
/// balance; events answer how that balance and RFID cycle came to be.
class PersonalInventoryEvent {
  const PersonalInventoryEvent({
    required this.eventUid,
    required this.inventoryUid,
    this.rfidTagUid,
    this.rfidTagCycle,
    required this.eventType,
    this.beforeGrams,
    this.afterGrams,
    this.deltaGrams,
    required this.occurredAt,
    this.source = 'local',
    this.note,
    this.printerUid,
    this.printerName,
    this.channelIndex,
    this.taskUid,
    this.isRemote = false,
  });

  final String eventUid;
  final String inventoryUid;
  final String? rfidTagUid;
  final int? rfidTagCycle;
  final String eventType;
  final double? beforeGrams;
  final double? afterGrams;
  final double? deltaGrams;
  final DateTime occurredAt;
  final String source;
  final String? note;
  final String? printerUid;
  final String? printerName;
  final int? channelIndex;
  final String? taskUid;

  /// True when this row came from another installation through cloud sync.
  /// It is local bookkeeping and is intentionally omitted from JSON.
  final bool isRemote;

  Map<String, dynamic> toJson() => {
    'eventUid': eventUid,
    'inventoryUid': inventoryUid,
    'rfidTagUid': rfidTagUid,
    'rfidTagCycle': rfidTagCycle,
    'eventType': eventType,
    'beforeGrams': beforeGrams,
    'afterGrams': afterGrams,
    'deltaGrams': deltaGrams,
    'occurredAt': DateTime.fromMillisecondsSinceEpoch(
      occurredAt.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String(),
    'source': source,
    'note': note,
    if (printerUid != null) 'printerUid': printerUid,
    if (printerName != null) 'printerName': printerName,
    if (channelIndex != null) 'channelIndex': channelIndex,
    if (taskUid != null) 'taskUid': taskUid,
  };

  factory PersonalInventoryEvent.fromJson(Map<String, dynamic> json) {
    final eventUid = _eventText(json['eventUid'], 'eventUid', 160);
    final inventoryUid = _eventText(json['inventoryUid'], 'inventoryUid', 128);
    final eventType = _eventText(json['eventType'], 'eventType', 48);
    final source = _eventText(json['source'] ?? 'remote', 'source', 32);
    if (!RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(eventType) ||
        !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(source)) {
      throw const FormatException('个人耗材事件类型或来源格式不正确');
    }
    final occurredAt = DateTime.tryParse('${json['occurredAt'] ?? ''}');
    if (occurredAt == null) {
      throw const FormatException('个人耗材事件 occurredAt 格式不正确');
    }
    final tagValue = json['rfidTagUid'];
    String? tagUid;
    if (tagValue != null) {
      if (tagValue is! String) {
        throw const FormatException('个人耗材事件 rfidTagUid 格式不正确');
      }
      final normalized = normalizeRfidTagUid(tagValue);
      tagUid = normalized.isEmpty ? null : normalized;
    }
    final cycle = _eventInt(json['rfidTagCycle'], 'rfidTagCycle');
    if (tagUid == null && cycle != null && cycle != 1) {
      throw const FormatException('没有 RFID 标签的事件不能使用非 1 周期');
    }
    return PersonalInventoryEvent(
      eventUid: eventUid,
      inventoryUid: inventoryUid,
      rfidTagUid: tagUid,
      rfidTagCycle: tagUid == null ? null : (cycle ?? 1),
      eventType: eventType,
      beforeGrams: _eventNumber(json['beforeGrams'], 'beforeGrams'),
      afterGrams: _eventNumber(json['afterGrams'], 'afterGrams'),
      deltaGrams: _eventNumber(json['deltaGrams'], 'deltaGrams'),
      occurredAt: occurredAt.toUtc(),
      source: source,
      note: _eventOptionalText(json['note'], 'note', 400),
      printerUid: _eventOptionalText(json['printerUid'], 'printerUid', 128),
      printerName: _eventOptionalText(json['printerName'], 'printerName', 80),
      channelIndex: _eventChannel(json['channelIndex']),
      taskUid: _eventOptionalText(json['taskUid'], 'taskUid', 128),
    );
  }

  PersonalInventoryEvent copyWith({
    String? eventUid,
    String? inventoryUid,
    String? rfidTagUid,
    int? rfidTagCycle,
    String? eventType,
    double? beforeGrams,
    double? afterGrams,
    double? deltaGrams,
    DateTime? occurredAt,
    String? source,
    String? note,
    bool? isRemote,
  }) {
    return PersonalInventoryEvent(
      eventUid: eventUid ?? this.eventUid,
      inventoryUid: inventoryUid ?? this.inventoryUid,
      rfidTagUid: rfidTagUid ?? this.rfidTagUid,
      rfidTagCycle: rfidTagCycle ?? this.rfidTagCycle,
      eventType: eventType ?? this.eventType,
      beforeGrams: beforeGrams ?? this.beforeGrams,
      afterGrams: afterGrams ?? this.afterGrams,
      deltaGrams: deltaGrams ?? this.deltaGrams,
      occurredAt: occurredAt ?? this.occurredAt,
      source: source ?? this.source,
      note: note ?? this.note,
      printerUid: printerUid,
      printerName: printerName,
      channelIndex: channelIndex,
      taskUid: taskUid,
      isRemote: isRemote ?? this.isRemote,
    );
  }
}

String _eventText(Object? value, String name, int max) {
  if (value is! String || value.trim().isEmpty || value.length > max) {
    throw FormatException('个人耗材事件 $name 格式不正确');
  }
  final text = value.trim();
  if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(text)) {
    throw FormatException('个人耗材事件 $name 包含不支持的字符');
  }
  return text;
}

String? _eventOptionalText(Object? value, String name, int max) {
  if (value == null) return null;
  if (value is String && value.trim().isEmpty) return null;
  return _eventText(value, name, max);
}

int? _eventChannel(Object? value) {
  if (value == null) return null;
  if (value is! num ||
      !value.isFinite ||
      value.toInt() != value ||
      value < 0 ||
      value > 65535) {
    throw const FormatException('个人耗材事件槽位格式不正确');
  }
  return value.toInt();
}

class PersonalInventoryEventPage {
  const PersonalInventoryEventPage({
    required this.events,
    required this.nextCursor,
    required this.hasMore,
  });
  final List<PersonalInventoryEvent> events;
  final int nextCursor;
  final bool hasMore;

  factory PersonalInventoryEventPage.fromJson(Map<String, dynamic> json) {
    final raw = json['events'];
    final cursor = json['nextCursor'];
    if (raw is! List ||
        raw.length > 200 ||
        cursor is! int ||
        cursor < 0 ||
        json['hasMore'] is! bool) {
      throw const FormatException('个人耗材账本分页格式不正确');
    }
    return PersonalInventoryEventPage(
      events: [
        for (final value in raw)
          if (value is Map)
            PersonalInventoryEvent.fromJson(Map<String, dynamic>.from(value))
          else
            throw const FormatException('个人耗材事件格式不正确'),
      ],
      nextCursor: cursor,
      hasMore: json['hasMore'] as bool,
    );
  }
}

double? _eventNumber(Object? value, String name) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < -100000 || value > 100000) {
    throw FormatException('个人耗材事件 $name 格式不正确');
  }
  return value.toDouble();
}

int? _eventInt(Object? value, String name) {
  if (value == null) return null;
  if (value is! num ||
      !value.isFinite ||
      value.toInt() != value ||
      value < 1 ||
      value > 1000000) {
    throw FormatException('个人耗材事件 $name 格式不正确');
  }
  return value.toInt();
}
