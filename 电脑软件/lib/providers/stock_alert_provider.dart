import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database/daos/print_task_consumable_dao.dart';
import 'consumable_provider.dart';
import 'database_provider.dart';
import 'filament_cost_provider.dart';

/// Revision signal for settings that live in SharedPreferences.  Shared
/// Preferences has no reactive stream, so the settings screen bumps this
/// value after a successful save and all alert consumers recompute immediately.
class StockThresholdsRevisionNotifier extends StateNotifier<int> {
  StockThresholdsRevisionNotifier() : super(0);

  void bump() => state++;
}

final stockThresholdsRevisionProvider =
    StateNotifierProvider<StockThresholdsRevisionNotifier, int>(
  (ref) => StockThresholdsRevisionNotifier(),
);

/// Database change signal used by stock alerts for consumption-log updates.
/// Inventory changes already arrive through [consumablesProvider], while this
/// stream also covers a completed task whose inventory row did not change.
final printTaskConsumableChangesProvider = StreamProvider<void>((ref) {
  return ref.watch(printTaskConsumableDaoProvider).changeStream;
});

/// 库存等级。
enum StockLevel { critical, low, healthy }

// ===================== 阈值常量（默认值，可被用户设置覆盖） =====================

/// 单规格总剩余克数低于此值 → critical 候选（默认 100g）。
const double kDefaultCriticalRemainingGrams = 100;

/// 单规格总剩余克数低于此值 → low 候选（默认 200g）。
const double kDefaultLowRemainingGrams = 200;

/// 预计剩余可用天数低于此值 → critical 候选（要求月均消耗 > 0，默认 3 天）。
const int kDefaultCriticalDaysLeft = 3;

/// 预计剩余可用天数低于此值 → low 候选（要求月均消耗 > 0，默认 7 天）。
const int kDefaultLowDaysLeft = 7;

/// 单卷剩余克数低于此值视为低库存卷（用于 lowRollCount 统计，默认 100g）。
const double kDefaultLowRollRemainingGrams = 100;

/// 计算月均消耗速率的回看天数（默认 30 天）。
const int kDefaultConsumptionLookbackDays = 30;

/// 每卷标准克数（1kg）。
const double _kGramsPerRoll = 1000.0;

// ===================== 阈值持久化 keys =====================
const _kCriticalRemainingKey = 'stock_critical_grams';
const _kLowRemainingKey = 'stock_low_grams';
const _kCriticalDaysKey = 'stock_critical_days';
const _kLowDaysKey = 'stock_low_days';
const _kLowRollRemainingKey = 'stock_low_roll_grams';
const _kLookbackDaysKey = 'stock_lookback_days';

/// 库存阈值配置（从 SharedPreferences 读取，未设置用默认值）。
class StockThresholds {
  final double criticalRemainingGrams;
  final double lowRemainingGrams;
  final int criticalDaysLeft;
  final int lowDaysLeft;
  final double lowRollRemainingGrams;
  final int consumptionLookbackDays;

  const StockThresholds({
    this.criticalRemainingGrams = kDefaultCriticalRemainingGrams,
    this.lowRemainingGrams = kDefaultLowRemainingGrams,
    this.criticalDaysLeft = kDefaultCriticalDaysLeft,
    this.lowDaysLeft = kDefaultLowDaysLeft,
    this.lowRollRemainingGrams = kDefaultLowRollRemainingGrams,
    this.consumptionLookbackDays = kDefaultConsumptionLookbackDays,
  });

  static Future<StockThresholds> load() async {
    final prefs = await SharedPreferences.getInstance();
    final rawCriticalGrams = prefs.getDouble(_kCriticalRemainingKey);
    final rawLowGrams = prefs.getDouble(_kLowRemainingKey);
    final rawCriticalDays = prefs.getInt(_kCriticalDaysKey);
    final rawLowDays = prefs.getInt(_kLowDaysKey);
    final rawLowRollGrams = prefs.getDouble(_kLowRollRemainingKey);
    final rawLookbackDays = prefs.getInt(_kLookbackDaysKey);
    final criticalGrams = rawCriticalGrams != null &&
            rawCriticalGrams.isFinite &&
            rawCriticalGrams >= 0
        ? rawCriticalGrams
        : kDefaultCriticalRemainingGrams;
    final lowGrams =
        rawLowGrams != null && rawLowGrams.isFinite && rawLowGrams > 0
            ? math.max(rawLowGrams, criticalGrams)
            : math.max(kDefaultLowRemainingGrams, criticalGrams);
    final criticalDays = rawCriticalDays != null && rawCriticalDays >= 0
        ? rawCriticalDays
        : kDefaultCriticalDaysLeft;
    final lowDays = rawLowDays != null && rawLowDays > 0
        ? math.max(rawLowDays, criticalDays)
        : math.max(kDefaultLowDaysLeft, criticalDays);
    final lowRollGrams = rawLowRollGrams != null &&
            rawLowRollGrams.isFinite &&
            rawLowRollGrams >= 0
        ? rawLowRollGrams
        : kDefaultLowRollRemainingGrams;
    final lookbackDays = rawLookbackDays != null && rawLookbackDays > 0
        ? rawLookbackDays
        : kDefaultConsumptionLookbackDays;
    return StockThresholds(
      criticalRemainingGrams: criticalGrams,
      lowRemainingGrams: lowGrams,
      criticalDaysLeft: criticalDays,
      lowDaysLeft: lowDays,
      lowRollRemainingGrams: lowRollGrams,
      consumptionLookbackDays: lookbackDays,
    );
  }

  static Future<void> save({
    double? criticalRemainingGrams,
    double? lowRemainingGrams,
    int? criticalDaysLeft,
    int? lowDaysLeft,
    double? lowRollRemainingGrams,
    int? consumptionLookbackDays,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (criticalRemainingGrams != null) {
      await prefs.setDouble(_kCriticalRemainingKey, criticalRemainingGrams);
    }
    if (lowRemainingGrams != null) {
      await prefs.setDouble(_kLowRemainingKey, lowRemainingGrams);
    }
    if (criticalDaysLeft != null) {
      await prefs.setInt(_kCriticalDaysKey, criticalDaysLeft);
    }
    if (lowDaysLeft != null) {
      await prefs.setInt(_kLowDaysKey, lowDaysLeft);
    }
    if (lowRollRemainingGrams != null) {
      await prefs.setDouble(_kLowRollRemainingKey, lowRollRemainingGrams);
    }
    if (consumptionLookbackDays != null) {
      await prefs.setInt(_kLookbackDaysKey, consumptionLookbackDays);
    }
  }
}

// 保留旧常量名作为默认值别名，避免外部引用断裂（指向默认值常量）
const double kCriticalRemainingGrams = kDefaultCriticalRemainingGrams;
const double kLowRemainingGrams = kDefaultLowRemainingGrams;
const int kCriticalDaysLeft = kDefaultCriticalDaysLeft;
const int kLowDaysLeft = kDefaultLowDaysLeft;
const double kLowRollRemainingGrams = kDefaultLowRollRemainingGrams;
const int kConsumptionLookbackDays = kDefaultConsumptionLookbackDays;

/// 库存预警项。
///
/// 按 (manufacturer, materialType, colorHex) 三元组聚合后的一行预警数据。
/// 一行可能合并多卷同规格耗材。
class StockAlertItem {
  final String manufacturer;
  final String materialType;
  final String? colorHex;
  final String? colorName;

  /// 该规格总剩余克数（合并多卷）。
  final double totalRemainingGrams;

  /// 该规格总卷数。
  final int rollCount;

  /// 低库存卷数（剩余 < [kLowRollRemainingGrams]）。
  final int lowRollCount;

  /// 单价（元/kg，从 filament_cost_configs 匹配；未匹配为 null）。
  final double? costPerKg;

  /// 近 30 天月均消耗克数（即 30 天总消耗克数，不除以 30）。
  final double monthlyConsumptionGrams;

  /// 按当前消耗速率预计剩余可用天数。
  /// 0 表示已耗尽；-1 表示无消耗历史（无法预测）。
  final int estimatedDaysLeft;

  /// 库存等级。
  final StockLevel level;

  const StockAlertItem({
    required this.manufacturer,
    required this.materialType,
    required this.colorHex,
    required this.colorName,
    required this.totalRemainingGrams,
    required this.rollCount,
    required this.lowRollCount,
    required this.costPerKg,
    required this.monthlyConsumptionGrams,
    required this.estimatedDaysLeft,
    required this.level,
  });

  /// 唯一标识（用于 keying / 去重）。
  String get key => '$manufacturer|$materialType|${colorHex ?? ''}';
}

/// 采购建议项。
class PurchaseSuggestion {
  final String manufacturer;
  final String materialType;
  final String? colorHex;
  final String? colorName;

  /// 当前剩余克数。
  final double currentRemainingGrams;

  /// 近 30 天月均消耗克数。
  final double monthlyConsumptionGrams;
  final int estimatedDaysLeft;

  /// 建议采购克数（最少 1 卷 = 1000g）。
  final double suggestedPurchaseGrams;

  /// 折算卷数（按 1kg/卷，向上取整，最少 1 卷）。
  final int suggestedRolls;

  /// 估算采购成本（元）。costPerKg 未匹配时为 null。
  final double? estimatedCost;

  /// 对应的库存等级（用于 UI 配色）。
  final StockLevel level;

  const PurchaseSuggestion({
    required this.manufacturer,
    required this.materialType,
    required this.colorHex,
    required this.colorName,
    required this.currentRemainingGrams,
    required this.monthlyConsumptionGrams,
    required this.estimatedDaysLeft,
    required this.suggestedPurchaseGrams,
    required this.suggestedRolls,
    required this.estimatedCost,
    required this.level,
  });

  String get key => '$manufacturer|$materialType|${colorHex ?? ''}';
}

/// 计算单规格的库存等级。
///
/// 优先级：critical > low > healthy。
/// - remainingGrams < [StockThresholds.criticalRemainingGrams] 或
///   月均消耗>0 且预计<[StockThresholds.criticalDaysLeft]天 → critical
/// - remainingGrams < [StockThresholds.lowRemainingGrams] 或
///   月均消耗>0 且预计<[StockThresholds.lowDaysLeft]天 → low
/// - 其他 → healthy
StockLevel _calcLevel(
  double remainingGrams,
  double monthlyConsumption,
  int daysLeft,
  StockThresholds thresholds,
) {
  // critical 条件
  if (remainingGrams < thresholds.criticalRemainingGrams) {
    return StockLevel.critical;
  }
  if (monthlyConsumption > 0 &&
      daysLeft >= 0 &&
      daysLeft < thresholds.criticalDaysLeft) {
    return StockLevel.critical;
  }
  // low 条件
  if (remainingGrams < thresholds.lowRemainingGrams) return StockLevel.low;
  if (monthlyConsumption > 0 &&
      daysLeft >= 0 &&
      daysLeft < thresholds.lowDaysLeft) {
    return StockLevel.low;
  }
  return StockLevel.healthy;
}

/// 计算预计剩余可用天数。
///
/// - 月均消耗 ≤ 0：返回 -1（无消耗历史，无法预测）
/// - 剩余 ≤ 0：返回 0（已耗尽）
/// - 否则：round(remainingGrams / (monthlyConsumption / lookbackDays))
int _calcDaysLeft(
  double remainingGrams,
  double monthlyConsumption,
  int lookbackDays,
) {
  if (monthlyConsumption <= 0) return -1;
  if (remainingGrams <= 0) return 0;
  if (lookbackDays <= 0) return -1;
  final daily = monthlyConsumption / lookbackDays;
  return (remainingGrams / daily).round();
}

/// 库存预警列表 Provider。
///
/// 数据来源：
/// 1. [consumablesProvider] 获取全部耗材，按 (manufacturer, materialType, colorHex) 分组聚合
/// 2. [PrintTaskConsumableDao.getSummary] 查询近 30 天消耗（按 vendor+material+color 分组）
/// 3. [FilamentCostConfigDao.matchCost] 匹配单价
///
/// 返回按等级排序的列表（critical 优先 → low → healthy）。
final stockAlertsProvider = FutureProvider<List<StockAlertItem>>((ref) async {
  // watch consumablesProvider 以便耗材变更时刷新
  ref.watch(consumablesProvider);
  // Also refresh when thresholds, cost rules, or consumption logs change.
  // A fixed three-second sleep here used to make every dashboard open show an
  // empty/old alert list and still did not react to cost or log edits.
  ref.watch(stockThresholdsRevisionProvider);
  ref.watch(filamentCostConfigsProvider);
  ref.watch(printTaskConsumableChangesProvider);
  final consumablesAsync = ref.read(consumablesProvider);
  final consumables = consumablesAsync.valueOrNull ?? const [];

  final ptcDao = ref.watch(printTaskConsumableDaoProvider);
  final costDao = ref.watch(filamentCostConfigDaoProvider);
  final costConfigs = await costDao.getAll();

  // 加载用户配置的阈值（未设置用默认值）
  final thresholds = await StockThresholds.load();

  // 查询近 N 天消耗汇总（N 由 thresholds.consumptionLookbackDays 决定）
  final end = DateTime.now();
  final start =
      end.subtract(Duration(days: thresholds.consumptionLookbackDays));
  List<ConsumptionSummaryRow> summary = const [];
  try {
    summary = await ptcDao.getSummary(start: start, end: end);
  } catch (_) {
    // 数据库查询失败时按 0 消耗继续处理，避免整页崩溃
  }

  // 把消耗汇总按 (vendor|material|colorHex) 索引（同一规格可能因 cost_per_kg_snapshot
  // 不同被分成多行，这里聚合）
  final consumptionMap = <String, double>{};
  for (final row in summary) {
    final k = '${row.vendor}|${row.materialType}|${row.colorHex}';
    consumptionMap[k] = (consumptionMap[k] ?? 0) + row.totalGrams;
  }

  // 按规格分组聚合耗材
  // key: manufacturer|materialType|colorHex
  final groups = <String, _SpecGroup>{};
  for (final c in consumables) {
    final k = '${c.manufacturer}|${c.materialType}|${c.colorHex}';
    final g = groups.putIfAbsent(
      k,
      () => _SpecGroup(
        manufacturer: c.manufacturer,
        materialType: c.materialType,
        colorHex: c.colorHex,
        colorName: c.colorName,
      ),
    );
    g.totalRemaining += c.remainingGrams;
    g.rollCount += 1;
    if (c.remainingGrams < thresholds.lowRollRemainingGrams) {
      g.lowRollCount += 1;
    }
    // 优先采用第一个非空 colorName
    if (g.colorName == null && (c.colorName?.isNotEmpty ?? false)) {
      g.colorName = c.colorName;
    }
  }

  // 构建 StockAlertItem 列表
  final items = <StockAlertItem>[];
  for (final g in groups.values) {
    final consumptionKey = '${g.manufacturer}|${g.materialType}|${g.colorHex}';
    final monthlyConsumption = consumptionMap[consumptionKey] ?? 0.0;
    final daysLeft = _calcDaysLeft(
      g.totalRemaining,
      monthlyConsumption,
      thresholds.consumptionLookbackDays,
    );
    final level = _calcLevel(
      g.totalRemaining,
      monthlyConsumption,
      daysLeft,
      thresholds,
    );

    // 成本配置已一次性读取，按与 DAO 相同的优先级在内存匹配。
    double? costPerKg;
    for (final config in costConfigs) {
      if (config.vendor == g.manufacturer &&
          config.materialType == g.materialType &&
          config.colorHex == g.colorHex) {
        costPerKg = config.costPerKg;
        break;
      }
    }
    if (costPerKg == null) {
      for (final config in costConfigs) {
        if (config.vendor == g.manufacturer &&
            config.materialType == g.materialType &&
            config.colorHex.isEmpty) {
          costPerKg = config.costPerKg;
          break;
        }
      }
    }
    if (costPerKg == null) {
      for (final config in costConfigs) {
        if (config.vendor.isEmpty &&
            config.materialType == g.materialType &&
            config.colorHex.isEmpty) {
          costPerKg = config.costPerKg;
          break;
        }
      }
    }

    items.add(
      StockAlertItem(
        manufacturer: g.manufacturer,
        materialType: g.materialType,
        colorHex: g.colorHex.isEmpty ? null : g.colorHex,
        colorName: g.colorName,
        totalRemainingGrams: g.totalRemaining,
        rollCount: g.rollCount,
        lowRollCount: g.lowRollCount,
        costPerKg: costPerKg,
        monthlyConsumptionGrams: monthlyConsumption,
        estimatedDaysLeft: daysLeft,
        level: level,
      ),
    );
  }

  // 排序：critical → low → healthy；同级别按剩余克数升序（剩余少的在前）
  final levelOrder = <StockLevel, int>{
    StockLevel.critical: 0,
    StockLevel.low: 1,
    StockLevel.healthy: 2,
  };
  items.sort((a, b) {
    final r = levelOrder[a.level]!.compareTo(levelOrder[b.level]!);
    if (r != 0) return r;
    return a.totalRemainingGrams.compareTo(b.totalRemainingGrams);
  });

  return items;
});

/// 是否有 critical 级别告警。
final hasCriticalStockAlertProvider = Provider<bool>((ref) {
  final alerts = ref.watch(stockAlertsProvider).valueOrNull ?? [];
  return alerts.any((a) => a.level == StockLevel.critical);
});

/// 采购清单 Provider。
///
/// 仅返回 critical 和 low 级别的规格。
/// 建议采购量按 2 个月备货计算，最少 1 卷。
final purchaseListProvider =
    FutureProvider<List<PurchaseSuggestion>>((ref) async {
  final alerts = await ref.watch(stockAlertsProvider.future);
  final suggestions = <PurchaseSuggestion>[];

  for (final a in alerts) {
    if (a.level != StockLevel.critical && a.level != StockLevel.low) continue;

    // 目标库存：max(月均消耗 * 2, 1 卷)
    final target = math.max(a.monthlyConsumptionGrams * 2, _kGramsPerRoll);
    // 建议采购量 = 目标 - 当前；最少 1 卷
    final rawSuggested = target - a.totalRemainingGrams;
    final suggestedGrams = math.max(rawSuggested, _kGramsPerRoll);
    // 折算卷数：向上取整，最少 1
    final suggestedRolls = math.max(
      1,
      (suggestedGrams / _kGramsPerRoll).ceil(),
    );

    // 估算成本
    double? estimatedCost;
    if (a.costPerKg != null) {
      estimatedCost = suggestedGrams / _kGramsPerRoll * a.costPerKg!;
    }

    suggestions.add(
      PurchaseSuggestion(
        manufacturer: a.manufacturer,
        materialType: a.materialType,
        colorHex: a.colorHex,
        colorName: a.colorName,
        currentRemainingGrams: a.totalRemainingGrams,
        monthlyConsumptionGrams: a.monthlyConsumptionGrams,
        estimatedDaysLeft: a.estimatedDaysLeft,
        suggestedPurchaseGrams: suggestedGrams,
        suggestedRolls: suggestedRolls,
        estimatedCost: estimatedCost,
        level: a.level,
      ),
    );
  }

  return suggestions;
});

/// 内部聚合结构。
class _SpecGroup {
  final String manufacturer;
  final String materialType;
  final String colorHex;
  String? colorName;

  double totalRemaining = 0;
  int rollCount = 0;
  int lowRollCount = 0;

  _SpecGroup({
    required this.manufacturer,
    required this.materialType,
    required this.colorHex,
    required this.colorName,
  });
}
