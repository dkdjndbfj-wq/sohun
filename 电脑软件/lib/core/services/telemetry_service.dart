// 遥测服务。
//
// 任务书 11（Phase F-1）要求：
// - 白名单事件采集（app.crash / sync.* / http.* / printer.connection / remote_config.fetch）
// - 高频事件内存聚合，按 60s 周期落库（避免每个 MQTT 包写一次 DB）
// - 5 分钟周期上传至社区服务器（可选，未配置服务器时仅本地存储）
// - 安装 ID 匿名生成（不派生自机器名/SID/硬件 ID/账号/序列号）
// - 保留期清理（30 天 + 上限 10000 条，优先保留崩溃事件）
// - 上传失败不产生新遥测事件（避免递归）
//
// 全程不阻塞调用方：recordEvent 同步入聚合 Map，DB 写入由定时器异步驱动。

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../data/database/daos/telemetry_event_dao.dart';
import '../../data/external/community/community_api_client.dart';
import 'sensitive_data_sanitizer.dart';

/// 遥测服务。负责事件采集、内存聚合、定时落库与上传。
///
/// 通过 [telemetryServiceProvider] 注入 Riverpod，全 App 单例。
/// 调用方通过 [recordEvent] 上报事件，无需关心落库与上传时机。
class TelemetryService {
  TelemetryService({
    required TelemetryEventDao dao,
    CommunityTelemetryApi? api,
    required SharedPreferences prefs,
    required bool Function() isUploadEnabled,
  })  : _dao = dao,
        _api = api,
        _prefs = prefs,
        _isUploadEnabled = isUploadEnabled {
    // 启动定时器：60s 落库聚合，5min 上传待发批次
    _flushTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(_flushAggregations()),
    );
    _uploadTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_uploadPendingEvents()),
    );
    // 启动后立即清理一次过期事件
    unawaited(clearOldEvents());
  }

  final TelemetryEventDao _dao;
  final CommunityTelemetryApi? _api;
  final SharedPreferences _prefs;
  final bool Function() _isUploadEnabled;

  static const Uuid _uuid = Uuid();

  /// 事件名白名单（与服务端一致）。不在白名单内的事件被静默丢弃。
  static const Set<String> kEventWhitelist = {
    'app.crash',
    'app.upgrade',
    'sync.community_presets',
    'sync.bambu_devices',
    'sync.bambu_presets',
    'http.community_request',
    'printer.connection',
    'printer.compatibility',
    'camera.bridge',
    'onboarding.flow',
    'remote_config.fetch',
  };

  /// SharedPreferences 键：匿名安装 ID（UUID v4，首次启动生成）。
  static const String kInstallIdKey = 'telemetry_install_id';

  /// SharedPreferences 键：遥测上传开关（用户可在设置中关闭）。
  static const String kUploadEnabledKey = 'telemetry_upload_enabled';

  // -- 内存聚合 ---------------------------------------------------------------

  /// 聚合缓冲区。键为 `eventName|resultCategory`，值为该窗口内的聚合统计。
  ///
  /// 高频事件（如 MQTT 状态更新）先在此合并，每 60s 落库一次，
  /// 避免每个包都触发 DB 写入。
  final Map<String, _AggregatedEvent> _aggregations = {};

  // -- 定时器 -----------------------------------------------------------------

  Timer? _flushTimer;
  Timer? _uploadTimer;

  // -- 上传状态 ---------------------------------------------------------------

  /// 当前上传批次大小。413 时减半，下限 1。
  int _batchSize = 50;

  /// 429 退避：在此时间之前跳过上传循环。
  DateTime? _pausedUntil;

  /// 网络错误连续退避基数（指数退避用）。
  int _networkErrorStreak = 0;

  String? _installId;
  String? _installIdHash;

  // -- 公开 API --------------------------------------------------------------

  /// 记录一次遥测事件。
  ///
  /// - 不在白名单的事件静默丢弃（不抛异常）。
  /// - [sanitizeAttributes]=true 时通过 [SensitiveDataSanitizer.sanitizeMap] 脱敏。
  /// - 高频事件在内存聚合，低频事件也走同一通道（统一 60s 落库）。
  /// - 本方法 **永不抛异常、永不阻塞调用方**：所有 DB 写入由定时器异步驱动。
  Future<void> recordEvent({
    required String eventName,
    String? resultCategory,
    int? durationMs,
    Map<String, dynamic> attributes = const {},
    bool sanitizeAttributes = true,
  }) async {
    try {
      // 1. 白名单校验
      if (!kEventWhitelist.contains(eventName)) {
        if (kDebugMode) {
          debugPrint('[TelemetryService] 事件不在白名单，已丢弃: $eventName');
        }
        return;
      }

      // 2. 脱敏 attributes
      final sanitized = sanitizeAttributes
          ? SensitiveDataSanitizer.sanitizeMap(attributes)
          : Map<String, dynamic>.from(attributes);

      // 3. 写入聚合缓冲区（同步操作，不阻塞）
      final now = DateTime.now();
      final key = '$eventName|${resultCategory ?? ''}';
      final existing = _aggregations[key];
      if (existing != null) {
        existing
          ..count += 1
          ..lastDurationMs = durationMs ?? existing.lastDurationMs
          ..lastRecordedAt = now;
        // 合并 attributes（后者覆盖前者，保留更多上下文）
        sanitized.forEach((k, v) => existing.attributes[k] = v);
      } else {
        _aggregations[key] = _AggregatedEvent(
          eventName: eventName,
          resultCategory: resultCategory,
          count: 1,
          lastDurationMs: durationMs,
          firstRecordedAt: now,
          lastRecordedAt: now,
          attributes: sanitized,
        );
      }
    } catch (e) {
      // 永不抛异常：遥测失败不应影响业务流程
      if (kDebugMode) {
        debugPrint('[TelemetryService] recordEvent 异常（已吞掉）: $e');
      }
    }
  }

  /// 按保留策略清理旧事件。可在启动时或用户触发时调用。
  Future<void> clearOldEvents() async {
    try {
      await _dao.clearOldEvents();
      // 任务书 11.4：未发送队列最多 1000 条或 7 天，超限先删最旧非崩溃聚合事件。
      await _dao.clearOldPendingEvents();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[TelemetryService] clearOldEvents 失败: $e');
      }
    }
  }

  /// 释放资源：取消定时器，刷入残留聚合。
  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _uploadTimer?.cancel();
    _uploadTimer = null;
    await _flushAggregations();
  }

  /// 获取（必要时生成）匿名安装 ID。
  ///
  /// **隐私要求**：ID 为随机 UUID v4，不派生自机器名、Windows SID、
  /// 硬件 ID、账号或序列号。仅用于在服务器侧区分不同安装。
  Future<String> getInstallId() async {
    if (_installId != null) return _installId!;
    final existing = _prefs.getString(kInstallIdKey);
    if (existing != null && existing.isNotEmpty) {
      _installId = existing;
      return existing;
    }
    final newId = _uuid.v4();
    await _prefs.setString(kInstallIdKey, newId);
    _installId = newId;
    return newId;
  }

  /// 获取安装 ID 的 SHA-256 哈希（发送至服务器，不可逆推原始 ID）。
  Future<String> getInstallIdHash() async {
    if (_installIdHash != null) return _installIdHash!;
    final id = await getInstallId();
    _installIdHash = sha256.convert(utf8.encode(id)).toString();
    return _installIdHash!;
  }

  // -- 内部：落库 -------------------------------------------------------------

  /// 将内存聚合缓冲区刷入数据库。每次 flush 后清空缓冲区。
  ///
  /// 聚合事件落库时，将 count / 窗口起止时间写入 attributes，
  /// 服务端可据此还原原始频次。
  Future<void> _flushAggregations() async {
    if (_aggregations.isEmpty) return;
    final entries = List<_AggregatedEvent>.from(_aggregations.values);
    _aggregations.clear();
    for (final entry in entries) {
      try {
        final event = TelemetryEvent(
          id: _uuid.v4(),
          eventUid: _uuid.v4(),
          eventName: entry.eventName,
          resultCategory: entry.resultCategory,
          durationMs: entry.lastDurationMs,
          attributes: {
            ...entry.attributes,
            if (entry.count > 1) 'aggCount': entry.count,
            if (entry.count > 1)
              'aggWindowStart': entry.firstRecordedAt.toUtc().toIso8601String(),
            if (entry.count > 1)
              'aggWindowEnd': entry.lastRecordedAt.toUtc().toIso8601String(),
          },
          recordedAt: entry.lastRecordedAt,
        );
        await _dao.insert(event);
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[TelemetryService] flush 单条事件失败: $e');
        }
      }
    }
  }

  // -- 内部：上传 -------------------------------------------------------------

  /// 上传一批 pending 事件至社区服务器。
  ///
  /// 错误处理策略（任务书 11）：
  /// - 429：暂停上传循环 5 分钟
  /// - 413：批次大小减半（下限 1）
  /// - 401/403：标记事件为 failed，不再自动重试
  /// - 网络错误：指数退避 + 抖动（base 30s，max 30min，×2）
  ///
  /// **上传失败不产生新遥测事件**，避免递归。
  Future<void> _uploadPendingEvents() async {
    // 未配置社区服务器 → 仅本地存储
    final api = _api;
    if (api == null) return;

    // 用户关闭了上传
    if (!_isUploadEnabled()) return;

    // 429 退避期内跳过
    if (_pausedUntil != null && DateTime.now().isBefore(_pausedUntil!)) {
      return;
    }

    try {
      final events = await _dao.queryPending(limit: _batchSize);
      if (events.isEmpty) {
        _networkErrorStreak = 0;
        return;
      }

      final installIdHash = await getInstallIdHash();
      final payload = events.map((e) => e.toUploadPayload()).toList();

      await api.submitTelemetryBatch(
        installIdHash: installIdHash,
        events: payload,
      );

      // 成功：标记为 synced，重置退避计数，逐步恢复批次大小
      await _dao.markSynced(events.map((e) => e.id).toList());
      _networkErrorStreak = 0;
      // 413 减半后，成功上传时逐步恢复批次大小到上限 50
      if (_batchSize < 50) {
        _batchSize = (_batchSize * 2).clamp(1, 50);
      }
    } on CommunityApiException catch (e) {
      await _handleApiError(e);
    } catch (e) {
      // 未知异常：按网络错误退避，但不产生新遥测事件
      if (kDebugMode) {
        debugPrint('[TelemetryService] 上传未知异常: $e');
      }
      _networkErrorStreak += 1;
    }
  }

  Future<void> _handleApiError(CommunityApiException e) async {
    final statusCode = e.statusCode;
    if (statusCode == 429) {
      // 限流：暂停上传循环 5 分钟
      _pausedUntil = DateTime.now().add(const Duration(minutes: 5));
      if (kDebugMode) {
        debugPrint('[TelemetryService] 429 限流，暂停上传 5 分钟');
      }
      return;
    }
    if (statusCode == 413) {
      // 载荷过大：批次减半（下限 1）
      _batchSize = (_batchSize ~/ 2).clamp(1, 50);
      if (kDebugMode) {
        debugPrint('[TelemetryService] 413 载荷过大，批次减至 $_batchSize');
      }
      return;
    }
    if (statusCode == 401 || statusCode == 403) {
      // 鉴权失败：暂停上传循环 24 小时（等待用户重新登录修复身份），
      // 避免逐批烧光 pending 事件。同时标记当前批为 failed 不再重试。
      _pausedUntil = DateTime.now().add(const Duration(hours: 24));
      try {
        final pending = await _dao.queryPending(limit: _batchSize);
        for (final event in pending) {
          await _dao.markFailed(event.id);
        }
      } catch (_) {
        // 标记失败本身不应阻塞上传循环
      }
      if (kDebugMode) {
        debugPrint(
          '[TelemetryService] ${e.statusCode} 鉴权失败，暂停上传 24 小时并标记当前批为 failed',
        );
      }
      return;
    }

    // 其余错误（网络/超时/5xx）按指数退避
    _networkErrorStreak += 1;
    final backoffSeconds = _computeBackoffSeconds(_networkErrorStreak);
    final nextRetryAt = DateTime.now().add(Duration(seconds: backoffSeconds));
    try {
      final pending = await _dao.queryPending(limit: _batchSize);
      for (final event in pending) {
        await _dao.incrementAttempt(
          event.id,
          nextRetryAt: nextRetryAt.millisecondsSinceEpoch,
        );
      }
    } catch (_) {
      // 退避标记失败不阻塞下一轮
    }
    if (kDebugMode) {
      debugPrint(
        '[TelemetryService] 网络错误退避：streak=$_networkErrorStreak, '
        'backoff=${backoffSeconds}s',
      );
    }
  }

  /// 指数退避 + 抖动：base=30s, max=30min, multiplier=2, jitter=0~30s。
  int _computeBackoffSeconds(int attempt) {
    const base = 30;
    const maxSeconds = 30 * 60; // 30 分钟
    final exponential = base * pow(2, attempt - 1).toInt();
    final clamped = exponential > maxSeconds ? maxSeconds : exponential;
    final jitter = _random.nextInt(base); // 0~30s 抖动
    return (clamped + jitter).clamp(base, maxSeconds);
  }

  static final Random _random = Random();
}

/// 内存聚合事件（高频事件缓冲区条目）。
///
/// 键为 `eventName|resultCategory`，每 60s 落库一次。
/// 落库时 count / 窗口起止时间写入 attributes。
class _AggregatedEvent {
  final String eventName;
  final String? resultCategory;
  int count;
  int? lastDurationMs;
  DateTime firstRecordedAt;
  DateTime lastRecordedAt;
  final Map<String, dynamic> attributes;

  _AggregatedEvent({
    required this.eventName,
    required this.resultCategory,
    required this.count,
    required this.lastDurationMs,
    required this.firstRecordedAt,
    required this.lastRecordedAt,
    required this.attributes,
  });
}
