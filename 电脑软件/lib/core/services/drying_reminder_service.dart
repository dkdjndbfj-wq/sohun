import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/prefs/app_prefs.dart';
import '../../providers/database_provider.dart';
import '../../providers/printer_connection_provider.dart';
import 'error_logger.dart';
import 'notification_service.dart';

/// P1-创新1: 耗材干燥提醒服务。
///
/// **背景**：3D 打印耗材（特别是吸湿性强的材质）暴露在空气中会吸收水分，
/// 导致打印时出现拉丝、气泡、层间附着力下降等问题。吸湿后的耗材需要放入
/// 干燥箱烘干才能恢复性能。
///
/// **提醒策略**：按材质吸湿性分三档：
/// - **高吸湿**（TPU/Nylon/PC/PVA）：3 天未用建议干燥
/// - **中吸湿**（PETG/ABS/ASA/HIPS）：7 天未用建议干燥
/// - **低吸湿**（PLA/PLA+/PLA-Silk/PLA-CF）：14 天未用建议干燥
///
/// **触发时机**：
/// - 应用启动后 30 秒（等通知服务初始化完成）
/// - 每 6 小时定时检查一次（应用长时间运行时）
///
/// **判定依据**：耗材的 `updatedAt` 字段（任何克数变化都会更新此字段）。
/// 仅对剩余克数 > 0 的耗材检查（已用完的无需干燥）。
///
/// **去重**：同一卷耗材 24 小时内只提醒一次（避免反复弹窗打扰）。
class DryingReminderService {
  final Ref _ref;

  /// 已提醒记录：consumableId → 上次提醒时间
  /// 用于 24 小时去重，避免同一卷耗材反复弹窗
  final Map<int, DateTime> _notifiedMap = {};

  /// 定时检查定时器（6 小时一次）
  Timer? _periodicTimer;

  /// 启动延迟定时器（30 秒后首次检查）
  Timer? _startupTimer;

  static const Duration _startupDelay = Duration(seconds: 30);
  static const Duration _checkInterval = Duration(hours: 6);
  static const Duration _dedupWindow = Duration(hours: 24);

  DryingReminderService(this._ref);

  /// 启动干燥提醒服务。
  ///
  /// 在 app.dart initState 中调用（通知服务初始化之后）。
  /// 启动后 30 秒执行首次检查，之后每 6 小时检查一次。
  void start() {
    _startupTimer?.cancel();
    _periodicTimer?.cancel();
    _startupTimer = Timer(_startupDelay, _checkAll);
    _periodicTimer = Timer.periodic(_checkInterval, (_) => _checkAll());
    debugPrint('[DryingReminder] 服务已启动');
  }

  /// 停止服务（应用退出时调用）。
  void stop() {
    _startupTimer?.cancel();
    _periodicTimer?.cancel();
    _startupTimer = null;
    _periodicTimer = null;
    _notifiedMap.clear();
  }

  /// 立即执行一次检查（设置页"立即检查"按钮用）。
  Future<void> checkNow() async {
    await _checkAll();
  }

  /// 清除去重记录（用户手动操作后可重新提醒）。
  void clearNotifiedHistory() {
    _notifiedMap.clear();
  }

  /// 释放资源（Provider 被 dispose 时调用，避免 Timer 继续运行）。
  void dispose() {
    _startupTimer?.cancel();
    _periodicTimer?.cancel();
    _startupTimer = null;
    _periodicTimer = null;
    _notifiedMap.clear();
  }

  Future<void> _checkAll() async {
    try {
      // 检查用户是否启用干燥提醒（默认启用）
      final enabled = _ref.read(dryingReminderEnabledProvider);
      if (!enabled) return;

      final dao = _ref.read(consumableDaoProvider);
      final consumables = await dao.getAll();
      // v12：批量查 hygroscopicity 字段，优先用 DB 设置的档位，回退材质推断
      final paramsMap = await dao.getParamsMap(
        consumables.map((c) => c.id).toList(),
      );

      // 清理过期的去重记录（超过 24 小时的）
      final now = DateTime.now();
      _notifiedMap.removeWhere(
        (id, time) => now.difference(time) > _dedupWindow,
      );

      // v12：读取活跃打印机的 AMS 环境湿度（AMS 2 Pro / AMS HT 推送）。
      // 高湿度环境下耗材吸湿加速，提前触发提醒（阈值减半）。
      // 老 AMS 不推送湿度，amsHumidity 为 null，按原阈值判断。
      final amsHumidity =
          _ref.read(activePrinterConnectionProvider).status?.amsHumidity;
      // 湿度>60% 视为高湿环境，提醒阈值减半（向上取整，至少 1 天）
      final highHumidity = amsHumidity != null && amsHumidity > 60;

      // 按材质分组需要干燥的耗材
      final needDrying = <_DryingCandidate>[];
      for (final c in consumables) {
        // 已用完的耗材无需干燥
        if (c.remainingGrams <= 0) continue;

        // v12：优先用 DB 的 hygroscopicity，回退材质名推断
        final hygro = paramsMap[c.id]?.hygroscopicity;
        var threshold = hygro != null
            ? _daysByHygroscopicity(hygro)
            : _getDryingThresholdDays(c.materialType);
        if (threshold == null) continue; // 未知材质不提醒

        // v12：高湿度环境阈值减半（耗材吸湿加速）
        if (highHumidity) {
          threshold = (threshold / 2).ceil().clamp(1, threshold);
        }

        final daysSinceUpdate = now.difference(c.updatedAt).inDays;
        if (daysSinceUpdate < threshold) continue;

        // 去重：24 小时内已提醒过则跳过
        final lastNotified = _notifiedMap[c.id];
        if (lastNotified != null &&
            now.difference(lastNotified) < _dedupWindow) {
          continue;
        }

        needDrying.add(
          _DryingCandidate(
            consumable: c,
            daysIdle: daysSinceUpdate,
            thresholdDays: threshold,
          ),
        );
        _notifiedMap[c.id] = now;
      }

      if (needDrying.isEmpty) return;

      // 发送通知
      await _notify(needDrying);
    } catch (e, st) {
      debugPrint('[DryingReminder] 检查失败: $e');
      // 提醒失败不影响主流程，记录到 ErrorLogger
      try {
        ErrorLogger.log(
          e,
          st,
          source: 'drying_reminder',
          level: ErrorLevel.warning,
          context: {'phase': 'check_all'},
        );
      } catch (_) {
        // ErrorLogger 可能未初始化，忽略
      }
    }
  }

  /// 发送干燥提醒通知。
  ///
  /// 单卷耗材：显示品牌+型号+材质。
  /// 多卷耗材：显示数量 + 最旧的几卷。
  Future<void> _notify(List<_DryingCandidate> candidates) async {
    final notif = _ref.read(notificationServiceProvider);

    if (candidates.length == 1) {
      final c = candidates.first.consumable;
      const title = '耗材干燥提醒';
      final body = '${c.manufacturer} ${c.model}'
          '（${c.materialType}）已 ${candidates.first.daysIdle} 天未使用，'
          '建议放入干燥箱烘干后再打印，避免拉丝和气泡。';
      await notif.alert(
        type: AlertType.dryingNeeded,
        title: title,
        body: body,
      );
      return;
    }

    // 多卷：按闲置天数倒序，取前 3 卷展示
    candidates.sort((a, b) => b.daysIdle.compareTo(a.daysIdle));
    final top = candidates.take(3).map((c) {
      return '${c.consumable.manufacturer} ${c.consumable.model}'
          '（${c.daysIdle}天）';
    }).join('、');

    final title = '耗材干燥提醒（${candidates.length} 卷）';
    final body = '以下耗材已超过建议干燥周期：$top'
        '${candidates.length > 3 ? ' 等 ${candidates.length} 卷' : ''}。'
        '建议放入干燥箱烘干后再打印。';
    await notif.alert(
      type: AlertType.dryingNeeded,
      title: title,
      body: body,
    );
  }

  /// 获取材质对应的干燥提醒阈值（天数）。
  ///
  /// 返回 null 表示该材质不提醒（未知材质）。
  ///
  /// **CF/GF 增强材料处理**：
  /// 碳纤维/玻璃纤维增强材料因纤维毛细作用，实际比基础材料更易吸湿，
  /// 阈值应降一档（PLA-CF 从低 14 天降到中 7 天，PA-CF 已是高 3 天不变）。
  static int? _getDryingThresholdDays(String? materialType) {
    if (materialType == null || materialType.isEmpty) return null;
    final normalized = materialType.toLowerCase();
    final isReinforced =
        normalized.contains('-cf') || normalized.contains('-gf');

    // PC 精确匹配：避免 'pctg' 被误判为 PC 高档（PCTG 是中档 7 天）
    // PC 单独使用或 PC-FR/PC-Abs 才归高档
    if (normalized == 'pc' || normalized.startsWith('pc-')) return 3;

    // 高吸湿性：3 天（CF/GF 增强的不降档，已是最高档）
    for (final m in _highAbsorption) {
      if (normalized.contains(m)) return 3;
    }
    // 中吸湿性：7 天
    for (final m in _mediumAbsorption) {
      if (normalized.contains(m)) return 7;
    }
    // 低吸湿性：14 天
    // CF/GF 增强材料升级到中吸湿性 7 天（碳纤维毛细作用加速吸湿）
    if (isReinforced) {
      // 检查是否是 PLA 系列的 CF/GF（PLA-CF、PLA-GF）
      for (final m in _lowAbsorption) {
        if (normalized.contains(m)) return 7; // 降档到中
      }
    }
    for (final m in _lowAbsorption) {
      if (normalized.contains(m)) return 14;
    }
    // 未知材质不提醒（避免误报）
    return null;
  }

  /// v12：按 hygroscopicity 字段返回阈值天数（用户手动设置的档位优先）。
  ///
  /// 'high'→3, 'medium'→7, 'low'→14，其他返回 null（回退材质推断）。
  static int? _daysByHygroscopicity(String? hygro) {
    switch (hygro) {
      case 'high':
        return 3;
      case 'medium':
        return 7;
      case 'low':
        return 14;
      default:
        return null;
    }
  }

  /// 高吸湿性材质关键字（3 天阈值）
  /// 含 PA 全系列（PA/PA6/PA12/PAHT）、TPU、PVA、BVOH、PPA、PEEK、PEI。
  /// CF/GF 增强的 PA 系列已在高档，不降档。
  /// 注意：PC 不在此列表，因 'pc' 会误匹配 'pctg'，PC 由精确匹配逻辑处理。
  static const List<String> _highAbsorption = [
    'tpu',
    'tpe',
    'nylon',
    'pa',
    'pa-cf',
    'pa6',
    'pa12',
    'paht',
    'pva',
    'hips',
    'bvoh', // 水溶材料，极度吸湿
    'ppa',
    'peek',
    'pei',
  ];

  /// 中吸湿性材质关键字（7 天阈值）
  /// 含 PETG/PET 全系列、ABS/ASA、PPS。
  /// PET-CF 拓竹标"超低吸湿"，但保守归中档（避免漏提醒）。
  static const List<String> _mediumAbsorption = [
    'petg',
    'pet',
    'abs',
    'asa',
    'petg-cf',
    'pet-cf',
    'pctg',
    'pps',
  ];

  /// 低吸湿性材质关键字（14 天阈值）
  /// 含 PLA 全系列（含美学衍生型号）、PE、PP。
  /// CF/GF 增强的 PLA 系列会被 [isReinforced] 逻辑降档到中 7 天。
  static const List<String> _lowAbsorption = [
    'pla',
    'pls',
    'pla+',
    'pla-silk',
    'pla-cf',
    'pla-matte',
    'pla-gf',
    'pe',
    'pp',
  ];
}

/// 干燥提醒候选项（内部用）
class _DryingCandidate {
  final Consumable consumable;
  final int daysIdle;
  final int thresholdDays;

  const _DryingCandidate({
    required this.consumable,
    required this.daysIdle,
    required this.thresholdDays,
  });
}

/// 干燥提醒服务 Provider（全局单例）
final dryingReminderServiceProvider = Provider<DryingReminderService>((ref) {
  return DryingReminderService(ref);
});
