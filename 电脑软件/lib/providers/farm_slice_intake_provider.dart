import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/external/slicer/production_package_inspector.dart';

class FarmSliceIntakeRequest {
  const FarmSliceIntakeRequest({
    required this.id,
    required this.inspection,
  });

  final String id;
  final ProductionPackageInspection inspection;
}

class FarmSliceIntakeState {
  const FarmSliceIntakeState({
    this.pending = const [],
    this.deferred = const [],
  });

  final List<FarmSliceIntakeRequest> pending;
  final List<FarmSliceIntakeRequest> deferred;

  FarmSliceIntakeState copyWith({
    List<FarmSliceIntakeRequest>? pending,
    List<FarmSliceIntakeRequest>? deferred,
  }) {
    return FarmSliceIntakeState(
      pending: pending ?? this.pending,
      deferred: deferred ?? this.deferred,
    );
  }
}

/// Coalesces the several G-code files that Bambu Studio can emit for one
/// multi-plate project before presenting a single farm intake prompt.
class FarmSliceIntakeNotifier extends StateNotifier<FarmSliceIntakeState> {
  FarmSliceIntakeNotifier() : super(const FarmSliceIntakeState());

  static const _coalesceDelay = Duration(milliseconds: 2200);
  static const _managedCorrelationLifetime = Duration(seconds: 30);
  final Map<String, ProductionPackageInspection> _buffer = {};
  final Map<String, Timer> _timers = {};
  final Set<String> _handledArtifacts = {};
  final Set<String> _queuedArtifacts = {};
  final Map<String, ProductionPackageInspection> _managedDeferred = {};
  final Map<String, int> _activeManagedSources = {};
  final Map<String, DateTime> _recentManagedCorrelations = {};
  var _managedSliceDepth = 0;

  /// Runs a slice started by Sohun without feeding Bambu Studio's temporary
  /// G-code back into the global "new external slice" inbox.
  ///
  /// Bambu Studio writes its command-line intermediate files into the same
  /// `bamboo_model` directory used for genuinely manual slices. The file
  /// The source/correlation key is tracked instead of globally suppressing all
  /// watcher traffic. A genuinely manual slice of another project therefore
  /// still reaches the inbox even while an in-app slice is running.
  Future<T> runManagedSlice<T>(
    Future<T> Function() operation, {
    ProductionPackageInspection? Function(T result)? inspectionOf,
    String? sourcePath,
  }) async {
    final sourceKey = _normalizedCorrelation(sourcePath);
    if (sourceKey != null) {
      _activeManagedSources.update(
        sourceKey,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    _managedSliceDepth++;
    try {
      final result = await operation();
      final inspection = inspectionOf?.call(result);
      if (inspection != null) {
        _remember(inspection);
        _rememberManagedCorrelation(inspection.correlationKey);
        _rememberManagedCorrelation(inspection.projectPath);
      }
      return result;
    } finally {
      _rememberManagedCorrelation(sourcePath);
      if (sourceKey != null) {
        final remaining = (_activeManagedSources[sourceKey] ?? 1) - 1;
        if (remaining <= 0) {
          _activeManagedSources.remove(sourceKey);
        } else {
          _activeManagedSources[sourceKey] = remaining;
        }
      }
      _managedSliceDepth--;
      if (_managedSliceDepth == 0) _drainManagedDeferred();
    }
  }

  void submit(ProductionPackageInspection inspection) {
    if (!inspection.isUsable) return;
    final artifactKey = _artifactKey(inspection);
    if (_handledArtifacts.contains(artifactKey) ||
        _queuedArtifacts.contains(artifactKey)) {
      return;
    }
    _removeExpiredManagedCorrelations();
    if (_matchesRecentManagedCorrelation(inspection)) {
      _remember(inspection);
      return;
    }
    if (_matchesActiveManagedSource(inspection) ||
        (_managedSliceDepth > 0 && _activeManagedSources.isEmpty)) {
      _managedDeferred[artifactKey] = inspection;
      return;
    }

    _submitExternal(inspection, artifactKey: artifactKey);
  }

  void _submitExternal(
    ProductionPackageInspection inspection, {
    String? artifactKey,
  }) {
    final resolvedArtifactKey = artifactKey ?? _artifactKey(inspection);
    final key = inspection.correlationKey?.trim().toLowerCase();
    final groupKey = key == null || key.isEmpty ? resolvedArtifactKey : key;
    final existing = _buffer[groupKey];
    _buffer[groupKey] =
        existing == null ? inspection : existing.merge(inspection);
    _timers.remove(groupKey)?.cancel();
    _timers[groupKey] = Timer(_coalesceDelay, () => _flush(groupKey));
  }

  void _drainManagedDeferred() {
    if (_managedDeferred.isEmpty) return;
    final deferred = _managedDeferred.values.toList(growable: false);
    _managedDeferred.clear();
    for (final inspection in deferred) {
      final artifactKey = _artifactKey(inspection);
      if (_handledArtifacts.contains(artifactKey) ||
          _matchesRecentManagedCorrelation(inspection)) {
        _remember(inspection);
        continue;
      }
      _submitExternal(inspection, artifactKey: artifactKey);
    }
  }

  void _flush(String groupKey) {
    _timers.remove(groupKey)?.cancel();
    final inspection = _buffer.remove(groupKey);
    if (inspection == null) return;
    final id = '${DateTime.now().microsecondsSinceEpoch}:$groupKey';
    final request = FarmSliceIntakeRequest(id: id, inspection: inspection);
    _queuedArtifacts.add(_artifactKey(inspection));
    state = state.copyWith(pending: [...state.pending, request]);
  }

  void complete(String id) {
    final request = _find(id);
    if (request != null) {
      _queuedArtifacts.remove(_artifactKey(request.inspection));
      _remember(request.inspection);
    }
    state = state.copyWith(
      pending: state.pending.where((item) => item.id != id).toList(),
      deferred: state.deferred.where((item) => item.id != id).toList(),
    );
  }

  void ignore(String id) => complete(id);

  void defer(String id) {
    final request = _find(id);
    if (request == null) return;
    state = state.copyWith(
      pending: state.pending.where((item) => item.id != id).toList(),
      deferred: [request, ...state.deferred.where((item) => item.id != id)],
    );
  }

  void restoreNextDeferred() {
    if (state.deferred.isEmpty) return;
    final request = state.deferred.first;
    state = state.copyWith(
      pending: [request, ...state.pending],
      deferred: state.deferred.skip(1).toList(),
    );
  }

  void restore(String id) {
    final request = state.deferred.where((item) => item.id == id).firstOrNull;
    if (request == null) return;
    state = state.copyWith(
      pending: [request, ...state.pending.where((item) => item.id != id)],
      deferred: state.deferred.where((item) => item.id != id).toList(),
    );
  }

  FarmSliceIntakeRequest? _find(String id) {
    for (final item in [...state.pending, ...state.deferred]) {
      if (item.id == id) return item;
    }
    return null;
  }

  void _remember(ProductionPackageInspection inspection) {
    _handledArtifacts.add(_artifactKey(inspection));
    if (_handledArtifacts.length > 300) {
      _handledArtifacts.remove(_handledArtifacts.first);
    }
  }

  String _artifactKey(ProductionPackageInspection inspection) =>
      '${inspection.artifactSha256 ?? inspection.artifactPath}|'
      '${inspection.plates.map((item) => item.plateIndex).join(',')}';

  String? _normalizedCorrelation(String? value) {
    final normalized = value?.trim().replaceAll('\\', '/').toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  Iterable<String> _inspectionCorrelations(
    ProductionPackageInspection inspection,
  ) sync* {
    for (final value in [inspection.correlationKey, inspection.projectPath]) {
      final normalized = _normalizedCorrelation(value);
      if (normalized != null) yield normalized;
    }
  }

  bool _matchesActiveManagedSource(ProductionPackageInspection inspection) =>
      _inspectionCorrelations(inspection)
          .any(_activeManagedSources.containsKey);

  bool _matchesRecentManagedCorrelation(
    ProductionPackageInspection inspection,
  ) =>
      _inspectionCorrelations(inspection)
          .any(_recentManagedCorrelations.containsKey);

  void _rememberManagedCorrelation(String? value) {
    final normalized = _normalizedCorrelation(value);
    if (normalized == null) return;
    _recentManagedCorrelations[normalized] =
        DateTime.now().add(_managedCorrelationLifetime);
  }

  void _removeExpiredManagedCorrelations() {
    final now = DateTime.now();
    _recentManagedCorrelations.removeWhere(
      (_, expiresAt) => !expiresAt.isAfter(now),
    );
  }

  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _managedDeferred.clear();
    _activeManagedSources.clear();
    _recentManagedCorrelations.clear();
    super.dispose();
  }
}

final farmSliceIntakeProvider =
    StateNotifierProvider<FarmSliceIntakeNotifier, FarmSliceIntakeState>((ref) {
  return FarmSliceIntakeNotifier();
});

/// Prevents the global cut-complete prompt from opening over the work-order
/// composer. While the composer is active it claims matching sliced outputs
/// itself and upgrades the corresponding source 3MF in place.
final farmWorkOrderComposerActiveProvider = StateProvider<bool>((ref) => false);
