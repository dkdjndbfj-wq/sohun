/// Account sync payload. Printer LAN addresses, access codes and full serials
/// are intentionally excluded. printerKey is an opaque local hash.
class PrinterFaultRecord {
  final String eventId, printerKey, printerName, model, code, kind;
  final String severity, title, message, source;
  final String? sourceVersion, helpUrl;
  final DateTime firstSeenAt, lastSeenAt;
  final DateTime? clearedAt, readAt;
  const PrinterFaultRecord({
    required this.eventId,
    required this.printerKey,
    required this.printerName,
    required this.model,
    required this.code,
    required this.kind,
    required this.severity,
    required this.title,
    required this.message,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.clearedAt,
    this.readAt,
    this.source = 'device-report',
    this.sourceVersion,
    this.helpUrl,
  });

  bool get active => clearedAt == null;
  bool get needsAttention => active && readAt == null && severity != 'info';

  Map<String, dynamic> toJson() => {
    'eventId': eventId,
    'printerKey': printerKey,
    'printerName': printerName,
    'model': model,
    'code': code,
    'kind': kind,
    'severity': severity,
    'title': title,
    'message': message,
    'source': source,
    'sourceVersion': sourceVersion,
    'helpUrl': helpUrl,
    'firstSeenAt': firstSeenAt.toUtc().toIso8601String(),
    'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
    'clearedAt': clearedAt?.toUtc().toIso8601String(),
    'readAt': readAt?.toUtc().toIso8601String(),
  };
  factory PrinterFaultRecord.fromJson(Map<String, dynamic> json) =>
      PrinterFaultRecord(
        eventId: json['eventId'] as String,
        printerKey: json['printerKey'] as String,
        printerName: json['printerName'] as String,
        model: json['model'] as String? ?? '',
        code: json['code'] as String,
        kind: json['kind'] as String,
        severity: json['severity'] as String,
        title: json['title'] as String,
        message: json['message'] as String,
        source: json['source'] as String? ?? 'device-report',
        sourceVersion: json['sourceVersion'] as String?,
        helpUrl: json['helpUrl'] as String?,
        firstSeenAt: DateTime.parse(json['firstSeenAt'] as String),
        lastSeenAt: DateTime.parse(json['lastSeenAt'] as String),
        clearedAt: DateTime.tryParse(json['clearedAt'] as String? ?? ''),
        readAt: DateTime.tryParse(json['readAt'] as String? ?? ''),
      );
  PrinterFaultRecord copyWith({
    DateTime? lastSeenAt,
    DateTime? clearedAt,
    DateTime? readAt,
  }) => PrinterFaultRecord.fromJson({
    ...toJson(),
    if (lastSeenAt != null) 'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
    if (clearedAt != null) 'clearedAt': clearedAt.toUtc().toIso8601String(),
    if (readAt != null) 'readAt': readAt.toUtc().toIso8601String(),
  });
}

class PrinterFaultPage {
  final List<PrinterFaultRecord> events;
  final int cursor;
  final bool hasMore;
  const PrinterFaultPage({
    required this.events,
    required this.cursor,
    required this.hasMore,
  });
  factory PrinterFaultPage.fromJson(Map<String, dynamic> json) =>
      PrinterFaultPage(
        events: (json['events'] as List)
            .map((e) => PrinterFaultRecord.fromJson(e as Map<String, dynamic>))
            .toList(),
        cursor: json['cursor'] as int,
        hasMore: json['hasMore'] as bool? ?? false,
      );
}
