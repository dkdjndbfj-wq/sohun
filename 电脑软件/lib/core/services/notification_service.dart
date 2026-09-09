import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../app_identity.dart';
import '../../data/prefs/app_prefs.dart';
import 'theme_icon_service.dart';

// Ref 引用保留以便未来扩展（如读取其他 provider 状态）

/// 告警级别。
enum AlertLevel { info, warning, error, success }

/// 告警事件类型。
enum AlertType {
  printerFault('打印机故障'),
  printFailed('打印失败'),
  printerOffline('打印机离线'),
  amsFilamentEmpty('料卷耗尽'),
  amsFilamentInserted('检测到新耗材'),
  lowStock('库存预警'),
  printFinished('打印完成'),
  printCancelled('打印异常取消'),
  dryingNeeded('耗材干燥提醒'),
  consumptionAnomaly('耗材消耗异常'),
  batchAnomaly('批次异常对比'),
  unattendedBlocked('无人值守暂停'),
  filamentChange('换色提醒'),
  appUpdate('应用更新');

  final String label;
  const AlertType(this.label);
}

/// 通知服务。
///
/// 基于 [local_notifier] 的 Windows Toast 通知 + [trayManager] 托盘图标更新。
/// 即使应用最小化到托盘，也能弹出系统级通知。
///
/// 使用方式：
/// - 应用启动时调用 [init]（在 app.dart initState 中）
/// - 全局通过 [notificationServiceProvider] 读取实例
/// - 调用 [notify] 发送通知
/// - 调用 [clearAlert] 恢复托盘图标
class NotificationService {
  NotificationService(this._themeIconService);

  final ThemeIconService _themeIconService;

  bool _initialized = false;
  bool _hasActiveAlert = false;
  bool _enabled = true;
  bool _printEnabled = true;
  bool _materialEnabled = true;

  void configure({
    bool? enabled,
    bool? printEnabled,
    bool? materialEnabled,
  }) {
    _enabled = enabled ?? _enabled;
    _printEnabled = printEnabled ?? _printEnabled;
    _materialEnabled = materialEnabled ?? _materialEnabled;
  }

  /// 应用启动时初始化。
  Future<void> init() async {
    if (_initialized) return;
    try {
      await localNotifier.setup(
        appName: AppIdentity.name,
        // shortName 用于 Windows 通知中心标识
        shortcutPolicy: ShortcutPolicy.ignore,
      );
      _initialized = true;
      debugPrint('[NotificationService] 初始化完成');
    } catch (e) {
      debugPrint('[NotificationService] 初始化失败: $e');
    }
  }

  /// 发送通知。
  ///
  /// [title] 通知标题，[body] 通知正文，[level] 决定图标与紧迫程度。
  /// 同时更新托盘 tooltip 提示，并在有未处理告警时切换托盘图标。
  Future<void> notify({
    required String title,
    required String body,
    AlertLevel level = AlertLevel.info,
    AlertType? type,
    VoidCallback? onClick,
  }) async {
    if (!_allows(type)) return;
    // 1. 系统 Toast 通知
    if (_initialized) {
      try {
        final notification = LocalNotification(
          title: title,
          body: body,
        );
        // onClick 是字段属性，构造后赋值
        notification.onClick = onClick ?? () => windowManager.show();
        await notification.show();
      } catch (e) {
        debugPrint('[NotificationService] 通知发送失败: $e');
      }
    }

    // 2. 更新托盘 tooltip
    try {
      final icon = _hasActiveAlert ? '⚠️ ' : '';
      await trayManager.setToolTip('$icon$title：$body');
      // 错误/警告级别标记为活跃告警，切换图标
      if (level == AlertLevel.error || level == AlertLevel.warning) {
        _hasActiveAlert = true;
      }
    } catch (_) {}
  }

  /// 便捷方法：发送告警级别通知。
  Future<void> alert({
    required AlertType type,
    required String title,
    required String body,
    VoidCallback? onClick,
  }) async {
    final level = switch (type) {
      AlertType.printFailed => AlertLevel.error,
      AlertType.printerFault => AlertLevel.error,
      AlertType.printerOffline => AlertLevel.error,
      AlertType.amsFilamentEmpty => AlertLevel.warning,
      AlertType.amsFilamentInserted => AlertLevel.info,
      AlertType.lowStock => AlertLevel.warning,
      AlertType.printCancelled => AlertLevel.warning,
      AlertType.dryingNeeded => AlertLevel.warning,
      AlertType.consumptionAnomaly => AlertLevel.warning,
      AlertType.batchAnomaly => AlertLevel.warning,
      AlertType.unattendedBlocked => AlertLevel.warning,
      AlertType.filamentChange => AlertLevel.warning,
      AlertType.printFinished => AlertLevel.success,
      AlertType.appUpdate => AlertLevel.info,
    };
    await notify(
      title: title,
      body: body,
      level: level,
      type: type,
      onClick: onClick,
    );
  }

  /// 清除告警状态（恢复托盘图标和 tooltip）。
  Future<void> clearAlert() async {
    if (!_hasActiveAlert) return;
    _hasActiveAlert = false;
    try {
      await trayManager.setToolTip(AppIdentity.trayTooltip);
      await _themeIconService.restoreTrayIcon();
    } catch (_) {}
  }

  bool get hasActiveAlert => _hasActiveAlert;

  bool _allows(AlertType? type) {
    if (!_enabled) return false;
    if (type == null || type == AlertType.appUpdate) return true;
    const printTypes = {
      AlertType.printFailed,
      AlertType.printerFault,
      AlertType.printerOffline,
      AlertType.printFinished,
      AlertType.printCancelled,
      AlertType.unattendedBlocked,
    };
    return printTypes.contains(type) ? _printEnabled : _materialEnabled;
  }
}

/// 通知服务 Provider（全局单例）。
final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService(ref.watch(themeIconServiceProvider));
  service.configure(
    enabled: ref.read(notificationsEnabledProvider),
    printEnabled: ref.read(printNotificationsEnabledProvider),
    materialEnabled: ref.read(materialNotificationsEnabledProvider),
  );
  ref.listen<bool>(notificationsEnabledProvider, (_, next) {
    service.configure(enabled: next);
  });
  ref.listen<bool>(printNotificationsEnabledProvider, (_, next) {
    service.configure(printEnabled: next);
  });
  ref.listen<bool>(materialNotificationsEnabledProvider, (_, next) {
    service.configure(materialEnabled: next);
  });
  return service;
});
