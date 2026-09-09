import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database/daos/print_task_dao.dart';
import 'database_provider.dart';

/// 打印历史过滤参数。
///
/// - [start]/[end] 为 null 表示不限制时间范围（"全部"模式）。
/// - [status] 为 null 表示不限状态。
/// - [printerId] 为 null 表示不限打印机。
/// - [modelName] 为 null 或空表示不限模型名。
class PrintHistoryFilter {
  final DateTime? start;
  final DateTime? end;
  final PrintTaskStatus? status;
  final int? printerId;
  final String? modelName;

  const PrintHistoryFilter({
    this.start,
    this.end,
    this.status,
    this.printerId,
    this.modelName,
  });

  /// 复制并替换部分字段。start/end 直接赋值（可置为 null 表示"无界限"）；
  /// status/printerId/modelName 通过 [clearStatus]/[clearPrinter]/[clearModel]
  /// 显式清空，避免与"未传值"混淆。
  PrintHistoryFilter copyWith({
    DateTime? start,
    DateTime? end,
    PrintTaskStatus? status,
    int? printerId,
    String? modelName,
    bool clearStatus = false,
    bool clearPrinter = false,
    bool clearModel = false,
  }) {
    return PrintHistoryFilter(
      start: start ?? this.start,
      end: end ?? this.end,
      status: clearStatus ? null : (status ?? this.status),
      printerId: clearPrinter ? null : (printerId ?? this.printerId),
      modelName: clearModel ? null : (modelName ?? this.modelName),
    );
  }
}

/// 当前过滤参数。UI 修改时间范围 / 状态 / 打印机 / 模型名时更新此 provider。
final printHistoryFilterProvider =
    StateProvider<PrintHistoryFilter>((ref) => const PrintHistoryFilter());

/// 过滤后的任务列表流。
///
/// 监听 [PrintTaskDao.onChange] 广播流，任务任何 CRUD 后自动重查。
/// filter 变化时 StreamProvider 重建，重新订阅流并立即推送最新结果。
final filteredPrintTasksProvider =
    StreamProvider<List<PrintTask>>((ref) async* {
  final filter = ref.watch(printHistoryFilterProvider);
  final dao = ref.watch(printTaskDaoProvider);

  Future<List<PrintTask>> fetch() => dao.getFiltered(
        start: filter.start,
        end: filter.end,
        status: filter.status,
        printerId: filter.printerId,
        modelName: filter.modelName,
      );

  // 先发一次当前数据，再监听后续变更
  yield await fetch();
  await for (final _ in dao.onChange) {
    yield await fetch();
  }
});

/// 打印历史统计汇总。
class PrintHistoryStats {
  final int totalTasks;
  final int successCount;
  final int failedCount;
  final int cancelledCount;

  /// 成功率，0-1。totalTasks 为 0 时返回 0。
  final double successRate;

  /// 实际消耗总克数。
  final double totalActualGrams;

  /// 预估总克数。
  final double totalEstimatedGrams;

  /// 平均预估偏差：(actual-estimated)/estimated 的均值。
  /// > 0 表示实际偏多，< 0 表示偏少。无有效样本时为 0。
  final double averageDeviation;

  const PrintHistoryStats({
    required this.totalTasks,
    required this.successCount,
    required this.failedCount,
    required this.cancelledCount,
    required this.successRate,
    required this.totalActualGrams,
    required this.totalEstimatedGrams,
    required this.averageDeviation,
  });

  /// 从任务列表聚合统计。
  factory PrintHistoryStats.from(Iterable<PrintTask> tasks) {
    var success = 0, failed = 0, cancelled = 0;
    var totalActual = 0.0, totalEstimated = 0.0;
    var deviationSum = 0.0;
    var deviationCount = 0;
    for (final t in tasks) {
      switch (t.status) {
        case PrintTaskStatus.finished:
          success++;
        case PrintTaskStatus.failed:
          failed++;
        case PrintTaskStatus.cancelled:
          cancelled++;
        case PrintTaskStatus.planned:
        case PrintTaskStatus.printing:
        case PrintTaskStatus.paused:
          break;
      }
      totalActual += t.actualGrams;
      totalEstimated += t.estimatedGrams;
      if (t.estimatedGrams > 0) {
        deviationSum += (t.actualGrams - t.estimatedGrams) / t.estimatedGrams;
        deviationCount++;
      }
    }
    final total = tasks.length;
    return PrintHistoryStats(
      totalTasks: total,
      successCount: success,
      failedCount: failed,
      cancelledCount: cancelled,
      successRate: total == 0 ? 0 : success / total,
      totalActualGrams: totalActual,
      totalEstimatedGrams: totalEstimated,
      averageDeviation: deviationCount == 0 ? 0 : deviationSum / deviationCount,
    );
  }
}

/// 统计汇总（成功率 / 总任务 / 总克数 / 平均偏差）。
/// 监听 filter 变化，重新查询并聚合。
final printHistoryStatsProvider =
    FutureProvider<PrintHistoryStats>((ref) async {
  final filter = ref.watch(printHistoryFilterProvider);
  final dao = ref.watch(printTaskDaoProvider);
  final tasks = await dao.getFiltered(
    start: filter.start,
    end: filter.end,
    status: filter.status,
    printerId: filter.printerId,
    modelName: filter.modelName,
  );
  return PrintHistoryStats.from(tasks);
});
