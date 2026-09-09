import '../printer/bambu_cloud_models.dart';
import '../slicer/slice_result.dart';

const _activeCloudTaskStatuses = <String>{
  '0',
  '1',
  '2',
  '3',
  'running',
  'printing',
  'pause',
  'paused',
  'pending',
};

/// 从云任务历史中选出指定打印机当前最可信的活跃任务。
BambuCloudTask? findActiveCloudTaskForPrinter({
  required List<BambuCloudTask> tasks,
  required String serial,
  String? taskName,
  String? gcodeFile,
}) {
  final candidates = tasks.where((task) {
    return task.deviceId.trim().toLowerCase() == serial.trim().toLowerCase() &&
        _activeCloudTaskStatuses.contains(task.status.trim().toLowerCase()) &&
        (task.weight > 0 || task.amsFilaments.any((item) => item.weight > 0));
  }).toList();
  if (candidates.isEmpty) return null;

  final expectedNames = <String>{
    if (taskName != null) _normalizeTaskName(taskName),
    if (gcodeFile != null) _normalizeTaskName(gcodeFile),
  }..removeWhere((name) => name.isEmpty);

  candidates.sort((a, b) {
    final aMatches = expectedNames.contains(_normalizeTaskName(a.title));
    final bMatches = expectedNames.contains(_normalizeTaskName(b.title));
    if (aMatches != bMatches) return aMatches ? -1 : 1;
    final aTime = a.startTime?.millisecondsSinceEpoch ?? 0;
    final bTime = b.startTime?.millisecondsSinceEpoch ?? 0;
    return bTime.compareTo(aTime);
  });
  return candidates.first;
}

/// 把云端活跃任务的耗材明细转换为本地统一切片结果。
///
/// 云端只作为本地切片缺失时的补充来源；无 AMS 机型全部归到通道 0，
/// 有 AMS 时保留云端上报的全局槽位（包括 254/255 外置料盘编号）。
SliceResult? cloudTaskToSliceResult({
  required BambuCloudTask task,
  required String fallbackPath,
  required String fallbackTaskName,
  required bool hasAms,
  int totalLayers = 0,
}) {
  final details = task.amsFilaments.where((item) => item.weight > 0).toList();
  final detailWeight =
      details.fold<double>(0, (total, item) => total + item.weight);
  final targetWeight = task.weight > 0 ? task.weight : detailWeight;
  if (targetWeight <= 0) return null;

  final filaments = <FilamentUsage>[];
  final mapping = <int>[];
  if (details.isEmpty) {
    filaments.add(
      FilamentUsage(
        toolIndex: 0,
        grams: targetWeight,
        lengthMm: task.length.toDouble(),
      ),
    );
    mapping.add(0);
  } else {
    final scale = detailWeight > 0 ? targetWeight / detailWeight : 1.0;
    for (var index = 0; index < details.length; index++) {
      final detail = details[index];
      final grams = detail.weight * scale;
      final length =
          targetWeight > 0 ? task.length * (grams / targetWeight) : 0.0;
      filaments.add(
        FilamentUsage(
          toolIndex: index,
          grams: grams,
          lengthMm: length,
          colorHex: _normalizeColor(detail.sourceColor),
          materialType:
              detail.filamentType.isEmpty ? null : detail.filamentType,
          vendor: detail.filamentId.isEmpty ? null : 'Bambu Lab',
          settingsId: detail.filamentType.isEmpty ? null : detail.filamentType,
          sku: detail.filamentId.isEmpty ? null : detail.filamentId,
        ),
      );
      mapping.add(hasAms ? detail.ams : 0);
    }
  }

  return SliceResult(
    filePath: fallbackPath,
    taskName:
        task.title.trim().isNotEmpty ? task.title.trim() : fallbackTaskName,
    filaments: filaments,
    estimatedSeconds: task.costTime,
    toolChangeCount: filaments.length > 1 ? filaments.length - 1 : 0,
    totalLayers: totalLayers,
    slicerName: 'Bambu Cloud',
    amsMapping: mapping,
  );
}

String _normalizeTaskName(String value) {
  final basename = value.split(RegExp(r'[/\\]')).last.toLowerCase();
  return basename
      .replaceFirst(RegExp(r'\.(3mf|gcode|gco|bgcode)$'), '')
      .replaceAll(RegExp(r'[\s_\-\.\(\)\[\]]+'), '');
}

String? _normalizeColor(String value) {
  final color = value.trim().replaceFirst('#', '');
  if (color.length < 6) return null;
  return '#${color.substring(0, 6).toUpperCase()}';
}
