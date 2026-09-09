import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/daos/filament_cost_config_dao.dart';
import '../data/database/daos/print_task_consumable_dao.dart';
import '../data/external/slicer/slice_result.dart';
import 'database_provider.dart';

/// 耗材成本配置列表（UI 管理页用）。
/// 监听 DAO 变更流，自动刷新。
final filamentCostConfigsProvider =
    StreamProvider<List<FilamentCostConfig>>((ref) {
  return ref.watch(filamentCostConfigDaoProvider).watchAll();
});

/// 耗材消耗时间范围枚举（汇总卡片用）。
enum ConsumptionRange { today, week, month }

/// 耗材消耗汇总数据。
class ConsumptionSummary {
  final double totalGrams; // 总消耗克数
  final double totalCost; // 总成本（元）
  final List<ConsumptionSummaryRow> rows; // 按耗材分组的明细

  const ConsumptionSummary({
    required this.totalGrams,
    required this.totalCost,
    required this.rows,
  });
}

/// 耗材消耗汇总 Provider（按时间范围查询）。
///
/// 数据来源：print_task_consumables 表（任务完成时写入 consumed_grams）。
/// 按 (vendor, materialType, colorHex, costPerKgSnapshot) 分组聚合。
///
/// 监听 PrintTaskConsumableDao 的变更流，任务完成结算后自动刷新。
final consumptionSummaryProvider =
    StreamProvider.family<ConsumptionSummary, ConsumptionRange>(
  (ref, range) async* {
    final dao = ref.watch(printTaskConsumableDaoProvider);
    DateTime start;
    final now = DateTime.now();
    switch (range) {
      case ConsumptionRange.today:
        start = DateTime(now.year, now.month, now.day);
        break;
      case ConsumptionRange.week:
        start = now.subtract(Duration(days: now.weekday - 1));
        start = DateTime(start.year, start.month, start.day);
        break;
      case ConsumptionRange.month:
        start = DateTime(now.year, now.month, 1);
        break;
    }

    Future<ConsumptionSummary> fetch() async {
      final end = DateTime.now();
      final rows = await dao.getSummary(start: start, end: end);
      final total = await dao.getTotalSummary(start: start, end: end);
      return ConsumptionSummary(
        totalGrams: total.totalGrams,
        totalCost: total.totalCost,
        rows: rows,
      );
    }

    // 先发一次当前数据
    yield await fetch();
    // 监听变更流，任务完成结算后自动刷新
    await for (final _ in dao.changeStream) {
      yield await fetch();
    }
  },
);

/// 任务关联耗材记录流（UI 实时面板用）。
/// 用 StreamProvider 缓存流，避免每次 widget 重建都新建 async* 生成器导致 DB 查询风暴。
final taskConsumablesProvider =
    StreamProvider.family<List<PrintTaskConsumable>, int>((ref, taskId) {
  return ref.watch(printTaskConsumableDaoProvider).watchByTask(taskId);
});

/// 消耗时间序列数据点（折线图用）。
class ConsumptionPoint {
  final DateTime time;
  final double grams;

  const ConsumptionPoint({required this.time, required this.grams});
}

/// 消耗趋势折线图 Provider（按时间范围查询）。
///
/// 时间粒度：
/// - 今日：每半小时一个点（0:00 到当前时间）
/// - 本周：7 天内每天一个点
/// - 本月：从 1 号到今天每天一个点
final consumptionTimelineProvider =
    StreamProvider.family<List<ConsumptionPoint>, ConsumptionRange>(
  (ref, range) async* {
    final dao = ref.watch(printTaskConsumableDaoProvider);
    final now = DateTime.now();

    DateTime start;
    int intervalSeconds;

    switch (range) {
      case ConsumptionRange.today:
        start = DateTime(now.year, now.month, now.day);
        intervalSeconds = 1800; // 30 分钟
        break;
      case ConsumptionRange.week:
        start = now.subtract(Duration(days: now.weekday - 1));
        start = DateTime(start.year, start.month, start.day);
        intervalSeconds = 86400; // 1 天
        break;
      case ConsumptionRange.month:
        start = DateTime(now.year, now.month, 1);
        intervalSeconds = 86400; // 1 天
        break;
    }

    Future<List<ConsumptionPoint>> fetch() async {
      final raw = await dao.getTimeline(
        start: start,
        end: now,
        intervalSeconds: intervalSeconds,
      );
      // 保留完整时间范围（0:00→当前），不过滤前导零点，让横坐标铺满整个坐标轴
      return raw
          .map((p) => ConsumptionPoint(time: p.time, grams: p.grams))
          .toList();
    }

    yield await fetch();
    await for (final _ in dao.changeStream) {
      yield await fetch();
    }
  },
);

/// 切片结果 → 总成本估算。
///
/// 按 G-code 读到的每色 (vendor, materialType, colorHex) 三级匹配单价，
/// 任一色匹配失败返回 null（UI 显示"未配置成本"）。
/// 匹配优先级见 [FilamentCostConfigDao.matchCost]。
class SliceCostResult {
  final double totalCost; // 元
  final List<double?> perFilamentCost; // 每色成本，null 表示该色未匹配到单价
  final List<FilamentCostConfig?> matchedConfigs; // 每色匹配到的配置，null 表示未匹配

  const SliceCostResult({
    required this.totalCost,
    required this.perFilamentCost,
    required this.matchedConfigs,
  });

  /// 是否所有色都成功匹配到单价
  bool get allMatched => perFilamentCost.every((c) => c != null);
}

/// 切片结果成本估算 Provider。
/// 输入 SliceResult，输出成本估算（按耗材成本库匹配单价）。
final sliceCostProvider =
    FutureProvider.family<SliceCostResult?, SliceResult>((ref, slice) async {
  if (slice.filaments.isEmpty) return null;

  final dao = ref.watch(filamentCostConfigDaoProvider);
  final perFilamentCost = <double?>[];
  final matchedConfigs = <FilamentCostConfig?>[];
  double total = 0;
  bool anyMatched = false;

  for (final f in slice.filaments) {
    final config = await dao.matchCost(
      vendor: f.vendor ?? '',
      materialType: f.materialType ?? '',
      colorHex: f.colorHex ?? '',
    );
    if (config != null) {
      final cost = config.costForGrams(f.grams);
      perFilamentCost.add(cost);
      matchedConfigs.add(config);
      total += cost;
      anyMatched = true;
    } else {
      perFilamentCost.add(null);
      matchedConfigs.add(null);
    }
  }

  if (!anyMatched) return null;
  return SliceCostResult(
    totalCost: total,
    perFilamentCost: perFilamentCost,
    matchedConfigs: matchedConfigs,
  );
});
