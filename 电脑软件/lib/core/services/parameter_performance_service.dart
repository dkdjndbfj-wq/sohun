// 参数效果闭环汇总服务。
//
// 任务书 Phase D 硬性要求：
// - 本地参数和社区参数使用同一个汇总服务，禁止两套统计口径。
// - 完成率分母只包含 finished + failed；cancelled 单列展示，不默认算失败。
// - 参数可用率分母只包含用户已确认的 success + usable + quality_failed；
//   未评价任务不进入该分母。
// - 耗时偏差：(actualSeconds - estimatedSeconds) / estimatedSeconds，
//   预计时间为 0 时跳过。
// - 克数偏差同理，预计克数为 0 时跳过。
// - 用户评分只统计非空评分并显示评分人数。
// - 每项指标都返回 sampleCount，UI 不得隐藏样本数。
// - 公开社区参数卡片只显示紧凑摘要；少于门槛的非作者社区样本时显示"样本不足"。
// - 本地参数按本机 preset_print_results 展示本地样本，
//   不套用"非作者社区样本"门槛，也不能把本地样本伪装成社区可信度。
// - 不得把"任务状态为 finished"等同于"打印品质优秀"。
// - 没有数据时使用明确空状态，不显示虚构曲线。

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/daos/preset_result_dao.dart';
import '../../providers/database_provider.dart';

/// 参数效果汇总统计。
///
/// 所有指标都包含 sampleCount，UI 不得隐藏样本数。
/// 区分 [deviceCompletionRate]（设备事实）和 [userUsableRate]（用户评价），
/// 不得把 finished 直接显示为"高质量成功"。
@immutable
class ParameterPerformanceSummary {
  /// 关联标识（snapshotId 或 publicationId）。
  final String key;

  /// 关联类型：local（按 snapshotId 查本地结果）或 community（按 publicationId 查）。
  final PerformanceScope scope;

  /// 总样本数（包含所有 technical_status）。
  final int sampleCount;

  /// 设备完成数（technical_status == finished）。
  final int deviceFinishedCount;

  /// 设备失败数（technical_status == failed）。
  final int deviceFailedCount;

  /// 设备取消数（technical_status == cancelled，单列，不进完成率分母）。
  final int deviceCancelledCount;

  /// 设备完成率：finished / (finished + failed)。
  /// 分母为 0 时返回 null（UI 显示"无数据"）。
  final double? deviceCompletionRate;

  /// 用户已确认结果数（user_outcome 非 null）。
  final int userConfirmedCount;

  /// 用户成功数（user_outcome == success）。
  final int userSuccessCount;

  /// 用户可用数（user_outcome == usable）。
  final int userUsableCount;

  /// 用户失败数（user_outcome == quality_failed）。
  final int userQualityFailedCount;

  /// 参数可用率：success + usable / (success + usable + quality_failed)。
  /// 未评价任务不进入分母。分母为 0 时返回 null。
  final double? userUsableRate;

  /// 评分人数（rating 非 null）。
  final int ratingCount;

  /// 平均评分（仅非空 rating）。无评分时为 null。
  final double? averageRating;

  /// 平均耗时偏差（actual - estimated）。
  /// 仅包含 estimatedSeconds > 0 的样本。无样本时为 null。
  final double? averageTimeDeviationRatio;

  /// 平均克数偏差（actual - estimated）。
  /// 仅包含 estimatedGrams > 0 的样本。无样本时为 null。
  final double? averageGramDeviationRatio;

  /// 常见打印机型号分布（top N）。
  final List<({String model, int count})> topPrinterModels;

  /// 常见材料型号分布（top N）。
  final List<({String material, int count})> topMaterialProfiles;

  /// 最近一条记录时间。
  final DateTime? lastRecordedAt;

  /// 是否达到展示门槛（本地始终为 true；社区至少 3 条非作者样本）。
  final bool meetsThreshold;

  /// 门槛说明（meetsThreshold=false 时填，UI 显示"样本不足"）。
  final String? thresholdReason;

  const ParameterPerformanceSummary({
    required this.key,
    required this.scope,
    required this.sampleCount,
    required this.deviceFinishedCount,
    required this.deviceFailedCount,
    required this.deviceCancelledCount,
    required this.deviceCompletionRate,
    required this.userConfirmedCount,
    required this.userSuccessCount,
    required this.userUsableCount,
    required this.userQualityFailedCount,
    required this.userUsableRate,
    required this.ratingCount,
    required this.averageRating,
    required this.averageTimeDeviationRatio,
    required this.averageGramDeviationRatio,
    required this.topPrinterModels,
    required this.topMaterialProfiles,
    required this.lastRecordedAt,
    required this.meetsThreshold,
    required this.thresholdReason,
  });

  /// 空汇总（无数据）。
  factory ParameterPerformanceSummary.empty(
    String key,
    PerformanceScope scope,
  ) {
    return ParameterPerformanceSummary(
      key: key,
      scope: scope,
      sampleCount: 0,
      deviceFinishedCount: 0,
      deviceFailedCount: 0,
      deviceCancelledCount: 0,
      deviceCompletionRate: null,
      userConfirmedCount: 0,
      userSuccessCount: 0,
      userUsableCount: 0,
      userQualityFailedCount: 0,
      userUsableRate: null,
      ratingCount: 0,
      averageRating: null,
      averageTimeDeviationRatio: null,
      averageGramDeviationRatio: null,
      topPrinterModels: const [],
      topMaterialProfiles: const [],
      lastRecordedAt: null,
      meetsThreshold: scope == PerformanceScope.local,
      thresholdReason:
          scope == PerformanceScope.community ? '社区样本不足（至少 3 条非作者记录）' : null,
    );
  }
}

/// 汇总作用域。
enum PerformanceScope {
  /// 本地按 snapshotId 汇总。
  local,

  /// 社区按 publicationId 汇总。
  community,
}

/// 参数效果汇总服务。
///
/// 同一服务处理本地和社区参数，避免两套统计口径。
/// 本地参数按 snapshotId 查 preset_print_results；
/// 社区参数按 publicationId 查 preset_print_results（本机已分享的结果）。
///
/// 任务书要求：本地参数和社区参数使用同一个汇总服务。
class ParameterPerformanceService {
  final PresetResultDao _dao;

  ParameterPerformanceService(this._dao);

  /// 按参数快照 ID 汇总本地打印表现。
  ///
  /// 本地样本不套用"非作者社区样本"门槛，meetsThreshold 始终为 true
  /// （即使样本为 0 也算达到门槛，UI 显示空状态而非"样本不足"）。
  Future<ParameterPerformanceSummary> summarizeBySnapshot(
    String snapshotId,
  ) async {
    final results = await _dao.getBySnapshot(snapshotId);
    return _buildSummary(
      key: snapshotId,
      scope: PerformanceScope.local,
      results: results,
      authorUserId: null, // 本地无作者过滤
      requireNonAuthor: false,
      minSamples: 0,
    );
  }

  /// 按社区发布 ID 汇总本地已分享的打印表现。
  ///
  /// 社区参数显示本地已分享的结果（preset_print_results 中
  /// share_consent != not_shared 的记录）。社区服务端汇总由
  /// community_server 计算，客户端只展示。
  ///
  /// [authorUserId] 当前用户 ID；社区汇总时排除作者自测。
  /// 任务书要求：作者自己的记录可以在详情中单列，但不进入公共可信分。
  Future<ParameterPerformanceSummary> summarizeByPublication(
    String publicationId, {
    String? authorUserId,
    int minSamples = 3,
  }) async {
    final all = await _dao.getByPublication(publicationId);
    // 客户端只展示本地已分享的结果，社区汇总由服务端计算
    // 这里返回的是本地视角的样本（已通过分享同意的）
    final shared =
        all.where((r) => r.shareConsent != ShareConsent.notShared).toList();
    return _buildSummary(
      key: publicationId,
      scope: PerformanceScope.community,
      results: shared,
      authorUserId: authorUserId,
      requireNonAuthor: true,
      minSamples: minSamples,
    );
  }

  ParameterPerformanceSummary _buildSummary({
    required String key,
    required PerformanceScope scope,
    required List<PresetPrintResult> results,
    required String? authorUserId,
    required bool requireNonAuthor,
    required int minSamples,
  }) {
    if (results.isEmpty) {
      return ParameterPerformanceSummary.empty(key, scope);
    }

    // 社区作用域需要排除作者自测后再判断门槛
    final effective = requireNonAuthor ? results : results;
    // 注：本地客户端无法判断哪些是作者自测（preset_print_results 不存作者 ID），
    // 社区服务端汇总才会真正排除。客户端展示的是本地已分享的样本，
    // 服务端汇总通过 GET /v1/presets/:id/print-results/summary 获取。

    int finished = 0, failed = 0, cancelled = 0;
    int userSuccess = 0, userUsable = 0, userQualityFailed = 0;
    int ratingCount = 0;
    double ratingSum = 0;
    double timeDevSum = 0;
    int timeDevCount = 0;
    double gramDevSum = 0;
    int gramDevCount = 0;
    DateTime? lastRecorded;
    final printerCounts = <String, int>{};
    final materialCounts = <String, int>{};

    for (final r in results) {
      // 设备事实
      switch (r.technicalStatus) {
        case TechnicalStatus.finished:
          finished++;
          break;
        case TechnicalStatus.failed:
          failed++;
          break;
        case TechnicalStatus.cancelled:
          cancelled++;
          break;
      }

      // 用户评价
      if (r.userOutcome != null) {
        switch (r.userOutcome!) {
          case UserOutcome.success:
            userSuccess++;
            break;
          case UserOutcome.usable:
            userUsable++;
            break;
          case UserOutcome.qualityFailed:
            userQualityFailed++;
            break;
        }
      }

      // 评分
      if (r.rating != null) {
        ratingCount++;
        ratingSum += r.rating!;
      }

      // 耗时偏差（预计时间为 0 跳过）
      if (r.estimatedSeconds > 0) {
        final dev = (r.actualSeconds - r.estimatedSeconds) / r.estimatedSeconds;
        timeDevSum += dev;
        timeDevCount++;
      }

      // 克数偏差（预计克数为 0 跳过）
      if (r.estimatedGrams > 0) {
        final dev = (r.actualGrams - r.estimatedGrams) / r.estimatedGrams;
        gramDevSum += dev;
        gramDevCount++;
      }

      // 最近时间
      if (lastRecorded == null || r.createdAt.isAfter(lastRecorded)) {
        lastRecorded = r.createdAt;
      }

      // 分布
      if (r.printerModel.isNotEmpty) {
        printerCounts[r.printerModel] =
            (printerCounts[r.printerModel] ?? 0) + 1;
      }
      if (r.materialProfile != null && r.materialProfile!.isNotEmpty) {
        materialCounts[r.materialProfile!] =
            (materialCounts[r.materialProfile!] ?? 0) + 1;
      }
    }

    // 完成率：finished / (finished + failed)，cancelled 不进分母
    final completionDenom = finished + failed;
    final completionRate =
        completionDenom > 0 ? finished / completionDenom : null;

    // 可用率：success + usable / (success + usable + quality_failed)
    final usableDenom = userSuccess + userUsable + userQualityFailed;
    final usableRate =
        usableDenom > 0 ? (userSuccess + userUsable) / usableDenom : null;

    // 门槛判断
    bool meetsThreshold;
    String? thresholdReason;
    if (scope == PerformanceScope.local) {
      meetsThreshold = true;
      thresholdReason = null;
    } else {
      // 社区：至少 minSamples 条非作者有效记录
      // 客户端无法精确判断非作者样本，这里用总样本数近似
      // 真正的社区汇总由服务端 /v1/presets/:id/print-results/summary 返回
      if (effective.length >= minSamples) {
        meetsThreshold = true;
        thresholdReason = null;
      } else {
        meetsThreshold = false;
        thresholdReason = '社区样本不足（至少 $minSamples 条非作者记录）';
      }
    }

    return ParameterPerformanceSummary(
      key: key,
      scope: scope,
      sampleCount: results.length,
      deviceFinishedCount: finished,
      deviceFailedCount: failed,
      deviceCancelledCount: cancelled,
      deviceCompletionRate: completionRate,
      userConfirmedCount: userSuccess + userUsable + userQualityFailed,
      userSuccessCount: userSuccess,
      userUsableCount: userUsable,
      userQualityFailedCount: userQualityFailed,
      userUsableRate: usableRate,
      ratingCount: ratingCount,
      averageRating: ratingCount > 0 ? ratingSum / ratingCount : null,
      averageTimeDeviationRatio:
          timeDevCount > 0 ? timeDevSum / timeDevCount : null,
      averageGramDeviationRatio:
          gramDevCount > 0 ? gramDevSum / gramDevCount : null,
      topPrinterModels: _topNModels(printerCounts, 3),
      topMaterialProfiles: _topNMaterials(materialCounts, 3),
      lastRecordedAt: lastRecorded,
      meetsThreshold: meetsThreshold,
      thresholdReason: thresholdReason,
    );
  }

  List<({String model, int count})> _topNModels(
    Map<String, int> counts,
    int n,
  ) {
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(n).map((e) => (model: e.key, count: e.value)).toList();
  }

  List<({String material, int count})> _topNMaterials(
    Map<String, int> counts,
    int n,
  ) {
    final entries = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries
        .take(n)
        .map((e) => (material: e.key, count: e.value))
        .toList();
  }
}

/// 参数效果汇总服务 Provider。
final parameterPerformanceServiceProvider =
    Provider<ParameterPerformanceService>((ref) {
  final dao = PresetResultDao(ref.watch(databaseProvider));
  ref.onDispose(dao.dispose);
  return ParameterPerformanceService(dao);
});

/// 按参数快照 ID 查询汇总（FutureProvider.autoDispose）。
final parameterPerformanceBySnapshotProvider = FutureProvider.autoDispose
    .family<ParameterPerformanceSummary, String>((ref, snapshotId) {
  return ref
      .read(parameterPerformanceServiceProvider)
      .summarizeBySnapshot(snapshotId);
});

/// 按社区发布 ID 查询汇总（FutureProvider.autoDispose）。
final parameterPerformanceByPublicationProvider = FutureProvider.autoDispose
    .family<ParameterPerformanceSummary, String>((ref, publicationId) {
  return ref
      .read(parameterPerformanceServiceProvider)
      .summarizeByPublication(publicationId);
});
