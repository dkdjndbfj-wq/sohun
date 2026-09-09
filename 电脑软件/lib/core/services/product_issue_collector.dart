import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/database/database.dart';
import '../app_version.dart';
import 'error_logger.dart';
import 'sensitive_data_sanitizer.dart';
import 'telemetry_service.dart';

enum ProductIssueCategory {
  crash('crash', '崩溃'),
  upgrade('upgrade', '升级'),
  deviceCompatibility('device_compatibility', '设备兼容'),
  firstUse('first_use', '首次使用');

  final String code;
  final String label;

  const ProductIssueCategory(this.code, this.label);
}

class ProductIssueSummary {
  final Map<ProductIssueCategory, int> counts;
  final Map<ProductIssueCategory, DateTime?> lastSeen;

  const ProductIssueSummary({
    required this.counts,
    required this.lastSeen,
  });

  factory ProductIssueSummary.empty() {
    return ProductIssueSummary(
      counts: {for (final category in ProductIssueCategory.values) category: 0},
      lastSeen: {
        for (final category in ProductIssueCategory.values) category: null,
      },
    );
  }

  int get total => counts.values.fold(0, (sum, count) => sum + count);
}

class _PendingIssue {
  final ProductIssueCategory category;
  final String outcome;
  final Map<String, dynamic> details;
  final ErrorLevel level;
  final int? durationMs;
  final DateTime recordedAt;

  const _PendingIssue({
    required this.category,
    required this.outcome,
    required this.details,
    required this.level,
    required this.durationMs,
    required this.recordedAt,
  });
}

class _CrashObservationState {
  _CrashObservationState(this.lastAcceptedAt);

  DateTime lastAcceptedAt;
  int suppressedOccurrences = 0;
}

/// Records bounded, sanitized product issue facts locally.
///
/// Raw device identifiers, network addresses, account details, paths and
/// credentials are never accepted by the per-category allowlists below.
class ProductIssueCollector {
  ProductIssueCollector._();

  static const _lastSeenAppVersionKey = 'product_issue_last_seen_app_version';
  static const _sessionActiveKey = 'product_issue_session_active';
  static const _sourcePrefix = 'product_issue.';
  static const _maxPending = 50;
  static const _crashObservationWindow = Duration(seconds: 30);

  static AppDatabase? _database;
  static TelemetryService? _telemetry;
  static final List<_PendingIssue> _pending = [];
  static final List<_PendingIssue> _telemetryBacklog = [];
  static final Map<String, _CrashObservationState> _crashObservations = {};
  static Future<void> _persistQueue = Future<void>.value();

  static const Map<ProductIssueCategory, Set<String>> _allowedDetailKeys = {
    ProductIssueCategory.crash: {
      'originSource',
      'originLibrary',
      'appVersion',
      'suppressedOccurrences',
    },
    ProductIssueCategory.upgrade: {
      'fromSchema',
      'toSchema',
      'backupCreated',
      'phase',
      'previousAppVersion',
      'currentAppVersion',
    },
    ProductIssueCategory.deviceCompatibility: {
      'connectionMode',
      'printerModel',
      'firmwareVersion',
      'studioVersion',
      'amsSummary',
      'errorCategory',
      'fallbackUsed',
    },
    ProductIssueCategory.firstUse: {
      'stepIndex',
      'visitedSteps',
      'cloudConnected',
      'printerCount',
      'slicerConfigured',
      'costConfigured',
      'action',
    },
  };

  static const Map<ProductIssueCategory, String> _telemetryEvents = {
    ProductIssueCategory.crash: 'app.crash',
    ProductIssueCategory.upgrade: 'app.upgrade',
    ProductIssueCategory.deviceCompatibility: 'printer.compatibility',
    ProductIssueCategory.firstUse: 'onboarding.flow',
  };

  static void init(AppDatabase database) {
    _database = database;
    _crashObservations.clear();
    ErrorLogger.setEntryObserver(_observeErrorEntry);
    final pending = List<_PendingIssue>.from(_pending);
    _pending.clear();
    for (final issue in pending) {
      unawaited(_enqueuePersist(issue));
    }
  }

  static void attachTelemetry(TelemetryService service) {
    _telemetry = service;
    final backlog = List<_PendingIssue>.from(_telemetryBacklog);
    _telemetryBacklog.clear();
    for (final issue in backlog) {
      unawaited(_recordTelemetry(issue));
    }
  }

  static void detachForTesting() {
    ErrorLogger.setEntryObserver(null);
    _database = null;
    _telemetry = null;
    _pending.clear();
    _telemetryBacklog.clear();
    _crashObservations.clear();
  }

  static Future<void> record({
    required ProductIssueCategory category,
    required String outcome,
    Map<String, dynamic> details = const {},
    ErrorLevel level = ErrorLevel.info,
    int? durationMs,
  }) async {
    final safeOutcome = _boundedString(
      SensitiveDataSanitizer.sanitize(outcome).text,
      fallback: 'unknown',
    );
    final issue = _PendingIssue(
      category: category,
      outcome: safeOutcome,
      details: _sanitizeDetails(category, details),
      level: level,
      durationMs: durationMs,
      recordedAt: DateTime.now(),
    );
    if (_database == null) {
      if (_pending.length < _maxPending) _pending.add(issue);
    } else {
      await _enqueuePersist(issue);
    }
    await _recordTelemetry(issue);
  }

  static void recordDetached({
    required ProductIssueCategory category,
    required String outcome,
    Map<String, dynamic> details = const {},
    ErrorLevel level = ErrorLevel.info,
    int? durationMs,
  }) {
    unawaited(
      record(
        category: category,
        outcome: outcome,
        details: details,
        level: level,
        durationMs: durationMs,
      ),
    );
  }

  static Future<void> recordVersionTransition() async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_lastSeenAppVersionKey);
    if (previous == AppVersion.fullVersion) return;
    await record(
      category: ProductIssueCategory.upgrade,
      outcome: previous == null ? 'first_seen' : 'app_version_changed',
      details: {
        'previousAppVersion': previous ?? 'none',
        'currentAppVersion': AppVersion.fullVersion,
        'phase': 'app_start',
      },
    );
    await prefs.setString(_lastSeenAppVersionKey, AppVersion.fullVersion);
  }

  /// Marks this process as active and reports an unclean previous shutdown.
  ///
  /// This provides a bounded clue for native crashes and forced termination,
  /// where Dart and Flutter exception handlers cannot produce a stack trace.
  static Future<void> startSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_sessionActiveKey) ?? false) {
      await record(
        category: ProductIssueCategory.crash,
        outcome: 'previous_session_ended_unexpectedly',
        level: ErrorLevel.error,
        details: {
          'originSource': 'session_guard',
          'originLibrary': 'process_lifecycle',
          'appVersion': AppVersion.fullVersion,
        },
      );
    }
    await prefs.setBool(_sessionActiveKey, true);
  }

  static Future<void> markCleanShutdown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_sessionActiveKey, false);
  }

  static String classifyConnectionError(String error) {
    final value = error.toLowerCase();
    if (value.contains('timeout') || value.contains('超时')) return 'timeout';
    if (value.contains('401') ||
        value.contains('403') ||
        value.contains('认证') ||
        value.contains('鉴权')) {
      return 'authentication';
    }
    if (value.contains('certificate') ||
        value.contains('tls') ||
        value.contains('证书')) {
      return 'certificate';
    }
    if (value.contains('protocol') || value.contains('协议')) return 'protocol';
    if (value.contains('network') ||
        value.contains('socket') ||
        value.contains('网络')) {
      return 'network';
    }
    return 'unknown';
  }

  static Future<ProductIssueSummary> loadSummary({
    Duration window = const Duration(days: 30),
  }) async {
    final database = _database;
    if (database == null) return ProductIssueSummary.empty();
    await ErrorLogger.flushPendingWrites();
    await flushPendingWrites();
    final cutoff = DateTime.now().subtract(window).millisecondsSinceEpoch;
    final rows = await database.customSelect(
      '''
      SELECT source, COUNT(*) AS issue_count, MAX(created_at) AS last_seen
      FROM error_logs
      WHERE source LIKE ? AND created_at >= ?
      GROUP BY source
      ''',
      variables: [
        Variable.withString('$_sourcePrefix%'),
        Variable.withInt(cutoff),
      ],
    ).get();
    final Map<ProductIssueCategory, int> counts = {
      for (final category in ProductIssueCategory.values) category: 0,
    };
    final Map<ProductIssueCategory, DateTime?> lastSeen = {
      for (final category in ProductIssueCategory.values) category: null,
    };
    for (final row in rows) {
      final source = row.read<String>('source');
      for (final category in ProductIssueCategory.values) {
        if (source == '$_sourcePrefix${category.code}') {
          counts[category] = row.read<int?>('issue_count') ?? 0;
          final millis = row.read<int?>('last_seen');
          lastSeen[category] = millis == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(millis);
        }
      }
    }
    return ProductIssueSummary(counts: counts, lastSeen: lastSeen);
  }

  static Future<String> exportSummary() async {
    final summary = await loadSummary();
    final buffer = StringBuffer('最近 30 天本地问题线索：\n');
    for (final category in ProductIssueCategory.values) {
      final lastSeen = summary.lastSeen[category];
      buffer.writeln(
        '- ${category.label}: ${summary.counts[category] ?? 0} 条，'
        '最近 ${lastSeen?.toUtc().toIso8601String() ?? '-'}',
      );
    }
    return buffer.toString();
  }

  static void _observeErrorEntry(ErrorLogEntry entry) {
    if (entry.source.startsWith(_sourcePrefix)) return;
    if (entry.level != ErrorLevel.error) return;
    if (entry.source != 'flutter_framework' && entry.source != 'isolate') {
      return;
    }
    final now = DateTime.now();
    final observation = _crashObservations[entry.source];
    if (observation != null &&
        now.difference(observation.lastAcceptedAt) < _crashObservationWindow) {
      observation.suppressedOccurrences += 1;
      return;
    }
    final locallySuppressed = observation?.suppressedOccurrences ?? 0;
    if (observation == null) {
      _crashObservations[entry.source] = _CrashObservationState(now);
    } else {
      observation
        ..lastAcceptedAt = now
        ..suppressedOccurrences = 0;
    }
    final loggerSuppressed = entry.context?['suppressedOccurrences'];
    final suppressedOccurrences =
        locallySuppressed + (loggerSuppressed is int ? loggerSuppressed : 0);
    recordDetached(
      category: ProductIssueCategory.crash,
      outcome: 'unhandled_error',
      level: ErrorLevel.error,
      details: {
        'originSource': entry.source,
        'originLibrary': entry.context?['library'] ?? 'unknown',
        'appVersion': AppVersion.fullVersion,
        if (suppressedOccurrences > 0)
          'suppressedOccurrences': suppressedOccurrences,
      },
    );
  }

  static Future<void> flushPendingWrites() async {
    await _persistQueue;
  }

  static Future<void> _enqueuePersist(_PendingIssue issue) {
    final database = _database;
    if (database == null) return Future<void>.value();
    final write = _persistQueue.then((_) => _persist(database, issue));
    _persistQueue = write;
    return write;
  }

  static Future<void> _persist(
    AppDatabase database,
    _PendingIssue issue,
  ) async {
    try {
      await database.customStatement(
        'INSERT INTO error_logs '
        '(level, source, message, stack_trace, context, created_at) '
        'VALUES (?, ?, ?, NULL, ?, ?)',
        [
          issue.level.code,
          '$_sourcePrefix${issue.category.code}',
          issue.outcome,
          jsonEncode({
            'outcome': issue.outcome,
            ...issue.details,
            if (issue.durationMs != null) 'durationMs': issue.durationMs,
          }),
          issue.recordedAt.millisecondsSinceEpoch,
        ],
      );
    } catch (_) {
      // Issue collection must never break the product flow.
    }
  }

  static Future<void> _recordTelemetry(_PendingIssue issue) async {
    final telemetry = _telemetry;
    if (telemetry == null) {
      if (_telemetryBacklog.length < _maxPending) {
        _telemetryBacklog.add(issue);
      }
      return;
    }
    await telemetry.recordEvent(
      eventName: _telemetryEvents[issue.category]!,
      resultCategory: issue.outcome,
      durationMs: issue.durationMs,
      attributes: issue.details,
    );
  }

  static Map<String, dynamic> _sanitizeDetails(
    ProductIssueCategory category,
    Map<String, dynamic> details,
  ) {
    final allowed = _allowedDetailKeys[category] ?? const <String>{};
    final filtered = <String, dynamic>{};
    for (final entry in details.entries) {
      if (!allowed.contains(entry.key)) continue;
      final value = entry.value;
      if (value is bool || value is num) {
        filtered[entry.key] = value;
      } else if (value != null) {
        filtered[entry.key] = _boundedString(value.toString());
      }
    }
    return SensitiveDataSanitizer.sanitizeMap(filtered);
  }

  static String _boundedString(String value, {String fallback = 'unknown'}) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return fallback;
    return trimmed.length > 120 ? trimmed.substring(0, 120) : trimmed;
  }
}
