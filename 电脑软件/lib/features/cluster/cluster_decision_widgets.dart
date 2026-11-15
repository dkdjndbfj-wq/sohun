import 'package:flutter/material.dart';

import '../../core/services/cluster_planning_service.dart';
import '../../core/services/mifu_client.dart';
import '../../core/theme/interaction_effects.dart';
import '../../widgets/mifu_brand.dart';
import 'cluster_observation.dart';

/// Presentation only: these widgets never change candidates or dispatch jobs.
class MifuDecisionHeader extends StatelessWidget {
  const MifuDecisionHeader({
    super.key,
    required this.health,
    required this.inferring,
    required this.onDetails,
  });

  final MifuHealth health;
  final bool inferring;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = health.trainingState == 'error'
        ? scheme.error
        : health.ready
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            const MifuBrandIdentity(width: 80),
            Tooltip(
              message: '查看 Mifu 状态',
              child: Semantics(
                button: true,
                child: InkWell(
                  onTap: onDetails,
                  borderRadius: BorderRadius.circular(24),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .065),
                      border: Border.all(color: color.withValues(alpha: .12)),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          inferring ? '比较中' : health.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: color,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Icon(Icons.chevron_right, size: 14, color: color),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class MifuPlateSummary extends StatelessWidget {
  const MifuPlateSummary({
    super.key,
    required this.plan,
    required this.duration,
  });
  final ClusterPlatePlan plan;
  final String duration;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final grams = plan.plate.estimatedGrams;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: .025),
        border: Border.all(color: scheme.onSurface.withValues(alpha: .06)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Tooltip(
            message: '当前打印盘 · ${plan.plate.name}',
            child: Text(
              'P${plan.plate.plateIndex.toString().padLeft(2, '0')} · ${plan.plate.name}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              _metric(context, '剩余盘次', '${plan.remainingRuns}'),
              _metric(
                context,
                '单盘用量',
                grams.isFinite && grams > 0
                    ? '${grams.toStringAsFixed(1)} g'
                    : '—',
              ),
              _metric(context, '单盘耗时', duration),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(BuildContext context, String label, String value) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ],
  );
}

class MifuCandidateSummary extends StatelessWidget {
  const MifuCandidateSummary({
    super.key,
    required this.total,
    required this.eligible,
    required this.compared,
  });
  final int total, eligible, compared;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 6,
      children: [
        for (final entry in [
          ('全部设备', total),
          ('满足条件', eligible),
          ('本次候选', compared),
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${entry.$2}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                entry.$1,
                style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
      ],
    );
  }
}

class MifuCandidateTile extends StatelessWidget {
  const MifuCandidateTile({
    super.key,
    required this.candidate,
    required this.selected,
    required this.onTap,
    this.probability,
    this.recommended = false,
  });

  final ClusterPrinterCandidate candidate;
  final bool selected;
  final double? probability;
  final bool recommended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = Color.lerp(scheme.primary, scheme.onSurface, .25)!;
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: AppMotion.duration(
          context,
          const Duration(milliseconds: 160),
        ),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: .055)
              : scheme.surface.withValues(alpha: .24),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: .42)
                : scheme.onSurface.withValues(alpha: .09),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, bounds) {
                      final stackProbability =
                          MediaQuery.textScalerOf(context).scale(1) >= 1.4 ||
                          bounds.maxWidth < 230;
                      final name = Row(
                        children: [
                          Icon(
                            selected
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 16,
                            color: selected
                                ? accent
                                : scheme.onSurfaceVariant.withValues(alpha: .5),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Tooltip(
                              message: candidate.printerName,
                              child: Text(
                                candidate.printerName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          if (recommended) ...[
                            const SizedBox(width: 5),
                            Text('建议', style: TextStyle(fontSize: 10, color: accent)),
                          ],
                        ],
                      );
                      final score = probability == null
                          ? null
                          : Tooltip(message: '模型偏好概率，不是打印成功率', child: Text(
                              '${(probability! * 100).toStringAsFixed(1)}%',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: selected ? accent : scheme.onSurface,
                              ),
                            ));
                      if (stackProbability) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            name,
                            if (score != null) ...[
                              const SizedBox(height: 4),
                              score,
                            ],
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: name),
                          if (score != null) ...[
                            const SizedBox(width: 8),
                            score,
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 14,
                    runSpacing: 4,
                    children: [
                      Text(
                        '可排 ${candidate.maxRuns} 次 · 队列 ${candidate.queuedRuns}',
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        clusterMachineWait(candidate.availableAfterSeconds),
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Puts the recommendation before its distribution. Timing is projected from
/// the same request, not invented as an explanation of the model's reasoning.
class MifuRecommendationCard extends StatelessWidget {
  const MifuRecommendationCard({
    super.key,
    required this.plan,
    required this.candidate,
    required this.candidateCount,
    required this.request,
    required this.modelRecommended,
    required this.busy,
    required this.ready,
    required this.stale,
    this.onReadyToCompare,
  });

  final ClusterPlatePlan plan;
  final ClusterPrinterCandidate? candidate;
  final int candidateCount;
  final MifuDecisionRequest? request;
  final bool modelRecommended, busy, ready, stale;
  final VoidCallback? onReadyToCompare;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = candidate;
    final input = request?.candidates.where((c) => '${c['id']}' == '${chosen?.printerId}').firstOrNull;
    final features = input?['features'];
    final rawSetup = features is Map ? features['setup_seconds'] : null;
    final setup = rawSetup is int && rawSetup >= 0 ? rawSetup : null;
    final wait = chosen?.availableAfterSeconds;
    final run = plan.plate.estimatedSeconds > 0 ? plan.plate.estimatedSeconds : null;
    final total = wait != null && setup != null && run != null ? wait + setup + run : null;
    final title = busy ? '正在比较设备' : chosen != null ? chosen.printerName : candidateCount == 0 ? '需要处理设备或材料' : '已筛选 $candidateCount 台设备';
    final caption = busy ? '条件检查 → 耗时比较' : modelRecommended ? 'Mifu 建议' : chosen != null ? '唯一适配设备' : stale ? '条件已更新' : '自动筛选完成';
    return Container(
      key: const ValueKey('mifu-recommendation-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary.withValues(alpha: .09), scheme.surface.withValues(alpha: .45)],
        ),
        border: Border.all(color: scheme.primary.withValues(alpha: .16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(modelRecommended ? Icons.auto_awesome_rounded : Icons.filter_alt_outlined, size: 15, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text(caption, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))),
            if (modelRecommended) Icon(Icons.check_circle_rounded, size: 15, color: scheme.primary),
          ]),
          const SizedBox(height: 8),
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (chosen != null) ...[
            Text('材料已匹配 · 可排 ${chosen.maxRuns} 次', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 8, children: [
              _time(context, '机器等待', wait),
              _time(context, '准备', setup),
              _time(context, '单盘打印', run),
            ]),
            if (total != null) ...[
              const SizedBox(height: 10),
              Tooltip(message: '已知等待下界 + 人工准备估计 + 切片耗时；非完成时间承诺', child: Text('已知单盘耗时 ≥ ${clusterDuration(total)}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
            ],
          ] else if (!busy) ...[
            Text(candidateCount == 0 ? '在详情中查看待处理项' : ready ? '确认准备时间，即可比较' : '模型未连接，可手动选择设备', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            if (onReadyToCompare != null) ...[
              const SizedBox(height: 10),
              TextButton.icon(
                key: const ValueKey('mifu-ready-compare'),
                onPressed: onReadyToCompare,
                icon: const Icon(Icons.bolt_rounded, size: 16),
                label: const Text('均无需准备，直接比较'),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _time(BuildContext context, String title, int? seconds) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      const SizedBox(height: 3),
      Text(seconds == null ? '待确认' : seconds == 0 ? '无需等待' : clusterDuration(seconds), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
    ],
  );
}
