import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/services/telemetry_service.dart';
import '../data/external/community/community_api_client.dart';
import 'database_provider.dart';

/// SharedPreferences 异步单例。
///
/// 首次访问时通过 `SharedPreferences.getInstance()` 加载，后续读取缓存值。
/// 遥测服务、用户偏好等需在构造时同步访问 prefs 的组件依赖此 Provider。
final sharedPreferencesProvider =
    FutureProvider<SharedPreferences>((ref) async {
  return SharedPreferences.getInstance();
});

/// TelemetryService 单例。
///
/// 依赖：
/// - [telemetryEventDaoProvider]：本地事件队列 DAO
/// - [communityTelemetryApiProvider]：社区服务器客户端（未配置服务器时为 null，
///   服务退化为仅本地存储）
/// - [sharedPreferencesProvider]：用于持久化匿名安装 ID 和上传开关
///
/// `isUploadEnabled` 回调同步读取 SharedPreferences 中的上传开关
/// （`telemetry_upload_enabled`，默认 false，用户需显式开启）。
/// SharedPreferences 加载后 `getBool` 为同步操作，适合在回调中直接调用。
final telemetryServiceProvider = FutureProvider<TelemetryService>((ref) async {
  final prefs = await ref.watch(sharedPreferencesProvider.future);
  final dao = ref.watch(telemetryEventDaoProvider);
  final api = ref.watch(communityTelemetryApiProvider);

  final service = TelemetryService(
    dao: dao,
    api: api,
    prefs: prefs,
    isUploadEnabled: () =>
        prefs.getBool(TelemetryService.kUploadEnabledKey) ?? false,
  );

  ref.onDispose(service.dispose);
  return service;
});
