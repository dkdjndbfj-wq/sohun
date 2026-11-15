import 'cluster_planning_service.dart';
import 'slice_geometry_evidence.dart';
import 'toolpath_geometry_evidence.dart';
import '../../data/external/printer/bambu_printer_models.dart';

/// Evidence captured with the decision, kept outside the model input. Unknown
/// geometry/setup/quality must remain unknown until measured or reviewed.
Map<String, Object?> clusterTrainingObservation(
  ClusterPlanningSnapshot snapshot,
  ClusterPlatePlan plan,
  List<ClusterPrinterCandidate> candidates,
  String requestId,
) {
  if (!snapshot.plates.any((item) => identical(item, plan)) ||
      candidates.any(
        (candidate) =>
            !plan.candidates.any((item) => identical(item, candidate)),
      )) {
    throw StateError('设备选择与采集快照不一致，请刷新后重试');
  }
  final ids = candidates.map((c) => c.printerId).toSet();
  final printers = snapshot.printers.where((p) => ids.contains(p.id));
  if (printers.length != ids.length) {
    throw StateError('候选设备不在当前可见快照中，请刷新后重试');
  }
  final declared = plan.declaredSliceGeometry;
  if (declared != null &&
      !SliceGeometryEvidence.matchesBinding(
        declared,
        artifactSha256: plan.plate.sliceArtifactSha256,
        plateIndex: plan.plate.plateIndex,
      )) {
    throw StateError('声明床面证据与当前切片或盘号不一致，请刷新后重试');
  }
  if (plan.toolpathGeometry != null &&
      !ToolpathGeometryEvidence.matchesBinding(
        plan.toolpathGeometry!,
        artifactSha256: plan.plate.sliceArtifactSha256,
        plateIndex: plan.plate.plateIndex,
      )) {
    throw StateError('刀路证据与当前切片或盘号不一致，请刷新后重试');
  }
  final observation = <String, Object?>{
    'schema': 'mifu-observation-v1',
    'requestId': requestId,
    'plate_id': plan.plate.id,
    'candidate_ids': candidates.map((c) => '${c.printerId}').toList(),
    'snapshot_at': snapshot.generatedAt.toUtc().toIso8601String(),
    'source': 'desktop_observation',
    'artifact_sha256': plan.plate.sliceArtifactSha256,
    'plate_index': plan.plate.plateIndex,
    'declared_slice_geometry': declared,
    'toolpath_geometry': plan.toolpathGeometry,
    'geometry': {
      'status': 'not_measured',
      'reason': 'complete_all_layer_footprints_not_extracted',
      'footprint_mm': null,
      'usable_bed_mm': null,
    },
    'devices': [
      for (final printer in printers)
        {
          'candidate_id': '${printer.id}',
          'model': printer.state?.reportedModel,
          'installed_nozzle_mm': printer.state?.installedNozzleDiameter,
          'nozzle_material': null,
          'telemetry_at': printer.state?.statusUpdatedAt
              ?.toUtc()
              .toIso8601String(),
          'ams_observed': printer.state?.lastStatus?.amsUnits != null,
          // A merged status timestamp does not prove when AMS fields arrived.
          'ams_telemetry_at': null,
          'connection': printer.state?.connectionState.name,
          'technical_state': printer.state?.lastStatus?.gcodeState?.name,
          'setup_seconds': null,
          'maintenance_assessment': null,
        },
    ],
    // Flatten units/slots to keep the JSON bounded. Physical identifiers,
    // credentials and material identities from unrelated slots are excluded.
    'ams_units': [
      for (final printer in printers)
        for (final unit
            in printer.state?.lastStatus?.amsUnits ?? const <AmsUnit>[])
          {
            'candidate_id': '${printer.id}',
            'unit_index': unit.id,
            'type': unit.type.name,
            'present': unit.isPresent,
            'extruder_index': unit.extruderId,
            'uses_track_switch': unit.rawInfo == null
                ? null
                : int.tryParse(unit.rawInfo!, radix: 16) == null
                ? null
                : unit.usesFilamentTrackSwitch,
            'telemetry_at': null,
          },
    ],
    'feed_slots': [
      for (final printer in printers)
        for (final unit
            in printer.state?.lastStatus?.amsUnits ?? const <AmsUnit>[])
          for (final slot in unit.trays)
            {
              'candidate_id': '${printer.id}',
              'unit_index': unit.id,
              'slot_index': slot.slot,
              'present': slot.hasFilamentObservation ? slot.hasFilament : null,
              'telemetry_at': null,
            },
    ],
    'training_eligible': false,
  };
  const capacities = {
    'candidate_ids': 16,
    'devices': 16,
    'ams_units': 256,
    'feed_slots': 1024,
  };
  const labels = {
    'candidate_ids': '候选设备',
    'devices': '设备证据',
    'ams_units': 'AMS单元',
    'feed_slots': '供料槽位',
  };
  for (final entry in capacities.entries) {
    if ((observation[entry.key] as List).length > entry.value) {
      throw StateError('采集快照的${labels[entry.key]}超过${entry.value}条容量；不会截取部分证据');
    }
  }
  return observation;
}
