import 'package:shared_preferences/shared_preferences.dart';

/// 切片文件读取方式。
///
/// - [onDemand]（默认）：不监听目录，MQTT 收到 running 事件时按 gcode 文件名
///   去切片输出目录一次性查找并解析。资源占用最低。
/// - [watch]：持续监听切片输出目录，切片完成即解析缓存。提前缓存，打印开始时零延迟。
enum SliceReadMode {
  onDemand,
  watch,
}

/// 切片软件路径持久化。
///
/// 保存用户手动指定的切片软件可执行文件路径和输出目录覆盖值。
/// 为 null 时表示未设置（回退到自动检测）。
///
/// exe 路径与输出目录按拓竹云账号隔离（多账号场景下各账号独立配置），
/// 切换账号后自动加载该账号的配置；未登录或未配置过则返回 null 走自动检测。
/// 读取方式（readMode）为个人偏好，全局共享不按账号隔离。
class SlicerPrefs {
  SlicerPrefs._();

  static const _exeKeyPrefix = 'slicer_exe_override::';
  static const _outKeyPrefix = 'slicer_output_override::';
  static const _readModeKey = 'slicer_read_mode';
  static const _activeSlicerIdKey = 'slicer_active_id';
  static const _bambuStudioVerKey = 'bambu_studio_version_override';
  static const _networkAgentStudioVerKey =
      'network_agent_studio_version_override';

  /// 未登录时使用的账号占位 key。
  static const _globalAccountKey = '__global__';

  static String _key(String prefix, String? accountKey) {
    final k = (accountKey == null || accountKey.isEmpty)
        ? _globalAccountKey
        : accountKey;
    return '$prefix$k';
  }

  /// 获取切片软件可执行文件覆盖路径。
  /// [accountKey] 为 "email|region_code" 格式，未登录传 null。
  ///
  /// 跨模式继承：已登录账号但账号专属槽位为空时，回退读 `__global__` 槽位，
  /// 确保 LAN-only 阶段配置的切片路径在登录云账号后仍可用。
  static Future<String?> getExeOverride({String? accountKey}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(_exeKeyPrefix, accountKey);
    final v = prefs.getString(key);
    if (v != null) return v;
    // 账号专属槽位为空且当前非全局 key → 回退读全局槽位
    if (accountKey != null && accountKey.isNotEmpty) {
      return prefs.getString(_key(_exeKeyPrefix, null));
    }
    return null;
  }

  /// 设置切片软件可执行文件覆盖路径。
  /// 传 null 清除该账号的配置。
  static Future<void> setExeOverride(
    String? value, {
    required String? accountKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(_exeKeyPrefix, accountKey);
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }

  /// 获取切片软件输出目录覆盖路径。
  /// [accountKey] 为 "email|region_code" 格式，未登录传 null。
  ///
  /// 跨模式继承：同 [getExeOverride]，账号专属槽位为空时回退读全局槽位。
  static Future<String?> getOutputOverride({String? accountKey}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(_outKeyPrefix, accountKey);
    final v = prefs.getString(key);
    if (v != null) return v;
    if (accountKey != null && accountKey.isNotEmpty) {
      return prefs.getString(_key(_outKeyPrefix, null));
    }
    return null;
  }

  /// 设置切片软件输出目录覆盖路径。
  /// 传 null 清除该账号的配置。
  static Future<void> setOutputOverride(
    String? value, {
    required String? accountKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _key(_outKeyPrefix, accountKey);
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }

  /// 获取切片文件读取方式（默认 onDemand）。
  /// 读取方式为个人偏好，全局共享不按账号隔离。
  static Future<SliceReadMode> getReadMode() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_readModeKey);
    return v == 'watch' ? SliceReadMode.watch : SliceReadMode.onDemand;
  }

  /// 设置切片文件读取方式。
  static Future<void> setReadMode(SliceReadMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_readModeKey, mode.name);
  }

  /// 获取当前选中的切片软件 ID。
  ///
  /// 返回 null 表示用户尚未选择，调用方应使用其默认切片器。
  static Future<String?> getActiveSlicerId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeSlicerIdKey);
  }

  /// 持久化当前选中的切片软件 ID。
  ///
  /// 传 null 或空串会清除选择，恢复调用方默认值。
  static Future<void> setActiveSlicerId(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_activeSlicerIdKey);
    } else {
      await prefs.setString(_activeSlicerIdKey, value);
    }
  }

  /// 获取 BambuStudio 模拟版本号覆盖值（用于上传预设/解绑设备接口）。
  /// 返回 null 表示用代码默认值。
  static Future<String?> getBambuStudioVersionOverride() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_bambuStudioVerKey);
  }

  /// 设置 BambuStudio 模拟版本号覆盖值。
  /// 传 null 或空串清除覆盖，恢复默认值。
  static Future<void> setBambuStudioVersionOverride(String? value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_bambuStudioVerKey);
    } else {
      await prefs.setString(_bambuStudioVerKey, value);
    }
  }

  /// 获取 bambu_network_agent 版本号覆盖值（BambuStudio 系列）。
  static Future<String?> getNetworkAgentStudioVersionOverride() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_networkAgentStudioVerKey);
  }

  /// 设置 bambu_network_agent 版本号覆盖值（BambuStudio 系列）。
  static Future<void> setNetworkAgentStudioVersionOverride(
    String? value,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    if (value == null || value.isEmpty) {
      await prefs.remove(_networkAgentStudioVerKey);
    } else {
      await prefs.setString(_networkAgentStudioVerKey, value);
    }
  }
}
