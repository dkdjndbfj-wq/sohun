import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';

import '../../data/database/database.dart';
import 'sensitive_data_sanitizer.dart';

/// 错误日志等级。
enum ErrorLevel {
  error('error'),
  warning('warning'),
  info('info');

  final String code;
  const ErrorLevel(this.code);
}

/// 错误日志条目（纯 Dart 模型，不走 drift 代码生成）。
class ErrorLogEntry {
  final int? id;
  final ErrorLevel level;
  final String source;
  final String message;
  final String? stackTrace;
  final Map<String, dynamic>? context;
  final DateTime createdAt;

  ErrorLogEntry({
    this.id,
    required this.level,
    required this.source,
    required this.message,
    this.stackTrace,
    this.context,
    required this.createdAt,
  });

  factory ErrorLogEntry.fromMap(Map<String, dynamic> map) {
    return ErrorLogEntry(
      id: map['id'] as int?,
      level: ErrorLevel.values.firstWhere(
        (l) => l.code == (map['level'] as String? ?? 'error'),
        orElse: () => ErrorLevel.error,
      ),
      source: map['source'] as String? ?? 'unknown',
      message: map['message'] as String? ?? '',
      stackTrace: map['stack_trace'] as String?,
      context: _parseContext(map['context'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        map['created_at'] as int? ?? 0,
      ),
    );
  }

  static Map<String, dynamic>? _parseContext(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return jsonDecode(json) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

class _ErrorFingerprintState {
  _ErrorFingerprintState(this.lastAcceptedAt);

  DateTime lastAcceptedAt;
  int suppressedOccurrences = 0;
}

/// 全局错误日志服务（单例）。
///
/// **核心能力**：
/// - [log]：异步写入错误日志（不阻塞调用方）
/// - [query]：查询近期日志（诊断中心用）
/// - [exportLogs]：导出日志包（用户报障用）
/// - [clearOldLogs]：清理超过 500 条的旧日志
///
/// **使用方式**：
/// ```dart
/// try {
///   await riskyOperation();
/// } catch (e, st) {
///   ErrorLogger.log(e, st, source: 'print_task', context: {'taskId': 123});
/// }
/// ```
///
/// **全局未捕获异常**：在 main.dart 中调用 [ErrorLogger.installGlobalHandler]
/// 自动捕获 Flutter framework 和 Dart isolate 的未处理异常。
class ErrorLogger {
  static const Duration _duplicateWindow = Duration(seconds: 30);
  static const int _maxFingerprints = 256;

  static AppDatabase? _db;
  static final List<ErrorLogEntry> _pendingLogs = [];
  static final Map<String, _ErrorFingerprintState> _fingerprints = {};
  static Future<void> _databaseWriteQueue = Future<void>.value();
  static bool _initialized = false;
  static void Function(ErrorLogEntry entry)? _entryObserver;

  static void setEntryObserver(void Function(ErrorLogEntry entry)? observer) {
    _entryObserver = observer;
  }

  /// Detaches global state between tests without waiting on the database queue.
  ///
  /// Test databases are closed during teardown, so retaining the singleton's
  /// database reference would let a late callback target a closed connection.
  static void detachForTesting() {
    _db = null;
    _initialized = false;
    _entryObserver = null;
    _pendingLogs.clear();
    _fingerprints.clear();
  }

  /// 初始化日志服务（在 app.dart runApp 之前调用）。
  static void init(AppDatabase db) {
    _db = db;
    _initialized = true;
    _fingerprints.clear();
    _flushPendingLogs();
    unawaited(clearOldLogs());
  }

  /// 安装全局未捕获异常处理器。
  ///
  /// 在 main.dart 中调用：
  /// ```dart
  /// ErrorLogger.init(database);
  /// ErrorLogger.installGlobalHandler();
  /// runApp(MyApp());
  /// ```
  static void installGlobalHandler() {
    // 捕获 Flutter framework 异常（如 widget build 失败）
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      log(
        details.exception,
        details.stack,
        source: 'flutter_framework',
        level: ErrorLevel.error,
        context: {
          'context': details.context?.toString() ?? '',
          'library': details.library ?? '',
        },
      );
    };

    // 捕获 Dart isolate 异步异常（如 Future 抛出未捕获异常）
    PlatformDispatcher.instance.onError = (error, stack) {
      log(
        error,
        stack,
        source: 'isolate',
        level: ErrorLevel.error,
      );
      return true;
    };
  }

  /// 异步记录错误日志（不阻塞调用方）。
  ///
  /// [source] 建议值：
  /// - `print_task`：打印任务相关（扣减/状态机/任务编排）
  /// - `ftp`：FTP 上传相关
  /// - `mqtt`：MQTT 连接/消息相关
  /// - `cloud_api`：拓竹云 API 相关
  /// - `gcode_parser`：G-code/3MF 解析相关
  /// - `database`：数据库操作相关
  /// - `flutter_framework`：Flutter framework 异常
  /// - `isolate`：Dart isolate 异步异常
  static void log(
    Object? error,
    StackTrace? stackTrace, {
    String source = 'unknown',
    ErrorLevel level = ErrorLevel.error,
    Map<String, dynamic>? context,
  }) {
    final rawMessage = error?.toString() ?? 'Unknown error';
    final message =
        rawMessage.length > 2000 ? rawMessage.substring(0, 2000) : rawMessage;
    final now = DateTime.now();
    final suppressedOccurrences = _admit(
      level: level,
      source: source,
      message: message,
      now: now,
    );
    if (suppressedOccurrences == null) return;

    final entryContext = suppressedOccurrences == 0
        ? context
        : <String, dynamic>{
            ...?context,
            'suppressedOccurrences': suppressedOccurrences,
          };
    final entry = ErrorLogEntry(
      level: level,
      source: source,
      message: message,
      stackTrace: stackTrace?.toString(),
      context: entryContext,
      createdAt: now,
    );

    if (kDebugMode) {
      debugPrint(
        '[ErrorLogger][${entry.level.code}][${entry.source}] ${entry.message}',
      );
    }

    try {
      _entryObserver?.call(entry);
    } catch (_) {
      // Observers are diagnostic-only and must never interrupt logging.
    }

    if (!_initialized || _db == null) {
      // 数据库尚未初始化，先缓存（最多 50 条）
      if (_pendingLogs.length < 50) {
        _pendingLogs.add(entry);
      }
      return;
    }

    _enqueueWrite(entry);
  }

  /// 查询近期日志（按时间倒序）。
  ///
  /// [limit] 默认 100，[sourceFilter] 可选按模块筛选。
  static Future<List<ErrorLogEntry>> query({
    int limit = 100,
    String? sourceFilter,
    ErrorLevel? levelFilter,
  }) async {
    if (_db == null) return [];
    await flushPendingWrites();

    final where = <String>[];
    final args = <dynamic>[];

    if (sourceFilter != null) {
      where.add('source = ?');
      args.add(sourceFilter);
    }
    if (levelFilter != null) {
      where.add('level = ?');
      args.add(levelFilter.code);
    }

    final whereClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final sql = '''
      SELECT id, level, source, message, stack_trace, context, created_at
      FROM error_logs
      $whereClause
      ORDER BY created_at DESC
      LIMIT ?
    ''';
    args.add(limit);

    final rows = await _db!
        .customSelect(
          sql,
          variables: args.map((a) {
            if (a is int) return Variable.withInt(a);
            if (a is String) return Variable.withString(a);
            return Variable.withString(a.toString());
          }).toList(),
        )
        .get();

    return rows.map((row) => ErrorLogEntry.fromMap(row.data)).toList();
  }

  /// 导出全部日志为文本（用于用户报障）。
  ///
  /// 任务书 11.3/11.5 要求：日志导出必须经过统一脱敏器。
  /// 返回格式化的日志文本，包含时间戳、等级、来源、消息、堆栈。
  static Future<String> exportLogs({int limit = 500}) async {
    final logs = await query(limit: limit);
    final buffer = StringBuffer();
    buffer.writeln('=== sohun 错误日志导出 ===');
    buffer.writeln('导出时间：${DateTime.now().toIso8601String()}');
    buffer.writeln('日志条数：${logs.length}');
    buffer.writeln('');

    for (final log in logs) {
      buffer.writeln('---');
      buffer.writeln('时间：${log.createdAt.toIso8601String()}');
      buffer.writeln('等级：${log.level.code}');
      buffer.writeln('来源：${log.source}');
      // 消息、上下文、堆栈统一脱敏后再写入导出文本
      final sanitizedMessage =
          SensitiveDataSanitizer.sanitize(log.message).text;
      buffer.writeln('消息：$sanitizedMessage');
      if (log.context != null) {
        final sanitizedContext =
            SensitiveDataSanitizer.sanitizeMap(log.context!);
        buffer.writeln('上下文：${jsonEncode(sanitizedContext)}');
      }
      if (log.stackTrace != null && log.stackTrace!.isNotEmpty) {
        final sanitizedStack =
            SensitiveDataSanitizer.sanitize(log.stackTrace!).text;
        buffer.writeln('堆栈：');
        buffer.writeln(sanitizedStack);
      }
    }

    return buffer.toString();
  }

  /// 生成完整诊断包（任务书 11.5）。
  ///
  /// 包含：应用版本、数据库 schema、功能开关状态、指标汇总、脱敏错误日志、生成时间。
  /// 所有文本字段统一经过 [SensitiveDataSanitizer] 二次扫描。
  static Future<String> exportDiagnosticsBundle({
    required String appVersion,
    required int databaseSchemaVersion,
    required Map<String, bool> featureFlags,
    required String telemetrySummary,
    required String productIssueSummary,
    int logLimit = 200,
  }) async {
    final buffer = StringBuffer();
    buffer.writeln('=== sohun 诊断包 ===');
    buffer.writeln('生成时间：${DateTime.now().toIso8601String()}');
    buffer.writeln('应用版本：$appVersion');
    buffer.writeln('数据库 schema：v$databaseSchemaVersion');
    buffer.writeln('');
    buffer.writeln('--- 功能开关 ---');
    final sortedFlags = featureFlags.keys.toList()..sort();
    for (final key in sortedFlags) {
      buffer.writeln('$key = ${featureFlags[key]}');
    }
    buffer.writeln('');
    buffer.writeln('--- 指标汇总 ---');
    final sanitizedTelemetry =
        SensitiveDataSanitizer.sanitize(telemetrySummary).text;
    buffer.writeln(sanitizedTelemetry);
    buffer.writeln('');
    buffer.writeln('--- 本地问题线索（最近 30 天） ---');
    final sanitizedIssues =
        SensitiveDataSanitizer.sanitize(productIssueSummary).text;
    buffer.writeln(sanitizedIssues);
    buffer.writeln('');
    buffer.writeln('--- 错误日志（已脱敏） ---');
    buffer.writeln(await exportLogs(limit: logLimit));
    buffer.writeln('');
    buffer.writeln('=== 诊断包结束 ===');

    // 最终再跑一次集中脱敏扫描，防止任何调用方传入敏感字段
    final raw = buffer.toString();
    return SensitiveDataSanitizer.sanitize(raw).text;
  }

  /// 清空所有日志（诊断中心"清空"按钮用）。
  static Future<void> clearAll() async {
    final database = _db;
    if (database == null) return;
    final deletion = _databaseWriteQueue.then(
      (_) => database.customStatement('DELETE FROM error_logs;'),
    );
    _databaseWriteQueue = deletion;
    await deletion;
  }

  /// 清理超过 500 条的旧日志（启动时自动调用）。
  static Future<void> clearOldLogs() async {
    final database = _db;
    if (database == null) return;
    final cleanup = _databaseWriteQueue.then((_) async {
      try {
        await database.customStatement('''
          DELETE FROM error_logs
          WHERE id NOT IN (
            SELECT id FROM error_logs
            ORDER BY created_at DESC
            LIMIT 500
          );
        ''');
      } catch (e) {
        debugPrint('[ErrorLogger] 清理旧日志失败: $e');
      }
    });
    _databaseWriteQueue = cleanup;
    await cleanup;
  }

  /// 获取错误统计（诊断中心顶部概览用）。
  ///
  /// 返回最近 7 天的 (errorCount, warningCount, infoCount)。
  static Future<({int error, int warning, int info})> getStats() async {
    if (_db == null) return (error: 0, warning: 0, info: 0);
    await flushPendingWrites();

    final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
    final sevenDaysAgoMs = sevenDaysAgo.millisecondsSinceEpoch;

    Future<int> countByLevel(String level) async {
      final result = await _db!.customSelect(
        'SELECT COUNT(*) as count FROM error_logs WHERE level = ? AND created_at >= ?',
        variables: [
          Variable.withString(level),
          Variable.withInt(sevenDaysAgoMs),
        ],
      ).getSingle();
      return result.read<int>('count');
    }

    return (
      error: await countByLevel(ErrorLevel.error.code),
      warning: await countByLevel(ErrorLevel.warning.code),
      info: await countByLevel(ErrorLevel.info.code),
    );
  }

  // ===== 内部实现 =====

  static Future<void> flushPendingWrites() async {
    final pending = _databaseWriteQueue;
    await pending;
  }

  static int? _admit({
    required ErrorLevel level,
    required String source,
    required String message,
    required DateTime now,
  }) {
    final fingerprint =
        '${level.code}\u0000$source\u0000${_normalizeMessage(message)}';
    final existing = _fingerprints[fingerprint];
    if (existing != null &&
        now.difference(existing.lastAcceptedAt) < _duplicateWindow) {
      existing.suppressedOccurrences += 1;
      return null;
    }

    final suppressed = existing?.suppressedOccurrences ?? 0;
    if (existing == null) {
      if (_fingerprints.length >= _maxFingerprints) {
        String? oldestKey;
        DateTime? oldestTime;
        for (final entry in _fingerprints.entries) {
          if (oldestTime == null ||
              entry.value.lastAcceptedAt.isBefore(oldestTime)) {
            oldestKey = entry.key;
            oldestTime = entry.value.lastAcceptedAt;
          }
        }
        if (oldestKey != null) _fingerprints.remove(oldestKey);
      }
      _fingerprints[fingerprint] = _ErrorFingerprintState(now);
    } else {
      existing
        ..lastAcceptedAt = now
        ..suppressedOccurrences = 0;
    }
    return suppressed;
  }

  static String _normalizeMessage(String message) {
    return message.replaceAll(
      RegExp(r'#[0-9a-fA-F]{4,}'),
      '#<render-object>',
    );
  }

  static void _enqueueWrite(ErrorLogEntry entry) {
    final database = _db;
    if (database == null) return;
    _databaseWriteQueue = _databaseWriteQueue.then(
      (_) => _writeToDb(database, entry),
    );
  }

  static Future<void> _writeToDb(
    AppDatabase database,
    ErrorLogEntry entry,
  ) async {
    try {
      final contextJson =
          entry.context != null ? jsonEncode(entry.context) : null;
      await database.customStatement(
        'INSERT INTO error_logs (level, source, message, stack_trace, context, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        [
          entry.level.code,
          entry.source,
          entry.message,
          entry.stackTrace,
          contextJson,
          entry.createdAt.millisecondsSinceEpoch,
        ],
      );
    } catch (e) {
      // 日志写入失败不能再抛异常，否则会无限循环
      debugPrint('[ErrorLogger] 写入失败: $e');
    }
  }

  static void _flushPendingLogs() {
    if (_db == null || _pendingLogs.isEmpty) return;
    final pending = List<ErrorLogEntry>.from(_pendingLogs);
    _pendingLogs.clear();
    for (final entry in pending) {
      _enqueueWrite(entry);
    }
  }
}
