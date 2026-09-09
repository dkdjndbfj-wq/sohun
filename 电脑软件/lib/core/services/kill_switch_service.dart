// 本地 kill switch 服务（Phase F-5）。
//
// 任务书 11.6 Phase F-5 要求：
// - 用户可控的本地 kill switch，可随时关闭某项功能。
// - isEnabled(key) 返回"本地 kill switch AND 远程配置 flag"的有效值。
// - 本地 kill switch 优先级高于远程配置（本地关闭则远程无法开启）。
// - 不可变安全特性永远返回 true。
// - 每个 kill switch 提供 StateNotifierProvider<bool> 供 UI 绑定。
//
// 与 Phase F-4 RemoteConfigService 的关系：
// - RemoteConfigService 提供远程 feature flags（服务端可控）。
// - KillSwitchService 在远程 flag 之上叠加本地用户开关。
// - 有效值 = 本地 kill switch AND 远程 config flag。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_config_service.dart';

/// Kill switch 配置项。
class _KillSwitchConfig {
  /// SharedPreferences 持久化 key。
  final String prefsKey;

  /// 对应的远程配置 flag 名称。
  final String remoteFlag;

  /// 本地默认值。
  final bool defaultValue;

  const _KillSwitchConfig({
    required this.prefsKey,
    required this.remoteFlag,
    required this.defaultValue,
  });
}

/// 本地 kill switch 服务。
///
/// 在远程配置 flag 之上叠加本地用户开关，提供 [isEnabled] 同步接口
/// 供各功能模块在调用前检查。本地开关优先级高于远程配置：
/// 本地关闭时，即使远程配置开启，功能也被禁用。
///
/// 不可变安全特性（[RemoteConfigService.immutableFlags]）永远返回 true。
class KillSwitchService {
  KillSwitchService._(this._remoteConfig) {
    _init();
  }

  final RemoteConfigService _remoteConfig;

  /// SharedPreferences 实例（异步加载后可用）。
  SharedPreferences? _prefs;

  /// 是否已完成初始化。
  bool _initialized = false;

  /// 各 kill switch 的配置。
  static const Map<String, _KillSwitchConfig> _configs = {
    'community_share': _KillSwitchConfig(
      prefsKey: 'killswitch_community_share',
      remoteFlag: 'community_share_print_results',
      defaultValue: false, // 社区设备记录分享（默认关闭）
    ),
    // 注意：auto_schedule 复用 scheduler_provider.dart 中已有的
    // autoScheduleEnabledProvider（key: 'auto_schedule_enabled'），
    // 此处 kill switch 读取同一 key，不创建新的 StateNotifierProvider。
    'auto_schedule': _KillSwitchConfig(
      prefsKey: 'auto_schedule_enabled',
      remoteFlag: 'auto_schedule',
      defaultValue: false, // 自动调度（默认关闭）
    ),
    'rfid_auto_adopt': _KillSwitchConfig(
      prefsKey: 'killswitch_rfid_auto_adopt',
      remoteFlag: 'rfid_auto_adopt_observations',
      defaultValue: true, // RFID 自动采用观测值（默认开启）
    ),
    'experiment_auto_enqueue': _KillSwitchConfig(
      prefsKey: 'killswitch_experiment_auto_enqueue',
      remoteFlag: 'experiment_auto_enqueue',
      defaultValue: false, // 参数实验自动入队（默认关闭）
    ),
  };

  /// 异步初始化：获取 SharedPreferences 实例。
  Future<void> _init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      _initialized = true;
    } catch (e) {
      debugPrint('[KillSwitch] 初始化失败: $e');
      _initialized = true;
    }
  }

  /// 获取 kill switch 的有效值（同步）。
  ///
  /// 返回：本地 kill switch AND 远程配置 flag。
  /// - 不可变 flag 永远返回 true。
  /// - 本地关闭时，即使远程开启也返回 false（本地优先）。
  /// - 初始化完成前使用默认值（安全回退）。
  bool isEnabled(String key) {
    // 不可变安全特性永远返回 true
    if (RemoteConfigService.immutableFlags.contains(key)) return true;

    final config = _configs[key];
    if (config == null) {
      debugPrint('[KillSwitch] 未知 kill switch key: $key');
      return false;
    }

    // 本地 kill switch 值
    bool localValue = config.defaultValue;
    if (_initialized && _prefs != null) {
      localValue = _prefs!.getBool(config.prefsKey) ?? config.defaultValue;
    }

    // 本地关闭 → 直接返回 false（本地优先）
    if (!localValue) return false;

    // 远程配置 flag
    final remoteValue = _remoteConfig.getFlag(config.remoteFlag);
    if (remoteValue is bool) {
      return remoteValue;
    }
    // 远程配置类型异常时回退到 false（安全）
    return false;
  }

  /// 设置本地 kill switch 值（持久化到 SharedPreferences）。
  Future<void> setEnabled(String key, bool value) async {
    final config = _configs[key];
    if (config == null) {
      debugPrint('[KillSwitch] 未知 kill switch key: $key');
      return;
    }

    if (_prefs == null) {
      _prefs = await SharedPreferences.getInstance();
      _initialized = true;
    }
    await _prefs!.setBool(config.prefsKey, value);
  }
}

// -- Riverpod Providers --

/// KillSwitchService 单例 Provider。
///
/// 依赖 [remoteConfigServiceProvider]：远程配置服务变化时重建。
final killSwitchServiceProvider = Provider<KillSwitchService>((ref) {
  final remoteConfig = ref.watch(remoteConfigServiceProvider.notifier);
  return KillSwitchService._(remoteConfig);
});

// -- 各 kill switch 的 StateNotifierProvider（供 UI 绑定） --
//
// 注意：autoScheduleEnabledProvider 已在 scheduler_provider.dart 中定义，
// 此处不重复创建，直接复用。

/// 社区设备记录分享 kill switch Provider（持久化，默认关闭）。
class CommunityShareEnabledNotifier extends StateNotifier<bool> {
  CommunityShareEnabledNotifier() : super(false) {
    _load();
  }

  static const _key = 'killswitch_community_share';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) state = prefs.getBool(_key) ?? false;
    } catch (e) {
      debugPrint('[KillSwitch] 加载 community_share 失败: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (e) {
      debugPrint('[KillSwitch] 保存 community_share 失败: $e');
    }
  }
}

final communityShareEnabledProvider =
    StateNotifierProvider<CommunityShareEnabledNotifier, bool>((ref) {
  return CommunityShareEnabledNotifier();
});

/// RFID 自动采用观测值 kill switch Provider（持久化，默认开启）。
class RfidAutoAdoptEnabledNotifier extends StateNotifier<bool> {
  RfidAutoAdoptEnabledNotifier() : super(true) {
    _load();
  }

  static const _key = 'killswitch_rfid_auto_adopt';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) state = prefs.getBool(_key) ?? true;
    } catch (e) {
      debugPrint('[KillSwitch] 加载 rfid_auto_adopt 失败: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (e) {
      debugPrint('[KillSwitch] 保存 rfid_auto_adopt 失败: $e');
    }
  }
}

final rfidAutoAdoptEnabledProvider =
    StateNotifierProvider<RfidAutoAdoptEnabledNotifier, bool>((ref) {
  return RfidAutoAdoptEnabledNotifier();
});

/// 参数实验自动入队 kill switch Provider（持久化，默认关闭）。
class ExperimentAutoEnqueueEnabledNotifier extends StateNotifier<bool> {
  ExperimentAutoEnqueueEnabledNotifier() : super(false) {
    _load();
  }

  static const _key = 'killswitch_experiment_auto_enqueue';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) state = prefs.getBool(_key) ?? false;
    } catch (e) {
      debugPrint('[KillSwitch] 加载 experiment_auto_enqueue 失败: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (e) {
      debugPrint('[KillSwitch] 保存 experiment_auto_enqueue 失败: $e');
    }
  }
}

final experimentAutoEnqueueEnabledProvider =
    StateNotifierProvider<ExperimentAutoEnqueueEnabledNotifier, bool>((ref) {
  return ExperimentAutoEnqueueEnabledNotifier();
});
