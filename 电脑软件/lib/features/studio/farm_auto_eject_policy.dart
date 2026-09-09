import '../../core/services/printer_model_normalizer.dart';

bool isBatchPrinterCompatible({
  required String targetModel,
  required double targetNozzle,
  required String printerModel,
  required double? installedNozzle,
}) =>
    installedNozzle != null &&
    PrinterModelNormalizer.sameModel(targetModel, printerModel) &&
    (targetNozzle - installedNozzle).abs() < .001;

/// Converts a requested object count into complete plate runs. The last plate
/// may intentionally overproduce because a prepared plate cannot be partially
/// printed without generating a different slice.
int requiredBatchRuns({
  required int targetQuantity,
  required int objectsPerPlate,
}) {
  if (targetQuantity <= 0 || objectsPerPlate <= 0) return 0;
  return (targetQuantity + objectsPerPlate - 1) ~/ objectsPerPlate;
}

/// Allocates only the current round. Busy printers are excluded before calling
/// this helper and can participate when the operator publishes a later round.
List<int> allocateBatchRound({
  required int remainingRuns,
  required int idlePrinterCount,
  required int maxRunsPerPrinter,
}) {
  if (remainingRuns <= 0 || idlePrinterCount <= 0) return const [];
  final limit = maxRunsPerPrinter <= 0 ? 1 : maxRunsPerPrinter;
  final assigned = List<int>.filled(idlePrinterCount, 0);
  final roundCapacity = idlePrinterCount * limit;
  final count = remainingRuns < roundCapacity ? remainingRuns : roundCapacity;
  for (var run = 0; run < count; run++) {
    assigned[run % idlePrinterCount]++;
  }
  return assigned.where((value) => value > 0).toList(growable: false);
}

/// Returns whether the cached plate artifact cannot safely represent the
/// requested batch. A nullable artifact flag is intentionally treated as
/// unknown so artifacts created before schema v42 are rebuilt before reuse.
bool mustRebuildPlateArtifact({
  required bool isSliced,
  required String? artifactPath,
  required bool sameTarget,
  required bool? artifactAutoEjectEnabled,
  required bool useAutoEject,
}) =>
    !isSliced ||
    artifactPath == null ||
    artifactPath.trim().isEmpty ||
    !sameTarget ||
    artifactAutoEjectEnabled != useAutoEject;
