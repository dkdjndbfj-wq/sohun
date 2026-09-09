import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/app_variant.dart';
import '../../core/utils/autostart_helper.dart';
import '../../providers/app_auth_provider.dart';

/// 全局应用偏好设置（非切片/主题/账号相关的杂项开关）。
///
/// 当前包含：
/// - [isDryingReminderEnabled]：耗材干燥提醒开关（默认启用）
/// - [isAnomalyDetectionEnabled]：耗材消耗异常检测开关（默认启用）
/// - [isBgDecorationEnabled]：桌面 mesh 光斑装饰开关（默认启用）
/// - [isInteractionEffectsEnabled]：桌面交互动效开关（默认启用）
/// - [isAutostartEnabled]：开机自启开关（默认关闭）
/// - 自动检查更新、关闭到托盘和通知分类开关
class AppPrefs {
  AppPrefs._();

  static const _dryingReminderKey = 'drying_reminder_enabled';
  static const _anomalyDetectionKey = 'anomaly_detection_enabled';
  static const _bgDecorationKey = 'bg_decoration_enabled';
  static const _interactionEffectsKey = 'interaction_effects_enabled';
  static const _autostartKey = 'autostart_enabled';
  static const _externalFilamentColorReminderKey =
      'external_filament_color_reminder_enabled';
  static const _autoCheckUpdatesKey = 'auto_check_updates_enabled';
  static const _closeToTrayKey = 'close_to_tray_enabled';
  static const _notificationsEnabledKey = 'notifications_enabled';
  static const _printNotificationsEnabledKey = 'print_notifications_enabled';
  static const _printerFaultPopupsKey = 'printer_fault_popups_enabled';
  static const _materialNotificationsEnabledKey =
      'material_notifications_enabled';
  static const _studioModeEnabledKey = 'studio_mode_enabled';
  static const _inventoryDetailLevelKey = 'inventory_detail_level';

  static Future<bool> getInventoryFineDetailEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_inventoryDetailLevelKey) == 'fine';
  }

  static Future<void> setInventoryFineDetailEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_inventoryDetailLevelKey, value ? 'fine' : 'simple');
  }

  /// 读取干燥提醒开关（默认 true）
  static Future<bool> getDryingReminderEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_dryingReminderKey) ?? true;
  }

  /// 写入干燥提醒开关
  static Future<void> setDryingReminderEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_dryingReminderKey, value);
  }

  /// 读取异常检测开关（默认 true）
  static Future<bool> getAnomalyDetectionEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_anomalyDetectionKey) ?? true;
  }

  /// 写入异常检测开关
  static Future<void> setAnomalyDetectionEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_anomalyDetectionKey, value);
  }

  /// 读取背景装饰开关（默认 true）
  static Future<bool> getBgDecorationEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_bgDecorationKey) ?? true;
  }

  /// 写入背景装饰开关
  static Future<void> setBgDecorationEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bgDecorationKey, value);
  }

  /// 读取交互动效开关（默认 true）。
  static Future<bool> getInteractionEffectsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_interactionEffectsKey) ?? true;
  }

  /// 写入交互动效开关。
  static Future<void> setInteractionEffectsEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_interactionEffectsKey, value);
  }

  /// 读取开机自启开关（默认 false）
  static Future<bool> getAutostartEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autostartKey) ?? false;
  }

  /// 写入开机自启开关
  static Future<void> setAutostartEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autostartKey, value);
  }

  /// 读取外挂料换色提醒开关（默认 true）。
  ///
  /// 开启后，外挂料多色打印时软件会提前 N 层预告下次换色，
  /// 并在打印机暂停换料时弹窗提示要换的颜色。
  /// 软件会自动检测 G-code 是否含换料指令，无换料指令时不打扰用户。
  static Future<bool> getExternalFilamentColorReminderEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_externalFilamentColorReminderKey) ?? true;
  }

  /// 写入外挂料换色提醒开关
  static Future<void> setExternalFilamentColorReminderEnabled(
    bool value,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_externalFilamentColorReminderKey, value);
  }

  static Future<bool> getAutoCheckUpdatesEnabled() =>
      _getBool(_autoCheckUpdatesKey, true);

  static Future<void> setAutoCheckUpdatesEnabled(bool value) =>
      _setBool(_autoCheckUpdatesKey, value);

  static Future<bool> getCloseToTrayEnabled() =>
      _getBool(_closeToTrayKey, true);

  static Future<void> setCloseToTrayEnabled(bool value) =>
      _setBool(_closeToTrayKey, value);

  static Future<bool> getNotificationsEnabled() =>
      _getBool(_notificationsEnabledKey, true);

  static Future<void> setNotificationsEnabled(bool value) =>
      _setBool(_notificationsEnabledKey, value);

  static Future<bool> getPrintNotificationsEnabled() =>
      _getBool(_printNotificationsEnabledKey, true);

  static Future<void> setPrintNotificationsEnabled(bool value) =>
      _setBool(_printNotificationsEnabledKey, value);
  static Future<bool> getPrinterFaultPopupsEnabled() => _getBool(_printerFaultPopupsKey, true);
  static Future<void> setPrinterFaultPopupsEnabled(bool value) => _setBool(_printerFaultPopupsKey, value);

  static Future<bool> getMaterialNotificationsEnabled() =>
      _getBool(_materialNotificationsEnabledKey, true);

  static Future<void> setMaterialNotificationsEnabled(bool value) =>
      _setBool(_materialNotificationsEnabledKey, value);

  static Future<bool> getStudioModeEnabled() =>
      _getBool(_studioModeEnabledKey, false);

  static Future<void> setStudioModeEnabled(bool value) =>
      _setBool(_studioModeEnabledKey, value);

  static Future<bool> _getBool(String key, bool fallback) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? fallback;
  }

  static Future<void> _setBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}

/// 干燥提醒开关 Provider（持久化，默认启用）。
///
/// 关闭后 [DryingReminderService] 不会发送任何干燥提醒通知。
class DryingReminderEnabledNotifier extends StateNotifier<bool> {
  DryingReminderEnabledNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final v = await AppPrefs.getDryingReminderEnabled();
    if (mounted) state = v;
  }

  Future<void> setEnabled(bool value) async {
    await AppPrefs.setDryingReminderEnabled(value);
    state = value;
  }
}

final dryingReminderEnabledProvider =
    StateNotifierProvider<DryingReminderEnabledNotifier, bool>((ref) {
  return DryingReminderEnabledNotifier();
});

/// 异常检测开关 Provider（持久化，默认启用）。
///
/// 关闭后 [AnomalyDetectionService] 不会发送任何消耗异常告警通知。
class AnomalyDetectionEnabledNotifier extends StateNotifier<bool> {
  AnomalyDetectionEnabledNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final v = await AppPrefs.getAnomalyDetectionEnabled();
    if (mounted) state = v;
  }

  Future<void> setEnabled(bool value) async {
    await AppPrefs.setAnomalyDetectionEnabled(value);
    state = value;
  }
}

final anomalyDetectionEnabledProvider =
    StateNotifierProvider<AnomalyDetectionEnabledNotifier, bool>((ref) {
  return AnomalyDetectionEnabledNotifier();
});

/// 背景装饰开关 Provider（持久化，默认启用）。
///
/// P0-7 修复：原 settings_sheet 中"背景动效"开关 onChanged 为空实现。
/// 现接入 [AppBackground]，关闭后隐藏 mesh 光斑装饰（保留渐变底色）。
class BgDecorationEnabledNotifier extends StateNotifier<bool> {
  BgDecorationEnabledNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final v = await AppPrefs.getBgDecorationEnabled();
    if (mounted) state = v;
  }

  Future<void> setEnabled(bool value) async {
    await AppPrefs.setBgDecorationEnabled(value);
    state = value;
  }
}

final bgDecorationEnabledProvider =
    StateNotifierProvider<BgDecorationEnabledNotifier, bool>((ref) {
  return BgDecorationEnabledNotifier();
});

/// 全局交互动效开关（持久化，默认启用）。
class InteractionEffectsEnabledNotifier extends StateNotifier<bool> {
  InteractionEffectsEnabledNotifier({
    bool initialValue = true,
    bool loadPersisted = true,
  }) : super(initialValue) {
    if (loadPersisted) _load();
  }

  Future<void> _load() async {
    final value = await AppPrefs.getInteractionEffectsEnabled();
    if (mounted) state = value;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await AppPrefs.setInteractionEffectsEnabled(value);
  }
}

final interactionEffectsEnabledProvider =
    StateNotifierProvider<InteractionEffectsEnabledNotifier, bool>((ref) {
  return InteractionEffectsEnabledNotifier();
});

/// 开机自启开关 Provider（持久化，默认关闭）。
///
/// P0-7 修复：原 settings_sheet 中"开机自启"开关 onChanged 为空实现。
/// 现通过 [AutostartHelper] 操作 Windows 注册表实现真实开机自启。
class AutostartEnabledNotifier extends StateNotifier<bool> {
  AutostartEnabledNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final v = await AppPrefs.getAutostartEnabled();
    if (mounted) state = v;
  }

  /// 设置开机自启：同步注册表 + 持久化偏好。
  /// 注册表操作失败时回滚 state，保证 UI 与实际状态一致。
  ///
  /// 返回是否设置成功。调用方（设置页）应在返回 false 时提示用户，
  /// 否则开关会无声回弹，看起来像界面卡住。
  Future<bool> setEnabled(bool value) async {
    final ok = await AutostartHelper.setEnabled(value);
    if (ok) {
      await AppPrefs.setAutostartEnabled(value);
      state = value;
    }
    return ok;
  }
}

final autostartEnabledProvider =
    StateNotifierProvider<AutostartEnabledNotifier, bool>((ref) {
  return AutostartEnabledNotifier();
});

/// 外挂料换色提醒开关 Provider（持久化，默认启用）。
///
/// 关闭后 [FilamentChangeReminderService] 不会发送任何换色预告/弹窗提醒。
/// 软件会自动检测 G-code 是否含换料指令（T/M600/M620/M400 U1），
/// 无换料指令时即使开关开启也不会打扰用户。
class ExternalFilamentColorReminderEnabledNotifier extends StateNotifier<bool> {
  ExternalFilamentColorReminderEnabledNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final v = await AppPrefs.getExternalFilamentColorReminderEnabled();
    if (mounted) state = v;
  }

  Future<void> setEnabled(bool value) async {
    await AppPrefs.setExternalFilamentColorReminderEnabled(value);
    state = value;
  }
}

final externalFilamentColorReminderProvider =
    StateNotifierProvider<ExternalFilamentColorReminderEnabledNotifier, bool>(
        (ref) {
  return ExternalFilamentColorReminderEnabledNotifier();
});

class AppBooleanPreferenceNotifier extends StateNotifier<bool> {
  AppBooleanPreferenceNotifier({
    required bool defaultValue,
    required Future<bool> Function() load,
    required Future<void> Function(bool) save,
  })  : _loadPreference = load,
        _savePreference = save,
        super(defaultValue) {
    _load();
  }

  final Future<bool> Function() _loadPreference;
  final Future<void> Function(bool) _savePreference;

  Future<void> _load() async {
    final value = await _loadPreference();
    if (mounted) state = value;
  }

  Future<void> setEnabled(bool value) async {
    state = value;
    await _savePreference(value);
  }
}

final autoCheckUpdatesProvider =
    StateNotifierProvider<AppBooleanPreferenceNotifier, bool>((ref) {
  return AppBooleanPreferenceNotifier(
    defaultValue: true,
    load: AppPrefs.getAutoCheckUpdatesEnabled,
    save: AppPrefs.setAutoCheckUpdatesEnabled,
  );
});

final closeToTrayProvider =
    StateNotifierProvider<AppBooleanPreferenceNotifier, bool>((ref) {
  return AppBooleanPreferenceNotifier(
    defaultValue: true,
    load: AppPrefs.getCloseToTrayEnabled,
    save: AppPrefs.setCloseToTrayEnabled,
  );
});

final notificationsEnabledProvider =
    StateNotifierProvider<AppBooleanPreferenceNotifier, bool>((ref) {
  return AppBooleanPreferenceNotifier(
    defaultValue: true,
    load: AppPrefs.getNotificationsEnabled,
    save: AppPrefs.setNotificationsEnabled,
  );
});

final printNotificationsEnabledProvider =
    StateNotifierProvider<AppBooleanPreferenceNotifier, bool>((ref) {
  return AppBooleanPreferenceNotifier(
    defaultValue: true,
    load: AppPrefs.getPrintNotificationsEnabled,
    save: AppPrefs.setPrintNotificationsEnabled,
  );
});

final printerFaultPopupsEnabledProvider =
    StateNotifierProvider<AppBooleanPreferenceNotifier, bool>((ref) => AppBooleanPreferenceNotifier(
      defaultValue: true, load: AppPrefs.getPrinterFaultPopupsEnabled, save: AppPrefs.setPrinterFaultPopupsEnabled));

final materialNotificationsEnabledProvider =
    StateNotifierProvider<AppBooleanPreferenceNotifier, bool>((ref) {
  return AppBooleanPreferenceNotifier(
    defaultValue: true,
    load: AppPrefs.getMaterialNotificationsEnabled,
    save: AppPrefs.setMaterialNotificationsEnabled,
  );
});

final inventoryFineDetailProvider =
    StateNotifierProvider<AppBooleanPreferenceNotifier, bool>((ref) {
  return AppBooleanPreferenceNotifier(
    defaultValue: false,
    load: AppPrefs.getInventoryFineDetailEnabled,
    save: AppPrefs.setInventoryFineDetailEnabled,
  );
});

/// 当前产品是否为农场版。
///
/// 工作台由构建产物决定，而不是由登录会话或历史偏好决定。这样两个已
/// 安装的产品始终保持独立，也不会在切换账号后跳进另一款软件的界面。
class StudioModeNotifier extends StateNotifier<bool> {
  StudioModeNotifier(Ref ref) : super(AppVariant.isFarm) {
    ref.listen<AppAuthState>(
      appAuthProvider,
      _onAuthChanged,
      fireImmediately: true,
    );
  }

  void _onAuthChanged(AppAuthState? previous, AppAuthState next) {
    if (next.status == AppAuthStatus.initializing) return;
    final enabled = AppVariant.isFarm;
    if (state != enabled) state = enabled;
  }

  Future<void> setEnabled(bool requested) async {
    // Retain a deterministic stored value for older preference readers, but
    // never let a setting alter which desktop product is running.
    final enabled = AppVariant.isFarm;
    if (state != enabled) state = enabled;
    await AppPrefs.setStudioModeEnabled(enabled);
  }
}

final studioModeEnabledProvider =
    StateNotifierProvider<StudioModeNotifier, bool>((ref) {
  return StudioModeNotifier(ref);
});
