import '../../core/services/cluster_planning_service.dart';

/// Focus a useful pending plate without selecting or dispatching a printer.
ClusterPlatePlan? selectClusterPendingPlate(List<ClusterPlatePlan> plates) {
  final pending = plates.where((p) => p.remainingRuns > 0).toList();
  if (pending.isEmpty) return null;
  final usable = pending
      .where((p) => p.blockers.isEmpty && p.candidates.isNotEmpty)
      .toList();
  final choices = usable.isEmpty ? pending : usable;
  var selected = choices.first;
  for (final next in choices.skip(1)) {
    if (next.dueAt != null &&
        (selected.dueAt == null || next.dueAt!.isBefore(selected.dueAt!))) {
      selected = next;
    }
  }
  return selected;
}

class ClusterPreparationEstimate {
  ClusterPreparationEstimate(Map<int, int?> values, this.observedAt)
    : values = Map.unmodifiable(values);
  final Map<int, int?> values;
  final DateTime observedAt;
}

/// Session-only estimates, never a new observation just because they are read.
class ClusterPreparationCache {
  String? _fingerprint, _modelIdentity;
  Set<int> _candidateIds = {};
  ClusterPreparationEstimate? _estimate;

  void clear() {
    _fingerprint = null;
    _modelIdentity = null;
    _candidateIds = {};
    _estimate = null;
  }

  void store({
    required String fingerprint,
    required String modelIdentity,
    required Iterable<int> candidateIds,
    required Map<int, int?> values,
    required DateTime observedAt,
  }) {
    final ids = candidateIds.toSet();
    if (values.keys.any((id) => !ids.contains(id)) ||
        values.values.any((v) => v != null && (v < 0 || v > 2678400))) {
      throw ArgumentError(
        'Preparation estimates must match the candidate scope',
      );
    }
    _fingerprint = fingerprint;
    _modelIdentity = modelIdentity;
    _candidateIds = ids;
    _estimate = ClusterPreparationEstimate({
      for (final id in ids) id: values[id],
    }, observedAt);
  }

  ClusterPreparationEstimate? read({
    required String fingerprint,
    required String modelIdentity,
    required Iterable<int> candidateIds,
    required DateTime now,
  }) {
    final estimate = _estimate;
    if (estimate == null) return null;
    final ids = candidateIds.toSet();
    final age = now.difference(estimate.observedAt);
    if (fingerprint != _fingerprint ||
        modelIdentity != _modelIdentity ||
        ids.length != _candidateIds.length ||
        !ids.containsAll(_candidateIds) ||
        age.isNegative ||
        age >= const Duration(seconds: 120)) {
      clear();
      return null;
    }
    return estimate;
  }
}
