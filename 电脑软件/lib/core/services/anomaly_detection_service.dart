import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/models/print_task.dart';
import '../../data/database/models/print_task_consumable.dart';
import '../../data/prefs/app_prefs.dart';
import '../../providers/database_provider.dart';
import 'error_logger.dart';
import 'notification_service.dart';

/// P1-创新2: 耗材消耗异常检测服务。
///
/// **背景**：实时扣减 + 终态结算策略依赖切片预估的准确性。如果切片文件
/// 与实际打印不匹配、AMS 通道映射错误、或多色任务某卷消耗异常，
/// 会导致库存与实际严重偏离，用户却毫不知情。本服务在扣减/结算关键点
/// 插入轻量检测，及时发现异常并告警。
///
/// **检测规则**：
/// 1. **单次扣减过大**（实时扣减阶段）：本次扣减量 delta 超过预估 × 50% 且 > 5g
///    - 典型场景：切片预估错误、mcPercent 跳变（如打印机重启后从 0 跳到 80）
/// 2. **结算远超预估**（结算阶段）：finalConsumed > estimatedGrams × 1.5 且 > 5g
///    - 典型场景：切片耗材计算偏小、实际多色切换有额外耗材损耗
/// 3. **结算远低于预估**（结算阶段）：finalConsumed < estimatedGrams × 0.3 且 > 5g 且任务未取消
///    - 典型场景：实际只用了某卷少量耗材（颜色切换比切片假设的少）
/// 4. **Z-score 异常**（结算阶段）：与同材质耗材卷历史消耗记录比较，偏离均值超过 2σ
///    - 典型场景：该卷被异常使用（如其他打印机误用、人工抽走一段）
///
/// **告警去重**：每条关联记录（ptc.id）在整个任务生命周期内只告警一次（用 Set 缓存）。
/// 避免实时扣减阶段高频推送导致反复告警。
///
/// **告警通道**：NotificationService（Toast）+ ErrorLogger（数据库日志，便于回溯）。
class AnomalyDetectionService {
  final Ref _ref;

  /// 已告警的关联记录 id 集合（去重用，防止同一异常反复告警）。
  /// key = ptc.id。任务结算后不再触发，自然不会重复。
  /// 资源修复：原实现结算后已清理，但实时检测路径未结算退出会残留。
  /// 加上限 2000，超限时清一半，防止极端场景内存增长。
  final Set<int> _alertedEntryIds = {};
  static const int _maxAlertedCache = 2000;

  void _trimAlertedCacheIfNeeded() {
    if (_alertedEntryIds.length > _maxAlertedCache) {
      final keep = _alertedEntryIds.skip(_alertedEntryIds.length ~/ 2).toSet();
      _alertedEntryIds
        ..clear()
        ..addAll(keep);
    }
  }

  /// Z-score 检测的最小样本数（不足此数不检测，避免小样本统计无意义）。
  static const int _minSampleSize = 5;

  /// Z-score 异常阈值（|z| > 2 视为异常，对应 95% 置信区间外）。
  static const double _zScoreThreshold = 2.0;

  AnomalyDetectionService(this._ref);

  /// 检测实时扣减异常。
  ///
  /// 在 [PrintTaskOrchestrator._doDeductConsumables] 每次扣减后调用。
  /// 只检测规则 1（单次扣减过大），避免实时阶段频繁查库影响性能。
  ///
  /// [task] 当前打印任务，[entry] 当前关联记录，[delta] 本次扣减量（正数），
  /// [mcPercent] 当前进度百分比。
  Future<void> detectRealtimeDeduction({
    required PrintTask task,
    required PrintTaskConsumable entry,
    required double delta,
    required int mcPercent,
  }) async {
    try {
      final enabled = _ref.read(anomalyDetectionEnabledProvider);
      if (!enabled) return;

      // 任务/关联记录尚未持久化（id 为 null）时无法去重，跳过
      final taskId = task.id;
      final entryId = entry.id;
      if (taskId == null || entryId == null) return;

      // 同一关联记录只告警一次（实时阶段可能多次扣减）
      if (_alertedEntryIds.contains(entryId)) return;
      final estimatedGrams = entry.estimatedGrams;
      if (!delta.isFinite || !estimatedGrams.isFinite || estimatedGrams <= 0) {
        return;
      }

      // 规则 1：单次扣减过大
      // 触发条件：delta > 预估 × 50% 且 delta > 5g
      // 例外：mcPercent 接近 100 时（>95%），单次扣减接近预估是正常的（最后一次结算修正）
      if (mcPercent > 95) return;

      final threshold = estimatedGrams * 0.5;
      if (delta > threshold && delta > 5.0) {
        await _alert(
          title: '耗材扣减异常',
          body: '${task.taskName} - T${entry.toolIndex} 通道单次扣减 '
              '${delta.toStringAsFixed(1)}g（预估该卷总量 ${entry.estimatedGrams.toStringAsFixed(1)}g，'
              '进度 $mcPercent%），可能切片预估偏低或进度跳变。',
          context: {
            'phase': 'realtime_deduct',
            'taskId': taskId,
            'ptcId': entryId,
            'consumableId': entry.consumableId,
            'delta': delta,
            'estimatedGrams': estimatedGrams,
            'mcPercent': mcPercent,
          },
        );
        _alertedEntryIds.add(entryId);
        _trimAlertedCacheIfNeeded();
      }
    } catch (e, st) {
      // 检测失败不影响主流程
      ErrorLogger.log(
        e,
        st,
        source: 'anomaly_detection',
        level: ErrorLevel.warning,
        context: {'phase': 'detect_realtime', 'taskId': task.id},
      );
    }
  }

  /// 检测任务结算异常。
  ///
  /// 在 [PrintTaskOrchestrator._settleTaskConsumables] 末尾调用（所有卷结算完成后）。
  /// 检测规则 2/3/4：结算远超/远低于预估、Z-score 异常。
  ///
  /// [task] 当前打印任务，[entries] 所有关联记录（已写入 finalConsumed），
  /// [isCancelled] 任务是否被取消（取消时实际消耗偏低是正常的，不告警规则 3）。
  Future<void> detectSettlement({
    required PrintTask task,
    required List<PrintTaskConsumable> entries,
    required bool isCancelled,
  }) async {
    try {
      final enabled = _ref.read(anomalyDetectionEnabledProvider);
      if (!enabled) return;

      // 任务尚未持久化（id 为 null）时无法查询历史记录，跳过
      final taskId = task.id;
      if (taskId == null) return;

      final ptcDao = _ref.read(printTaskConsumableDaoProvider);
      final consumableDao = _ref.read(consumableDaoProvider);

      for (final e in entries) {
        if (e.consumableId == null || e.id == null) continue;
        final entryId = e.id!; // 已 null 检查，提取到局部变量便于类型提升

        // 获取耗材信息（材质用于 Z-score 历史查询）
        final consumable = await consumableDao.getById(e.consumableId!);
        if (consumable == null) continue;

        // 规则 2：结算远超预估
        // 触发条件：finalConsumed > 预估 × 1.5 且 > 5g
        final estimatedGrams = e.estimatedGrams;
        final hasValidEstimate = estimatedGrams.isFinite && estimatedGrams > 0;
        if (hasValidEstimate &&
            e.consumedGrams.isFinite &&
            e.consumedGrams > estimatedGrams * 1.5 &&
            e.consumedGrams > 5.0) {
          await _alert(
            title: '耗材消耗异常：远超预估',
            body:
                '${task.taskName} - ${consumable.manufacturer} ${consumable.model}'
                '（T${e.toolIndex}）实际消耗 ${e.consumedGrams.toStringAsFixed(1)}g，'
                '切片预估仅 ${e.estimatedGrams.toStringAsFixed(1)}g'
                '（超出 ${(e.consumedGrams / e.estimatedGrams * 100 - 100).toStringAsFixed(0)}%），'
                '请检查切片设置或 AMS 通道映射。',
            context: {
              'phase': 'settle_over_estimate',
              'taskId': taskId,
              'ptcId': entryId,
              'consumableId': e.consumableId,
              'consumedGrams': e.consumedGrams,
              'estimatedGrams': e.estimatedGrams,
            },
          );
          _alertedEntryIds.add(entryId);
          continue; // 同一记录已告警，跳过 Z-score 检测
        }

        // 规则 3：结算远低于预估（取消任务跳过）
        // 触发条件：finalConsumed < 预估 × 0.3 且 > 5g 且任务未取消
        if (!isCancelled &&
            hasValidEstimate &&
            e.consumedGrams.isFinite &&
            e.consumedGrams < estimatedGrams * 0.3 &&
            e.consumedGrams > 5.0) {
          await _alert(
            title: '耗材消耗异常：远低于预估',
            body:
                '${task.taskName} - ${consumable.manufacturer} ${consumable.model}'
                '（T${e.toolIndex}）实际消耗 ${e.consumedGrams.toStringAsFixed(1)}g，'
                '切片预估 ${e.estimatedGrams.toStringAsFixed(1)}g'
                '（仅 ${(e.consumedGrams / e.estimatedGrams * 100).toStringAsFixed(0)}%），'
                '可能 AMS 通道映射错误或切片耗材计算偏大。',
            context: {
              'phase': 'settle_under_estimate',
              'taskId': taskId,
              'ptcId': entryId,
              'consumableId': e.consumableId,
              'consumedGrams': e.consumedGrams,
              'estimatedGrams': e.estimatedGrams,
            },
          );
          _alertedEntryIds.add(entryId);
          continue;
        }

        // 规则 4：Z-score 异常检测
        // 查询同材质耗材卷的近期消耗记录，计算 Z-score
        // materialType 是非空 String（数据库有默认值 'PLA'），无需 null 检查
        if (consumable.materialType.isEmpty) continue;

        final history = await ptcDao.getRecentConsumedGramsByMaterial(
          materialType: consumable.materialType,
          excludeTaskId: taskId,
        );
        final z = _calculateZScore(history, e.consumedGrams);
        if (z != null && z.abs() > _zScoreThreshold) {
          final direction = z > 0 ? '偏高' : '偏低';
          final mean = history.reduce((a, b) => a + b) / history.length;
          await _alert(
            title: '耗材消耗异常：偏离历史均值',
            body:
                '${task.taskName} - ${consumable.manufacturer} ${consumable.model}'
                '（${consumable.materialType}）实际消耗 ${e.consumedGrams.toStringAsFixed(1)}g，'
                '与近 ${history.length} 次同材质消耗记录相比异常$direction'
                '（历史均值 ${mean.toStringAsFixed(1)}g，Z-score ${z.toStringAsFixed(2)}），'
                '建议核查切片预估与实际打印参数。',
            context: {
              'phase': 'settle_zscore',
              'taskId': taskId,
              'ptcId': entryId,
              'consumableId': e.consumableId,
              'consumedGrams': e.consumedGrams,
              'historyMean': mean,
              'historyCount': history.length,
              'zScore': z,
            },
          );
          _alertedEntryIds.add(entryId);
        }
      }
    } catch (e, st) {
      // 检测失败不影响主流程
      ErrorLogger.log(
        e,
        st,
        source: 'anomaly_detection',
        level: ErrorLevel.warning,
        context: {'phase': 'detect_settlement', 'taskId': task.id},
      );
    } finally {
      // P0-4 修复：结算完成后清理这些关联记录的告警去重标记。
      // 旧实现只在 clearAlertedHistory() 全量清理，而该方法几乎不被调用，
      // 导致 _alertedEntryIds 随历史任务无限增长（每任务 × 每卷一条）。
      // 结算后这些 ptc 不再参与实时检测，可安全移除。
      for (final e in entries) {
        if (e.id != null) _alertedEntryIds.remove(e.id);
      }
    }
  }

  /// 清理已告警记录集合（应用退出或用户手动触发时调用）。
  ///
  /// 注意：通常无需调用。任务结算后会自动清理对应记录（见 detectSettlement）。
  void clearAlertedHistory() {
    _alertedEntryIds.clear();
  }

  /// 计算 Z-score。
  ///
  /// 返回 null 表示样本不足或标准差为 0（无法计算）。
  /// [history] 历史值列表，[value] 当前值。
  double? _calculateZScore(List<double> history, double value) {
    if (history.length < _minSampleSize) return null;
    final mean = history.reduce((a, b) => a + b) / history.length;
    final variance =
        history.map((v) => math.pow(v - mean, 2)).reduce((a, b) => a + b) /
            history.length;
    final std = math.sqrt(variance);
    if (std == 0) return null; // 所有历史值相同，无法判断偏离
    return (value - mean) / std;
  }

  /// 发送告警（双通道：Toast 通知 + ErrorLogger 数据库日志）。
  Future<void> _alert({
    required String title,
    required String body,
    required Map<String, dynamic> context,
  }) async {
    // 1. Toast 通知
    try {
      final notif = _ref.read(notificationServiceProvider);
      await notif.alert(
        type: AlertType.consumptionAnomaly,
        title: title,
        body: body,
      );
    } catch (e, st) {
      // 通知失败不影响 ErrorLogger 写入
      ErrorLogger.log(
        e,
        st,
        source: 'anomaly_detection',
        level: ErrorLevel.warning,
        context: {'phase': 'notify_failed', ...context},
      );
    }

    // 2. ErrorLogger 数据库日志（便于回溯统计）
    try {
      ErrorLogger.log(
        '$title: $body',
        null,
        source: 'anomaly_detection',
        level: ErrorLevel.warning,
        context: context,
      );
    } catch (_) {
      // ErrorLogger 可能未初始化，忽略
    }
  }
}

/// 异常检测服务 Provider（全局单例）。
///
/// 在 [PrintTaskOrchestrator] 中通过 ref.read 调用，
/// 不需要在 app.dart 中显式 start（被动触发，无定时器）。
final anomalyDetectionServiceProvider =
    Provider<AnomalyDetectionService>((ref) {
  return AnomalyDetectionService(ref);
});
