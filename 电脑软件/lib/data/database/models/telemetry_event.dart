// 遥测事件模型。
//
// 用于记录可上传至社区服务器的指标事件（崩溃、同步、HTTP、打印机连接等）。
// 写入 telemetry_events 表（见 lib/data/database/database.dart 的
// _createTelemetryEventsTable，schema v19 / kSchemaVersion=21）。
//
// 上传状态机：
// - pending：待上传（默认）
// - synced：已成功上传
// - failed：上传永久失败（例如 401/403，不再自动重试）
//
// 字段与 telemetry_events 表的列保持一致，事实来源为 database.dart 的 raw SQL。

import 'dart:convert';

/// 遥测事件上传状态。
enum TelemetryUploadStatus {
  pending('pending'),
  synced('synced'),
  failed('failed');

  final String code;
  const TelemetryUploadStatus(this.code);

  static TelemetryUploadStatus fromCode(String code) {
    for (final s in TelemetryUploadStatus.values) {
      if (s.code == code) return s;
    }
    return TelemetryUploadStatus.pending;
  }
}

/// 遥测事件记录。
///
/// 一次 [TelemetryEvent] 对应一条可上传的指标事件。通过
/// [TelemetryEventDao.insert] 写入数据库，由 [TelemetryService]
/// 协调聚合、上传、清理。
class TelemetryEvent {
  /// 主键（UUID v4）。INSERT OR IGNORE 幂等键。
  final String id;

  /// 业务幂等键（UUID v4）。同一事件唯一标识，防止重复入库。
  final String eventUid;

  /// 事件名（必须命中服务端白名单，详见 TelemetryService.kEventWhitelist）。
  final String eventName;

  /// 结果分类（可选，有限枚举标签，禁止包含敏感信息）。
  /// 例如：success / failure / timeout / connection_lost。
  final String? resultCategory;

  /// 耗时（毫秒，可选）。
  final int? durationMs;

  /// 事件属性（已脱敏）。写入时序列化为 JSON 字符串。
  final Map<String, dynamic> attributes;

  /// 事件记录时间。
  final DateTime recordedAt;

  /// 上传状态。
  final TelemetryUploadStatus uploadStatus;

  /// 上传尝试次数。
  final int attemptCount;

  /// 下次重试时间（仅 pending + 网络错误退避时设置）。
  final DateTime? nextRetryAt;

  const TelemetryEvent({
    required this.id,
    required this.eventUid,
    required this.eventName,
    this.resultCategory,
    this.durationMs,
    required this.attributes,
    required this.recordedAt,
    this.uploadStatus = TelemetryUploadStatus.pending,
    this.attemptCount = 0,
    this.nextRetryAt,
  });

  TelemetryEvent copyWith({
    String? id,
    String? eventUid,
    String? eventName,
    String? resultCategory,
    int? durationMs,
    Map<String, dynamic>? attributes,
    DateTime? recordedAt,
    TelemetryUploadStatus? uploadStatus,
    int? attemptCount,
    DateTime? nextRetryAt,
  }) {
    return TelemetryEvent(
      id: id ?? this.id,
      eventUid: eventUid ?? this.eventUid,
      eventName: eventName ?? this.eventName,
      resultCategory: resultCategory ?? this.resultCategory,
      durationMs: durationMs ?? this.durationMs,
      attributes: attributes ?? this.attributes,
      recordedAt: recordedAt ?? this.recordedAt,
      uploadStatus: uploadStatus ?? this.uploadStatus,
      attemptCount: attemptCount ?? this.attemptCount,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
    );
  }

  /// 从 SQLite 行映射（列名与 telemetry_events 表一致）。
  factory TelemetryEvent.fromMap(Map<String, dynamic> map) {
    final rawAttributes = map['attributes'] as String?;
    Map<String, dynamic> attributes = const {};
    if (rawAttributes != null && rawAttributes.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawAttributes);
        if (decoded is Map) {
          attributes = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        // 损坏的 JSON 容错为空 map，避免单条坏数据阻塞整个批次
        attributes = const {};
      }
    }

    final recordedMs = map['recorded_at'] as int;
    final nextRetryMs = map['next_retry_at'] as int?;

    return TelemetryEvent(
      id: map['id'] as String,
      eventUid: map['event_uid'] as String,
      eventName: map['event_name'] as String,
      resultCategory: map['result_category'] as String?,
      durationMs: map['duration_ms'] as int?,
      attributes: attributes,
      recordedAt: DateTime.fromMillisecondsSinceEpoch(recordedMs),
      uploadStatus: TelemetryUploadStatus.fromCode(
        map['upload_status'] as String? ?? 'pending',
      ),
      attemptCount: map['attempt_count'] as int? ?? 0,
      nextRetryAt: nextRetryMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(nextRetryMs),
    );
  }

  /// 序列化为 SQLite 行（列名与 telemetry_events 表一致）。
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'event_uid': eventUid,
      'event_name': eventName,
      'result_category': resultCategory,
      'duration_ms': durationMs,
      'attributes': jsonEncode(attributes),
      'recorded_at': recordedAt.millisecondsSinceEpoch,
      'upload_status': uploadStatus.code,
      'attempt_count': attemptCount,
      'next_retry_at': nextRetryAt?.millisecondsSinceEpoch,
    };
  }

  /// 构造上传至社区服务器的 payload（用于 CommunityTelemetryApi.submitTelemetryBatch）。
  ///
  /// 字段命名与 server API 契约一致（camelCase）。attributes 已在写入前
  /// 经过 SensitiveDataSanitizer 脱敏，这里直接透传。
  Map<String, dynamic> toUploadPayload() {
    return {
      'eventId': id,
      'eventUid': eventUid,
      'eventName': eventName,
      if (resultCategory != null) 'resultCategory': resultCategory,
      if (durationMs != null) 'durationMs': durationMs,
      'attributes': attributes,
      'recordedAt': recordedAt.toUtc().toIso8601String(),
    };
  }

  @override
  String toString() =>
      'TelemetryEvent($eventName, $resultCategory, status=${uploadStatus.code}, '
      'attempts=$attemptCount, recordedAt=$recordedAt)';
}

/// 遥测事件聚合行（运行指标页签用）。
///
/// 由 [TelemetryEventDao.aggregateByEvent] 返回，每个 (eventName, resultCategory)
/// 组合对应一条记录。
class TelemetryAggregateRow {
  /// 事件名（白名单内）。
  final String eventName;

  /// 结果类别（空字符串表示未分类）。
  final String resultCategory;

  /// 聚合窗口内的事件总次数。
  final int count;

  /// 平均耗时（毫秒，可为 null 表示事件无 duration 字段）。
  final int? avgDurationMs;

  /// 最近一次发生时间。
  final DateTime lastRecordedAt;

  const TelemetryAggregateRow({
    required this.eventName,
    required this.resultCategory,
    required this.count,
    required this.avgDurationMs,
    required this.lastRecordedAt,
  });

  @override
  String toString() =>
      'TelemetryAggregateRow($eventName|$resultCategory, count=$count, '
      'avg=${avgDurationMs}ms, last=$lastRecordedAt)';
}
