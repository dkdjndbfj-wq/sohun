import '../../data/external/printer/printer_connector.dart';
import 'cluster_planning_service.dart';
import 'cluster_training_observation.dart';
import 'mifu_client.dart';

/// Projects one unchanged live planning snapshot into the training v4 contract.
/// Human preparation estimates stay estimates; missing time is never zero.
MifuDecisionRequest clusterMifuRequest({
  required ClusterPlanningSnapshot snapshot,
  required ClusterPlatePlan plan,
  required List<ClusterPrinterCandidate> candidates,
  required String requestId,
  required Map<int, int?> preparationSeconds,
  required DateTime preparationObservedAt,
  required DateTime now,
}) {
  const maximumSeconds = 31 * 86400;
  const gateVersion = 'cluster-planning-v1';
  void fresh(DateTime? time) {
    final age = time == null ? null : now.difference(time);
    if (age == null || age.isNegative || age > const Duration(seconds: 120)) {
      throw const MifuException('设备或队列状态已过期，请刷新后重新比较');
    }
  }

  fresh(snapshot.generatedAt);
  fresh(preparationObservedAt);
  final artifact = plan.plate.sliceArtifactSha256;
  if (plan.blockers.isNotEmpty ||
      plan.remainingRuns < 1 ||
      !snapshot.plates.any((item) => identical(item, plan)) ||
      artifact == null ||
      !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(artifact)) {
    throw const MifuException('本盘切片或候选检查尚未完成，请刷新后重试');
  }
  if (candidates.length < 2 ||
      candidates.length > 16 ||
      candidates.map((c) => c.printerId).toSet().length != candidates.length ||
      candidates.any(
        (candidate) =>
            !plan.candidates.any((item) => identical(item, candidate)),
      ) ||
      preparationSeconds.keys.any(
        (id) => !candidates.any((c) => c.printerId == id),
      )) {
    throw const MifuException('本次候选范围已变化，请重新比较');
  }
  double epoch(DateTime time) => time.millisecondsSinceEpoch / 1000;
  final projected = <Map<String, dynamic>>[];
  for (final candidate in candidates) {
    final device = snapshot.printers
        .where((p) => p.id == candidate.printerId)
        .firstOrNull;
    if (device == null ||
        !device.isEligible ||
        device.state?.connectionState != PrinterConnectionState.connected) {
      throw const MifuException('候选设备已不满足本次检查，请刷新后重试');
    }
    final statusAt = device.state?.statusUpdatedAt;
    fresh(statusAt);
    final preparation = preparationSeconds[candidate.printerId];
    if (preparation != null &&
        (preparation < 0 || preparation > maximumSeconds)) {
      throw const MifuException('准备耗时必须为0至2678400的整数秒');
    }
    projected.add({
      'id': '${candidate.printerId}',
      'admission': {
        'status': 'passed',
        'version': gateVersion,
        'snapshot_id': requestId,
        'observed_at_epoch_s': epoch(
          statusAt!.isBefore(snapshot.generatedAt)
              ? statusAt
              : snapshot.generatedAt,
        ),
        'scope': 'existing_slice_model_nozzle_feed_material_queue_checks_only',
        'full_geometry_verified': false,
      },
      'features': {
        'max_runs': candidate.maxRuns,
        'queued_runs': candidate.queuedRuns,
        'available_after_seconds': candidate.availableAfterSeconds,
        'setup_seconds': preparation,
        'run_seconds': plan.plate.estimatedSeconds,
        'hardware': {
          'model': device.model,
          'nozzle_mm': device.state?.installedNozzleDiameter,
        },
        'materials': [
          for (final material in candidate.materialMatches)
            material.toModelFeatures(),
        ],
        'timing_evidence': {
          'setup': {
            'source': 'manual_estimate',
            'observed_at_epoch_s': epoch(preparationObservedAt),
          },
          'wait': {
            'source': 'queue_and_device_lower_bound',
            'observed_at_epoch_s': epoch(
              statusAt.isBefore(snapshot.generatedAt)
                  ? statusAt
                  : snapshot.generatedAt,
            ),
          },
          'run': {
            'source': 'selected_slice_estimate',
            'artifact_sha256': artifact.toLowerCase(),
          },
        },
      },
    });
  }
  return MifuDecisionRequest(
    requestId: requestId,
    plate: {
      ...plan.toModelFeatures(),
      'artifact_sha256': artifact.toLowerCase(),
    },
    candidates: projected,
    decisionContext: {
      'schema': 'mifu-decision-v4',
      'source': 'live_snapshot',
      'objective': 'earliest_known_finish',
      'snapshot_id': requestId,
      'gate_version': gateVersion,
      'observed_at_epoch_s': epoch(snapshot.generatedAt),
      'max_age_seconds': 120,
    },
    observation: clusterTrainingObservation(
      snapshot,
      plan,
      candidates,
      requestId,
    ),
  );
}
