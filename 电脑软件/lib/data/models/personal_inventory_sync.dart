import 'rfid_tag_identity.dart';
import 'personal_inventory_event.dart';
import 'rfid_tag_history.dart';

/// The account-scoped inventory contract shared by the desktop and Android
/// clients. It deliberately contains inventory metadata only: raw RFID dumps,
/// sector keys, signatures, and card credentials never enter this contract.
class PersonalInventoryRecord {
  const PersonalInventoryRecord({
    required this.uid,
    required this.manufacturer,
    required this.model,
    required this.materialType,
    required this.colorHex,
    this.colorName,
    required this.totalGrams,
    required this.remainingGrams,
    this.batchNo,
    this.purchaseDate,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    this.density,
    this.recommendedNozzleTemp,
    this.hygroscopicity,
    this.trayUuid,
    this.rfidSyncedAt,
    this.rfidTagUid,
    this.rfidTagType,
    this.rfidTagCycle = 1,
    this.lifecycleStatus = 'active',
    this.previousConsumableUid,
    this.rfidTagHistory = const [],
    this.sourceRfidTagUid,
    this.sourceRfidTagType,
    this.stockReceiptUid,
    this.stockReceiptIndex,
    this.stockReceiptQuantity,
  });

  final String uid;
  final String manufacturer;
  final String model;
  final String materialType;
  final String colorHex;
  final String? colorName;
  final double totalGrams;
  final double remainingGrams;
  final String? batchNo;
  final DateTime? purchaseDate;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double? density;
  final double? recommendedNozzleTemp;
  final String? hygroscopicity;
  final String? trayUuid;
  final int? rfidSyncedAt;

  /// Stable physical CUID/FUID identity. It is intentionally separate from
  /// [uid], which identifies one spool instance and is always unique.
  final String? rfidTagUid;
  final String? rfidTagType;
  final int rfidTagCycle;
  final String lifecycleStatus;
  final String? previousConsumableUid;
  final List<RfidTagHistoryEntry> rfidTagHistory;

  /// Reusable material card used to receive this stock. Many independent
  /// spools can share this source; it never identifies the spool in an AMS.
  final String? sourceRfidTagUid;
  final String? sourceRfidTagType;
  final String? stockReceiptUid;
  final int? stockReceiptIndex;
  final int? stockReceiptQuantity;

  factory PersonalInventoryRecord.fromJson(Map<String, dynamic> json) {
    final remainingGrams = _requiredFinite(json, 'remainingGrams');
    final lifecycleStatus =
        _optionalText(json, 'lifecycleStatus') ??
        (remainingGrams <= 0 ? 'depleted' : 'active');
    return PersonalInventoryRecord(
      uid: _requiredText(json, 'uid'),
      manufacturer: _requiredText(json, 'manufacturer'),
      model: _requiredText(json, 'model'),
      materialType: _requiredText(json, 'materialType'),
      colorHex: _requiredText(json, 'colorHex'),
      colorName: _optionalText(json, 'colorName'),
      totalGrams: _requiredFinite(json, 'totalGrams'),
      remainingGrams: remainingGrams,
      batchNo: _optionalText(json, 'batchNo'),
      purchaseDate: _optionalDate(json, 'purchaseDate'),
      note: _optionalText(json, 'note'),
      createdAt: _requiredDate(json, 'createdAt'),
      updatedAt: _requiredDate(json, 'updatedAt'),
      density: _optionalFinite(json, 'density'),
      recommendedNozzleTemp: _optionalFinite(json, 'recommendedNozzleTemp'),
      hygroscopicity: _optionalText(json, 'hygroscopicity'),
      trayUuid: _optionalText(json, 'trayUuid'),
      rfidSyncedAt: _optionalInt(json, 'rfidSyncedAt'),
      // Android readers commonly return `04:aa:bb:cc`, while the desktop
      // reader returns `04AABBCC`.  Normalize at the model boundary so a
      // server round-trip cannot create a second physical-tag identity.
      rfidTagUid: _optionalRfidTag(json, 'rfidTagUid'),
      rfidTagType: _optionalText(json, 'rfidTagType'),
      rfidTagCycle: _optionalInt(json, 'rfidTagCycle') ?? 1,
      lifecycleStatus: lifecycleStatus,
      previousConsumableUid: _optionalText(json, 'previousConsumableUid'),
      rfidTagHistory: RfidTagHistoryEntry.parseList(json['rfidTagHistory']),
      sourceRfidTagUid: _optionalRfidTag(json, 'sourceRfidTagUid'),
      sourceRfidTagType: _optionalText(json, 'sourceRfidTagType'),
      stockReceiptUid: _optionalText(json, 'stockReceiptUid'),
      stockReceiptIndex: _optionalInt(json, 'stockReceiptIndex'),
      stockReceiptQuantity: _optionalInt(json, 'stockReceiptQuantity'),
    );
  }

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'manufacturer': manufacturer,
    'model': model,
    'materialType': materialType,
    'colorHex': colorHex,
    'colorName': colorName,
    'totalGrams': totalGrams,
    'remainingGrams': remainingGrams,
    'batchNo': batchNo,
    'purchaseDate': purchaseDate?.toUtc().toIso8601String(),
    'note': note,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'density': density,
    'recommendedNozzleTemp': recommendedNozzleTemp,
    'hygroscopicity': hygroscopicity,
    'trayUuid': trayUuid,
    'rfidSyncedAt': rfidSyncedAt,
    'rfidTagUid': rfidTagUid,
    'rfidTagType': rfidTagType,
    'rfidTagCycle': rfidTagCycle,
    'lifecycleStatus': lifecycleStatus,
    'previousConsumableUid': previousConsumableUid,
    if (rfidTagHistory.isNotEmpty)
      'rfidTagHistory': rfidTagHistory.map((entry) => entry.toJson()).toList(),
    if (stockReceiptUid != null || sourceRfidTagUid != null) ...{
      'sourceRfidTagUid': sourceRfidTagUid,
      'sourceRfidTagType': sourceRfidTagType,
      'stockReceiptUid': stockReceiptUid,
      'stockReceiptIndex': stockReceiptIndex,
      'stockReceiptQuantity': stockReceiptQuantity,
    },
  };

  PersonalInventoryRecord copyWith({
    String? uid,
    String? manufacturer,
    String? model,
    String? materialType,
    String? colorHex,
    String? colorName,
    double? totalGrams,
    double? remainingGrams,
    String? batchNo,
    DateTime? purchaseDate,
    String? note,
    DateTime? createdAt,
    DateTime? updatedAt,
    double? density,
    double? recommendedNozzleTemp,
    String? hygroscopicity,
    String? trayUuid,
    int? rfidSyncedAt,
    String? rfidTagUid,
    String? rfidTagType,
    int? rfidTagCycle,
    String? lifecycleStatus,
    String? previousConsumableUid,
    List<RfidTagHistoryEntry>? rfidTagHistory,
    String? sourceRfidTagUid,
    String? sourceRfidTagType,
    String? stockReceiptUid,
    int? stockReceiptIndex,
    int? stockReceiptQuantity,
  }) {
    return PersonalInventoryRecord(
      uid: uid ?? this.uid,
      manufacturer: manufacturer ?? this.manufacturer,
      model: model ?? this.model,
      materialType: materialType ?? this.materialType,
      colorHex: colorHex ?? this.colorHex,
      colorName: colorName ?? this.colorName,
      totalGrams: totalGrams ?? this.totalGrams,
      remainingGrams: remainingGrams ?? this.remainingGrams,
      batchNo: batchNo ?? this.batchNo,
      purchaseDate: purchaseDate ?? this.purchaseDate,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      density: density ?? this.density,
      recommendedNozzleTemp:
          recommendedNozzleTemp ?? this.recommendedNozzleTemp,
      hygroscopicity: hygroscopicity ?? this.hygroscopicity,
      trayUuid: trayUuid ?? this.trayUuid,
      rfidSyncedAt: rfidSyncedAt ?? this.rfidSyncedAt,
      rfidTagUid: rfidTagUid ?? this.rfidTagUid,
      rfidTagType: rfidTagType ?? this.rfidTagType,
      rfidTagCycle: rfidTagCycle ?? this.rfidTagCycle,
      lifecycleStatus: lifecycleStatus ?? this.lifecycleStatus,
      previousConsumableUid:
          previousConsumableUid ?? this.previousConsumableUid,
      rfidTagHistory: rfidTagHistory ?? this.rfidTagHistory,
      sourceRfidTagUid: sourceRfidTagUid ?? this.sourceRfidTagUid,
      sourceRfidTagType: sourceRfidTagType ?? this.sourceRfidTagType,
      stockReceiptUid: stockReceiptUid ?? this.stockReceiptUid,
      stockReceiptIndex: stockReceiptIndex ?? this.stockReceiptIndex,
      stockReceiptQuantity: stockReceiptQuantity ?? this.stockReceiptQuantity,
    );
  }
}

String? _optionalRfidTag(Map<String, dynamic> json, String key) {
  final value = _optionalText(json, key);
  if (value == null) return null;
  final normalized = normalizeRfidTagUid(value);
  return normalized.isEmpty ? null : normalized;
}

class PersonalInventorySnapshot {
  const PersonalInventorySnapshot({
    required this.revision,
    required this.records,
    this.materialCatalog = const [],
    this.deletedUids = const {},
    this.events = const [],
    this.eventSyncVersion = 0,
    this.updatedAt,
  });

  final int revision;
  final List<PersonalInventoryRecord> records;
  final List<String> materialCatalog;

  /// Stable UID -> deletion timestamp. Tombstones prevent a deliberate local
  /// delete from being resurrected by a stale copy on another device.
  final Map<String, DateTime> deletedUids;

  /// Immutable NFC, replacement, twin, and consumption events. The list is
  /// merged by eventUid; omitting an old event from a PUT never deletes it.
  final List<PersonalInventoryEvent> events;

  /// Version 1 uses a separate append-only, cursor-paged event endpoint.
  final int eventSyncVersion;
  final DateTime? updatedAt;

  factory PersonalInventorySnapshot.fromJson(Map<String, dynamic> json) {
    final rawRecords = json['records'];
    if (rawRecords is! List) {
      throw const FormatException('个人库存同步响应缺少 records 列表');
    }
    final records = <PersonalInventoryRecord>[];
    for (final item in rawRecords) {
      if (item is! Map) {
        throw const FormatException('个人库存记录格式不正确');
      }
      records.add(
        PersonalInventoryRecord.fromJson(Map<String, dynamic>.from(item)),
      );
    }
    return PersonalInventorySnapshot(
      revision: _requiredInt(json, 'revision'),
      records: List.unmodifiable(records),
      materialCatalog: _optionalStringList(json, 'materialCatalog'),
      deletedUids: _optionalDeletedUids(json['deletedUids']),
      events: _optionalEvents(json['events']),
      eventSyncVersion: _optionalInt(json, 'eventSyncVersion') ?? 0,
      updatedAt: _optionalDate(json, 'updatedAt'),
    );
  }

  Map<String, dynamic> toPutJson() => {
    'revision': revision,
    'records': records.map((record) => record.toJson()).toList(),
    'materialCatalog': materialCatalog,
    'deletedUids': {
      for (final entry in deletedUids.entries)
        entry.key: entry.value.toUtc().toIso8601String(),
    },
    'events': events.map((event) => event.toJson()).toList(),
  };
}

List<PersonalInventoryEvent> _optionalEvents(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('events格式不正确');
  if (value.length > 10000) {
    throw const FormatException('events数量超出限制');
  }
  final result = <PersonalInventoryEvent>[];
  final seen = <String>{};
  for (final item in value) {
    if (item is! Map) throw const FormatException('events格式不正确');
    final event = PersonalInventoryEvent.fromJson(
      Map<String, dynamic>.from(item),
    );
    if (!seen.add(event.eventUid.toLowerCase())) {
      throw const FormatException('events中存在重复eventUid');
    }
    result.add(event);
  }
  result.sort((a, b) {
    final time = a.occurredAt.compareTo(b.occurredAt);
    return time != 0 ? time : a.eventUid.compareTo(b.eventUid);
  });
  return List.unmodifiable(result);
}

String _requiredText(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('个人库存记录缺少 $key');
  }
  return value.trim();
}

String? _optionalText(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('个人库存记录 $key 格式不正确');
  final result = value.trim();
  return result.isEmpty ? null : result;
}

double _requiredFinite(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite) {
    throw FormatException('个人库存记录 $key 格式不正确');
  }
  return value.toDouble();
}

double? _optionalFinite(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num || !value.isFinite) {
    throw FormatException('个人库存记录 $key 格式不正确');
  }
  return value.toDouble();
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value) {
    throw FormatException('个人库存记录 $key 格式不正确');
  }
  return value.toInt();
}

int? _optionalInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num || value.toInt() != value) {
    throw FormatException('个人库存记录 $key 格式不正确');
  }
  return value.toInt();
}

List<String> _optionalStringList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List) throw FormatException('个人库存记录 $key 格式不正确');
  final values = <String>{};
  for (final item in value) {
    if (item is! String) {
      throw FormatException('个人库存记录 $key 格式不正确');
    }
    final normalized = item.trim();
    if (normalized.isNotEmpty) values.add(normalized);
  }
  final result = values.toList(growable: false);
  result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return List.unmodifiable(result);
}

Map<String, DateTime> _optionalDeletedUids(Object? value) {
  if (value == null) return const {};
  if (value is! Map) throw const FormatException('deletedUids格式不正确');
  if (value.length > 2000) {
    throw const FormatException('deletedUids数量超出限制');
  }
  final result = <String, DateTime>{};
  final seen = <String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || (entry.key as String).trim().isEmpty) {
      throw const FormatException('deletedUids格式不正确');
    }
    final uid = (entry.key as String).trim();
    if (!seen.add(uid.toLowerCase())) {
      throw const FormatException('deletedUids中存在重复uid');
    }
    if (entry.value is! String) throw const FormatException('deletedUids格式不正确');
    final parsed = DateTime.tryParse(entry.value as String);
    if (parsed == null) throw const FormatException('deletedUids时间格式不正确');
    result[uid] = parsed.toUtc();
  }
  return Map.unmodifiable(result);
}

DateTime _requiredDate(Map<String, dynamic> json, String key) {
  final value = _optionalDate(json, key);
  if (value == null) throw FormatException('个人库存记录缺少 $key');
  return value;
}

DateTime? _optionalDate(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('个人库存记录 $key 格式不正确');
  return DateTime.tryParse(value)?.toLocal();
}
