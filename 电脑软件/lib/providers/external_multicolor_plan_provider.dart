import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/external/slicer/filament_change_point.dart';
import '../data/external/slicer/slice_result.dart';

/// A task that requires the user to map each external color to one inventory
/// spool before inventory deduction can start.
class ExternalMulticolorPlanRequest {
  const ExternalMulticolorPlanRequest({
    required this.taskId,
    required this.printerId,
    required this.printerSerial,
    required this.printerLabel,
    required this.taskName,
    required this.filaments,
    required this.changePoints,
    required this.createdAt,
    this.farmMode = false,
  });

  final int taskId;
  final int printerId;
  final String printerSerial;
  final String printerLabel;
  final String taskName;
  final List<FilamentUsage> filaments;
  final List<FilamentChangePoint> changePoints;
  final DateTime createdAt;
  final bool farmMode;

  String get requestId => '$printerSerial:$taskId';
}

List<FilamentUsage> activeExternalFilaments(SliceResult slice) {
  final items = slice.filaments.where((f) => f.grams > 0.01).toList()
    ..sort((a, b) => a.toolIndex.compareTo(b.toolIndex));
  return items;
}

/// Positive per-tool usage plus an actual G-code change sequence are both
/// required. This prevents false prompts caused by unused colors left loaded
/// in Bambu Studio.
bool isExternalMulticolorPrint({
  required SliceResult slice,
  required bool hasAms,
  required String? trayNow,
}) {
  return externalFilamentsRequiringPlan(
    slice: slice,
    hasAms: hasAms,
    trayNow: trayNow,
  ).isNotEmpty;
}

List<FilamentUsage> externalFilamentsRequiringPlan({
  required SliceResult slice,
  required bool hasAms,
  required String? trayNow,
}) {
  final active = activeExternalFilaments(slice);
  if (active.length < 2 ||
      (slice.filamentChangePoints.isEmpty && slice.toolChangeCount <= 0)) {
    return const [];
  }

  final tray = int.tryParse(trayNow ?? '');
  if (!hasAms || tray == 254 || tray == 255) return active;

  final mapping = slice.amsMapping;
  if (mapping == null || mapping.isEmpty) return active;
  return active.where((filament) {
    if (filament.toolIndex >= mapping.length) return true;
    final channel = mapping[filament.toolIndex];
    return channel < 0 || channel >= 254;
  }).toList();
}

class ExternalMulticolorPlanQueueNotifier
    extends StateNotifier<List<ExternalMulticolorPlanRequest>> {
  ExternalMulticolorPlanQueueNotifier() : super(const []);

  final Set<String> _resolved = {};

  void enqueue(ExternalMulticolorPlanRequest request) {
    if (_resolved.contains(request.requestId) ||
        state.any((item) => item.requestId == request.requestId)) {
      return;
    }
    state = [...state, request];
  }

  void resolve(String requestId) {
    _resolved.add(requestId);
    state = state.where((item) => item.requestId != requestId).toList();
  }

  void clear() {
    _resolved.clear();
    state = const [];
  }
}

final externalMulticolorPlanQueueProvider = StateNotifierProvider<
    ExternalMulticolorPlanQueueNotifier, List<ExternalMulticolorPlanRequest>>(
  (ref) => ExternalMulticolorPlanQueueNotifier(),
);
