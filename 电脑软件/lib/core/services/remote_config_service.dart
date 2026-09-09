// 远程配置服务（Phase F-4）。
//
// 任务书 11.6 Phase F-4 要求：
// - 从社区服务器拉取远程配置（feature flags），缓存到本地。
// - 提供统一的 getFlag(key) 接口供各功能模块查询。
// - 优先级：远程配置缓存（last-known-good）> 内置默认值。
// - 不可变安全特性（immutableFlags）永远返回 true，不允许远程关闭。
// - 3 秒超时、304 条件请求、24 小时过期、30 分钟定时刷新。
// - 所有操作不抛异常，静默回退到内置默认值或上次缓存。
//
// 线程安全：本服务在 Riverpod Provider 中以单例形式存在，
// 仅在 Provider 重建时（endpoint 变化）才会重新构造。
// 刷新等待初始化并合并并发请求；销毁后的响应不能更新持久化缓存。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import '../../data/external/community/community_api_client.dart';

/// 发行通道使用稳定的三段版本号和可选整数构建号。
bool isValidAppReleaseVersion(String version) {
  final normalized = version.trim().replaceFirst(RegExp(r'^[vV]'), '');
  return RegExp(r'^\d+\.\d+\.\d+(?:\+\d+)?$').hasMatch(normalized) &&
      normalized
          .split(RegExp(r'[.+]'))
          .every((part) => int.tryParse(part) != null);
}

/// 同时供配置缓存保护和更新服务使用，避免二者对构建号有不同解释。
int compareRemoteReleaseVersions(String left, String right) {
  List<int> parts(String value) {
    final version = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final sections = version.split('+');
    final core = sections.first.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < core.length ? int.tryParse(core[i]) ?? 0 : 0,
      sections.length > 1 ? int.tryParse(sections[1]) ?? 0 : 0,
    ];
  }

  final a = parts(left);
  final b = parts(right);
  for (var i = 0; i < a.length; i++) {
    final comparison = a[i].compareTo(b[i]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

/// 远程配置服务。
///
/// 负责从社区服务器拉取 feature flags，缓存到 SharedPreferences，
/// 提供同步 [getFlag] 接口供各功能模块查询。
///
/// 容错策略：
/// - 服务器未配置时使用内置默认值。
/// - 拉取失败/超时/格式无效时保留上次缓存，不覆盖。
/// - 不可变安全特性永远返回 true。
@immutable
class RemoteConfigState {
  const RemoteConfigState({
    required this.flags,
    required this.source,
    required this.updatedAtMillis,
    required this.etag,
    this.fetchError,
  });

  const RemoteConfigState.builtIn()
    : flags = const {},
      source = 'built_in',
      updatedAtMillis = 0,
      etag = null,
      fetchError = null;

  final Map<String, Object> flags;
  final String source;
  final int updatedAtMillis;
  final String? etag;

  /// 最近一次刷新失败（unavailable / invalid_config），不写入配置缓存。
  final String? fetchError;

  bool get isStale {
    if (updatedAtMillis == 0) return true;
    final age = DateTime.now().millisecondsSinceEpoch - updatedAtMillis;
    return age > RemoteConfigService.cacheExpiry.inMilliseconds;
  }
}

class RemoteConfigService extends StateNotifier<RemoteConfigState> {
  RemoteConfigService._(
    this._api, {
    bool startPeriodicRefresh = true,
    String? platform,
  }) : _requestPlatform = platform ?? _platform,
       super(const RemoteConfigState.builtIn()) {
    _initialization = _init(startPeriodicRefresh: startPeriodicRefresh);
  }

  @visibleForTesting
  factory RemoteConfigService.forTesting(
    CommunityTelemetryApi? api, {
    String? platform,
  }) => RemoteConfigService._(
    api,
    startPeriodicRefresh: false,
    platform: platform,
  );

  final CommunityTelemetryApi? _api;
  final String _requestPlatform;
  late final Future<void> _initialization;

  /// 内存中的 flags 缓存（从 SharedPreferences 加载）。
  Map<String, Object> _flagsCache = {};

  /// 当前配置来源。
  String _source = 'built_in';

  /// 最后更新时间（毫秒时间戳），0 表示从未更新。
  int _updatedAtMillis = 0;

  /// 当前 ETag。
  String? _etag;
  String? _fetchError;

  /// 定时刷新计时器。
  Timer? _timer;
  Future<void>? _fetchOperation;

  // -- SharedPreferences keys --

  static const _cacheKey = 'remote_config_cache';
  static const _etagKey = 'remote_config_etag';
  static const _updatedAtKey = 'remote_config_updated_at';
  static const _sourceKey = 'remote_config_source';

  // -- 常量 --

  /// 内置默认值：所有可控 flag 的安全默认值。
  static const Map<String, Object> builtInDefaults = {
    'community_share_print_results': true, // 本地用户开关默认关闭，远程仅作紧急停用
    // 这些能力由本地用户开关决定是否启用；远程配置只保留紧急停用能力。
    'auto_schedule': true,
    'rfid_auto_adopt_observations': true, // RFID 自动采用观测值（默认开启）
    'experiment_auto_enqueue': true,
    'telemetry_upload_enabled': false, // 匿名诊断上传（默认关闭）
    'community_feed_enhanced': true, // 社区增强展示
    // 应用更新元数据。正式服务可覆盖这些值，内置值代表本构建已知版本。
    'desktop_latest_version': AppVersion.fullVersion,
    'desktop_min_supported_version': '',
    'desktop_force_update': false,
    'desktop_download_url': '',
    'desktop_release_notes': '',
    'android_latest_version': AppVersion.fullVersion,
    'android_min_supported_version': '',
    'android_force_update': false,
    'android_download_url': '',
    'android_release_notes': '',
  };

  /// 不可变安全特性：永远不允许远程关闭。
  static const Set<String> immutableFlags = {
    'data_integrity_check',
    'inventory_settlement',
    'lan_monitoring',
    'fault_safety_alert',
    'credential_protection',
  };

  /// 缓存过期时间：24 小时。
  static const cacheExpiry = Duration(hours: 24);

  /// 定时刷新间隔：30 分钟。
  static const _refreshInterval = Duration(minutes: 30);

  /// 拉取超时：3 秒。
  static const _fetchTimeout = Duration(seconds: 3);

  /// 当前平台标识。
  static String get _platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  // -- 初始化 --

  /// 异步初始化：从 SharedPreferences 加载缓存，启动定时刷新。
  Future<void> _init({required bool startPeriodicRefresh}) async {
    await _loadCacheFromPrefs();
    if (!mounted) return;
    _publishState();
    if (startPeriodicRefresh) _startPeriodicRefresh();
  }

  /// 等待本地缓存装载完成。需要读取配置来源或更新时间的调用方应先等待。
  Future<void> get ready => _initialization;

  @visibleForTesting
  Future<void> get initialized => ready;

  /// 从 SharedPreferences 加载缓存到内存。
  Future<void> _loadCacheFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final cacheJson = prefs.getString(_cacheKey);
      if (cacheJson != null && cacheJson.isNotEmpty) {
        final decoded = jsonDecode(cacheJson);
        if (decoded is Map) {
          _flagsCache = Map<String, Object>.from(decoded);
        }
      }
      _source = prefs.getString(_sourceKey) ?? 'built_in';
      _updatedAtMillis = prefs.getInt(_updatedAtKey) ?? 0;
      _etag = prefs.getString(_etagKey);
    } catch (e) {
      debugPrint('[RemoteConfig] 加载缓存失败: $e');
      // 即使加载失败也继续，getFlag 会回退到内置默认值
    }
  }

  // -- 公开接口 --

  /// 获取 flag 值（同步）。
  ///
  /// 优先级：远程配置缓存（last-known-good）> 内置默认值。
  /// 不可变 flag 永远返回 true。
  /// 返回 Object（bool/int/string），调用方需自行转换类型。
  Object getFlag(String key) {
    // 不可变 flag 永远返回 true，不允许远程关闭
    if (immutableFlags.contains(key)) return true;
    // 远程配置缓存优先
    final cached = _flagsCache[key];
    if (cached != null) return cached;
    // 内置默认值
    return builtInDefaults[key] ?? false;
  }

  /// 获取当前配置来源：'built_in' / 'cached' / 'community_server'。
  String getConfigSource() => _source;

  /// 最后更新时间（毫秒时间戳），0 表示从未更新。
  int getLastUpdated() => _updatedAtMillis;

  /// 缓存是否已过期（超过 24 小时或从未更新）。
  bool isStale() {
    if (_updatedAtMillis == 0) return true;
    final age = DateTime.now().millisecondsSinceEpoch - _updatedAtMillis;
    return age > cacheExpiry.inMilliseconds;
  }

  /// 获取当前 ETag（用于条件请求）。
  String? getETag() => _etag;

  /// 拉取并更新远程配置。
  ///
  /// - 服务器未配置时跳过（使用内置默认值）。
  /// - 3 秒超时。
  /// - 校验响应：schema version、已知 key、类型。
  /// - 成功：更新 last-known-good 缓存 + ETag，source='community_server'。
  /// - 304：刷新缓存时间戳，不改变内容。
  /// - 失败：保留上次缓存，不覆盖。
  /// - 永不抛异常。
  Future<void> fetchAndUpdate() {
    if (!mounted || _api == null) return Future<void>.value();
    return _fetchOperation ??= _fetchAndUpdate(_api).whenComplete(() {
      _fetchOperation = null;
    });
  }

  Future<void> _fetchAndUpdate(CommunityTelemetryApi api) async {
    await ready;
    if (!mounted) return;
    try {
      final config = await api
          .fetchRemoteConfig(
            appVersion: AppVersion.fullVersion,
            platform: _requestPlatform,
            ifNoneMatch: _etag,
          )
          .timeout(_fetchTimeout);
      if (!mounted) return;

      // 校验响应
      if (!_validateConfig(config)) {
        debugPrint('[RemoteConfig] 远程配置校验失败，保留缓存');
        _reportFetchFailure('invalid_config');
        return;
      }

      // 过滤：只保留已知 key 且类型匹配的 flag
      final filtered = _filterKnownFlags(config.flags);
      _retainSafeReleaseDownloadUrls(filtered);

      // 更新内存缓存
      _flagsCache = filtered;
      _source = 'community_server';
      _etag = config.etag;
      _updatedAtMillis = DateTime.now().millisecondsSinceEpoch;
      _fetchError = null;

      // 持久化
      await _persistCache();
      _publishState();
    } on CommunityApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'not_modified') {
        // 304：仅刷新时间戳，不改变内容
        await _handleNotModified();
        return;
      }
      debugPrint('[RemoteConfig] 拉取失败（API 错误）: ${e.message}');
      _reportFetchFailure('unavailable');
    } on TimeoutException {
      debugPrint('[RemoteConfig] 拉取超时，保留缓存');
      _reportFetchFailure('unavailable');
    } catch (e) {
      debugPrint('[RemoteConfig] 拉取异常，保留缓存: $e');
      _reportFetchFailure('unavailable');
    }
  }

  /// 应用恢复时刷新（从后台回到前台时调用）。
  void onAppResume() {
    fetchAndUpdate();
  }

  /// 释放资源。
  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  // -- 内部方法 --

  /// 处理 304 Not Modified：仅刷新时间戳。
  Future<void> _handleNotModified() async {
    if (!mounted) return;
    _fetchError = null;
    _updatedAtMillis = DateTime.now().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      await prefs.setInt(_updatedAtKey, _updatedAtMillis);
      if (!mounted) return;
      // 若之前 source 为 built_in（从未成功拉取过），304 不改变 source
      // 若之前已有缓存，保持 cached/community_server
      if (_source == 'built_in' && _flagsCache.isNotEmpty) {
        _source = 'cached';
        await prefs.setString(_sourceKey, _source);
      }
    } catch (e) {
      debugPrint('[RemoteConfig] 304 时间戳持久化失败: $e');
    }
    _publishState();
  }

  /// 校验远程配置响应。
  bool _validateConfig(CommunityRemoteConfig config) {
    // schema version 必须 > 0
    if (config.schemaVersion <= 0) return false;
    // 空 flags 是服务端“当前没有任何覆盖项”的合法快照。
    // 但已知 flag 一旦出现，类型必须与内置默认值完全一致；否则整份快照
    // 不得覆盖 last-known-good，避免格式损坏被误解释成“全部使用默认值”。
    for (final entry in config.flags.entries) {
      final defaultValue = builtInDefaults[entry.key];
      if (defaultValue == null) continue;
      final value = entry.value;
      if ((defaultValue is bool && value is! bool) ||
          (defaultValue is int && value is! int) ||
          (defaultValue is String && value is! String)) {
        return false;
      }
    }
    if (!_validateReleasePolicy(config.flags, 'desktop') ||
        !_validateReleasePolicy(config.flags, 'android')) {
      return false;
    }
    // generatedAt 不能是未来时间（允许 1 小时误差，防止时钟偏移）
    final now = DateTime.now();
    if (config.generatedAt.isAfter(now.add(const Duration(hours: 1)))) {
      return false;
    }
    return true;
  }

  bool _validateReleasePolicy(Map<String, dynamic> flags, String prefix) {
    final latest = flags['${prefix}_latest_version'];
    final minimum = flags['${prefix}_min_supported_version'];
    final hasMetadata = flags.keys.any((key) => key.startsWith('${prefix}_'));
    if (hasMetadata &&
        (latest is! String || !isValidAppReleaseVersion(latest))) {
      return false;
    }
    if (minimum is String &&
        minimum.trim().isNotEmpty &&
        (!isValidAppReleaseVersion(minimum) ||
            latest is! String ||
            compareRemoteReleaseVersions(minimum, latest) > 0)) {
      return false;
    }

    // 强制策略被确认后，旧服务/损坏响应不能抹去持久化缓存，否则重启
    // 会绕过同一份最低版本要求。只有同级或更新发行的完整策略可撤回。
    if (!_isMandatoryRelease(_flagsCache, prefix)) return true;
    final previousLatest = _flagsCache['${prefix}_latest_version']! as String;
    if (latest is! String ||
        compareRemoteReleaseVersions(latest, previousLatest) < 0) {
      return false;
    }
    if (!_isMandatoryRelease(flags, prefix) &&
        (flags['${prefix}_force_update'] != false ||
            !flags.containsKey('${prefix}_min_supported_version'))) {
      return false;
    }
    return true;
  }

  bool _isMandatoryRelease(Map<String, dynamic> flags, String prefix) {
    final latest = flags['${prefix}_latest_version'];
    if (latest is! String ||
        !isValidAppReleaseVersion(latest) ||
        compareRemoteReleaseVersions(latest, AppVersion.fullVersion) <= 0) {
      return false;
    }
    final minimum = flags['${prefix}_min_supported_version'];
    return flags['${prefix}_force_update'] == true ||
        (minimum is String &&
            isValidAppReleaseVersion(minimum) &&
            compareRemoteReleaseVersions(AppVersion.fullVersion, minimum) < 0);
  }

  void _reportFetchFailure(String error) {
    if (!mounted) return;
    _fetchError = error;
    _publishState();
  }

  /// 过滤：只保留已知 key 且类型与默认值匹配的 flag。
  ///
  /// 未知 key 和不可变 flag 被忽略，防止服务端注入或关闭安全特性。
  Map<String, Object> _filterKnownFlags(Map<String, dynamic> flags) {
    final result = <String, Object>{};
    for (final entry in flags.entries) {
      final key = entry.key;
      final value = entry.value;
      // 只接受已知 key（在 builtInDefaults 中）
      if (!builtInDefaults.containsKey(key)) continue;
      // 不可变 flag 不接受远程值
      if (immutableFlags.contains(key)) continue;
      // 类型校验：与默认值类型匹配
      final defaultValue = builtInDefaults[key];
      if (defaultValue is bool && value is bool) {
        result[key] = value;
      } else if (defaultValue is int && value is int) {
        result[key] = value;
      } else if (defaultValue is String && value is String) {
        result[key] = value;
      }
      // 类型不匹配：跳过该 key
    }
    return result;
  }

  /// 同一发行版临时丢失地址时保留已校验入口，并随新快照一起持久化。
  /// 策略已在合并前完整验证；只合并 URL，不影响其他功能开关的刷新。
  void _retainSafeReleaseDownloadUrls(Map<String, Object> next) {
    for (final prefix in ['desktop', 'android']) {
      final versionKey = '${prefix}_latest_version';
      final downloadKey = '${prefix}_download_url';
      final previousVersion = _flagsCache[versionKey];
      final nextVersion = next[versionKey];
      if (previousVersion is! String ||
          nextVersion is! String ||
          !isValidAppReleaseVersion(previousVersion) ||
          !isValidAppReleaseVersion(nextVersion) ||
          compareRemoteReleaseVersions(previousVersion, nextVersion) != 0 ||
          _safeReleaseDownloadUrl(next[downloadKey]) != null) {
        continue;
      }
      final previousUrl = _safeReleaseDownloadUrl(_flagsCache[downloadKey]);
      if (previousUrl != null) next[downloadKey] = previousUrl;
    }
  }

  String? _safeReleaseDownloadUrl(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        !uri.isAbsolute ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    return uri.toString();
  }

  /// 持久化缓存到 SharedPreferences。
  Future<void> _persistCache() async {
    if (!mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      await prefs.setString(_cacheKey, jsonEncode(_flagsCache));
      if (!mounted) return;
      await prefs.setString(_sourceKey, _source);
      if (!mounted) return;
      await prefs.setInt(_updatedAtKey, _updatedAtMillis);
      if (!mounted) return;
      if (_etag != null) {
        await prefs.setString(_etagKey, _etag!);
      } else {
        await prefs.remove(_etagKey);
      }
    } catch (e) {
      debugPrint('[RemoteConfig] 持久化缓存失败: $e');
    }
  }

  void _publishState() {
    if (!mounted) return;
    state = RemoteConfigState(
      flags: Map<String, Object>.unmodifiable(_flagsCache),
      source: _source,
      updatedAtMillis: _updatedAtMillis,
      etag: _etag,
      fetchError: _fetchError,
    );
  }

  /// 启动定时刷新（每 30 分钟）。
  /// 任务书 11.6：社区服务地址为空时直接使用内置值，不启动定时网络请求。
  void _startPeriodicRefresh() {
    if (!mounted || _api == null) return;
    _timer?.cancel();
    _timer = Timer.periodic(_refreshInterval, (_) {
      fetchAndUpdate();
    });
    // 启动时立即拉取一次（fire-and-forget）
    fetchAndUpdate();
  }
}

// -- Riverpod Provider --

/// 远程配置服务 Provider。
///
/// 监听 [communityTelemetryApiProvider]：当 endpoint 变化时重建服务。
/// 服务构造后会异步加载缓存并启动定时刷新，[getFlag] 在缓存加载完成前
/// 返回内置默认值（安全回退）。
final remoteConfigServiceProvider =
    StateNotifierProvider<RemoteConfigService, RemoteConfigState>((ref) {
      final api = ref.watch(communityTelemetryApiProvider);
      return RemoteConfigService._(api);
    });
