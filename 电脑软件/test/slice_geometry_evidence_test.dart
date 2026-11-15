import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/core/services/cluster_planning_service.dart';
import 'package:consumable_tracker_desktop/core/services/cluster_training_observation.dart';
import 'package:consumable_tracker_desktop/core/services/slice_geometry_evidence.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/threemf_parser.dart';

final hashA = List.filled(64, 'a').join();
final hashB = List.filled(64, 'b').join();
final fixtureTime = DateTime.utc(2026, 11, 12);

Map<String, Object?> settings() => {
  'units': 'mm',
  'printable_area': ['0x0', '100x0', '100x80', '0x80'],
  'printable_height': '120',
  'bed_exclude_area': <String>[],
  'extruder_printable_area': ['0x0,60x0,60x80,0x80', '40x0,100x0,100x80,40x80'],
};

ArchiveFile textFile(String path, String text) {
  final bytes = utf8.encode(text);
  return ArchiveFile(path, bytes.length, bytes);
}

Archive fixtureArchive({Object? project, int index = 1, String? raw}) {
  final archive = Archive()
    ..addFile(
      textFile('Metadata/slice_info.config', '''
<config><plate><metadata key="index" value="$index"/>
<metadata key="prediction" value="3600"/>
<filament id="1" used_g="10" used_m="3" type="PLA" color="#FFFFFF"/>
</plate></config>'''),
    );
  if (project != null || raw != null) {
    archive.addFile(
      textFile('Metadata/project_settings.config', raw ?? jsonEncode(project)),
    );
  }
  return archive;
}

Map<String, Object?> parse(Object? project, {String? raw}) =>
    SliceGeometryEvidence.fromArchive(
      fixtureArchive(project: project, raw: raw),
      archiveBytesSha256: hashA,
      stableArtifactSha256: hashA,
      plateIndex: 1,
    )!;

Map field(Map evidence, String name) =>
    (evidence['fields'] as Map)[name] as Map;

StudioProductionPlate plate({String? path, String? hash, int index = 1}) =>
    StudioProductionPlate(
      id: 'plate',
      workspaceId: 'workspace',
      orderId: 'order',
      packageId: 'package',
      plateIndex: index,
      name: 'fixture',
      requiredRuns: 1,
      estimatedSeconds: 3600,
      estimatedGrams: 10,
      createdAt: fixtureTime,
      sliceStatus: StudioPlateSliceStatus.sliced,
      autoEjectEnabled: false,
      sliceArtifactPath: path,
      sliceArtifactSha256: hash ?? hashA,
      sliceTargetModel: 'P1S',
      sliceNozzleDiameter: .4,
      filaments: const [
        StudioPlateFilamentUsage(
          toolIndex: 0,
          grams: 10,
          materialType: 'PLA',
          colorHex: '#FFFFFF',
        ),
      ],
    );

StudioSnapshot studio(StudioProductionPlate item, {bool pending = true}) =>
    StudioSnapshot(
      workspace: StudioWorkspace(
        id: 'workspace',
        name: 'fixture',
        createdAt: fixtureTime,
        updatedAt: fixtureTime,
      ),
      members: const [],
      customers: const [],
      quotes: const [],
      inventoryEvents: const [],
      inventoryBatches: const [],
      shareLinks: const [],
      orders: [
        StudioOrder(
          id: 'order',
          workspaceId: 'workspace',
          orderNo: '1',
          title: 'fixture',
          status: StudioOrderStatus.production,
          totalPrice: 0,
          createdAt: fixtureTime,
          updatedAt: fixtureTime,
        ),
      ],
      productionPackages: [
        StudioProductionPackage(
          id: 'package',
          workspaceId: 'workspace',
          orderId: 'order',
          sourceName: 'fixture',
          artifactKind: '3mf',
          createdAt: fixtureTime,
        ),
      ],
      productionPlates: [item],
      workOrders: [
        StudioWorkOrder(
          id: 'work',
          workspaceId: 'workspace',
          orderId: 'order',
          productionPlateId: item.id,
          title: 'fixture',
          quantity: 1,
          completedQuantity: pending ? 0 : 1,
          status: pending
              ? StudioWorkOrderStatus.queued
              : StudioWorkOrderStatus.completed,
          materialCostSnapshot: 0,
          quotedPriceSnapshot: 0,
          createdAt: fixtureTime,
          updatedAt: fixtureTime,
        ),
      ],
    );

Future<ClusterPlanningSnapshot> buildPlan(
  StudioProductionPlate item,
  Map<String, Object?>? evidence, {
  bool pending = true,
}) =>
    ClusterPlanningService(
      inspectArtifact: (_) async => ClusterArtifactEvidence(
        declaredSliceGeometry: evidence,
        blockers: const ['fixture has no printer eligibility'],
      ),
    ).build(
      studio: studio(item, pending: pending),
      printers: const [],
      fleet: const {},
      allowedConsumableIds: const {},
      channelAvailableGrams: const {},
      activeQueueCounts: const {},
      now: fixtureTime,
    );

void main() {
  test(
    'only actual declared fields are parsed, never occupied geometry or fit',
    () {
      final result = parse(settings());
      expect(result['status'], 'declared_fields_parsed');
      expect(result['coordinate_units'], 'mm');
      expect(field(result, 'printable_area')['xy'], [
        0,
        0,
        100,
        0,
        100,
        80,
        0,
        80,
      ]);
      expect(field(result, 'printable_height')['value'], 120);
      expect(field(result, 'bed_exclude_area')['status'], 'declared_empty');
      expect(
        field(result, 'extruder_printable_area')['xy_by_extruder'],
        hasLength(2),
      );
      expect(result['physical_fit'], 'not_evaluated');
      expect(result['occupied_footprint'], 'not_measured');
      expect(result['artifact_sha256'], hashA);
      expect(result['plate_index'], 1);
      expect(result['settings_sha256'], hasLength(64));
    },
  );

  test(
    'missing settings and partial geometry never receive preset defaults',
    () {
      expect(parse(null)['status'], 'not_present');
      final result = parse({'printable_height': '120'});
      expect(result['status'], 'partial_declaration');
      for (final name in [
        'printable_area',
        'bed_exclude_area',
        'extruder_printable_area',
      ]) {
        expect(field(result, name)['status'], 'missing');
        expect(field(result, name)['raw'], isNull);
      }
      expect(jsonEncode(result['fields']), isNot(contains('256')));
    },
  );

  test(
    'missing unsupported and conflicting units stay unknown without conversion',
    () {
      final missing = settings()..remove('units');
      expect(parse(missing)['unit_status'], 'not_declared');
      for (final units in ['inch', 'cm', true, 1, null]) {
        final result = parse({...settings(), 'units': units});
        expect(result['coordinate_units'], isNull);
        expect(result['unit_status'], 'unsupported_or_conflicting');
        expect(field(result, 'printable_height')['value'], 120);
      }
      expect(
        parse({...settings(), 'unit': 'inch'})['coordinate_units'],
        isNull,
      );
      expect(
        parse({...settings(), 'unit': 'millimeter'})['coordinate_units'],
        'mm',
      );
    },
  );

  test(
    'invalid heights and nonfinite or malformed coordinates fail closed',
    () {
      for (final value in [
        true,
        -1,
        0,
        'NaN',
        'Infinity',
        '1e309',
        '120mm',
        [120],
      ]) {
        expect(
          field(
            parse({...settings(), 'printable_height': value}),
            'printable_height',
          )['status'],
          'invalid',
        );
      }
      for (final points in [
        ['0x0', '100x0'],
        ['0x0', 'NaNx0', '0x80'],
        ['0x0', '1e309x0', '0x80'],
        ['0x0', true, '0x80'],
        ['0x0', '100x0', '100x0', '0x80'],
        ['0x0', '100x80', '0x80', '100x0'],
        ['0x0', '1x0', '2x0'],
        List.filled(40, '1x2'),
      ]) {
        expect(
          field(
            parse({...settings(), 'printable_area': points}),
            'printable_area',
          )['status'],
          'invalid',
        );
      }
    },
  );

  test(
    'negative coordinates are preserved and closed clockwise polygon is parsed',
    () {
      final result = parse({
        ...settings(),
        'printable_area': ['-10x-10', '-10x10', '10x10', '10x-10', '-10x-10'],
      });
      expect(field(result, 'printable_area')['status'], 'syntax_parsed');
      expect(field(result, 'printable_area')['xy'], [
        -10,
        -10,
        -10,
        10,
        10,
        10,
        10,
        -10,
      ]);
    },
  );

  test(
    'duplicate JSON keys including escapes are unreadable, not last-wins evidence',
    () {
      for (final raw in [
        r'{"printable_height":"120","printable_height":"999"}',
        r'{"printable_height":"120","printable\u005fheight":"999"}',
      ]) {
        expect(parse(null, raw: raw)['status'], 'unreadable');
      }
      expect(parse(null, raw: '{invalid')['status'], 'unreadable');
    },
  );

  test('oversized and ambiguous metadata are bounded before expansion', () {
    expect(
      parse(
        null,
        raw: ' ' * (SliceGeometryEvidence.maxSettingsBytes + 1),
      )['status'],
      'unreadable',
    );
    final archive = fixtureArchive(project: settings())
      ..addFile(
        textFile('Metadata/PROJECT_SETTINGS.config', jsonEncode(settings())),
      );
    expect(
      SliceGeometryEvidence.fromArchive(
        archive,
        archiveBytesSha256: hashA,
        stableArtifactSha256: hashA,
        plateIndex: 1,
      )!['status'],
      'unreadable',
    );
    expect(
      field(
        parse({
          ...settings(),
          'extruder_printable_area': List.filled(17, '0x0,2x0,2x2,0x2'),
        }),
        'extruder_printable_area',
      )['status'],
      'invalid',
    );
  });

  test(
    'archive bytes, stable artifact and exact selected plate must agree',
    () {
      final archive = fixtureArchive(project: settings(), index: 2);
      expect(
        SliceGeometryEvidence.fromArchive(
          archive,
          archiveBytesSha256: hashA,
          stableArtifactSha256: hashB,
          plateIndex: 2,
        ),
        isNull,
      );
      expect(
        SliceGeometryEvidence.fromArchive(
          archive,
          archiveBytesSha256: 'bad',
          stableArtifactSha256: 'bad',
          plateIndex: 2,
        ),
        isNull,
      );
      expect(
        SliceGeometryEvidence.fromArchive(
          archive,
          archiveBytesSha256: hashA,
          stableArtifactSha256: hashA,
          plateIndex: 1,
        ),
        isNull,
      );
      final valid = SliceGeometryEvidence.fromArchive(
        archive,
        archiveBytesSha256: hashA,
        stableArtifactSha256: hashA,
        plateIndex: 2,
      )!;
      expect(
        SliceGeometryEvidence.matchesBinding(
          valid,
          artifactSha256: hashA,
          plateIndex: 2,
        ),
        isTrue,
      );
      expect(
        SliceGeometryEvidence.matchesBinding(
          valid,
          artifactSha256: hashB,
          plateIndex: 2,
        ),
        isFalse,
      );
      expect(
        SliceGeometryEvidence.matchesBinding(
          valid,
          artifactSha256: hashA,
          plateIndex: 1,
        ),
        isFalse,
      );
    },
  );

  test(
    '3MF parser and cluster inspector propagate the real compressed-byte hash',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'slice-geometry-evidence-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final archive = fixtureArchive(project: settings())
        ..addFile(
          textFile('Metadata/plate_1.gcode', '''
; HEADER_BLOCK_START
; BambuStudio 02.07.01.57
; total filament weight [g] : 10
; total filament length [mm] : 3000
; total estimated time: 1h
; HEADER_BLOCK_END
; CONFIG_BLOCK_START
; printer_settings_id = "Bambu Lab P1S 0.4 nozzle"
; nozzle_diameter = [0.4]
; filament_type = PLA
; filament_colour = #FFFFFF
; CONFIG_BLOCK_END
G1 X10 Y10
'''),
        );
      final bytes = ZipEncoder().encode(archive)!;
      final actualHash = sha256.convert(bytes).toString();
      final file = File('${temp.path}/fixture.3mf');
      await file.writeAsBytes(bytes);
      final parsed = await ThreemfParser.parseFile(file.path);
      expect(parsed!.declaredSliceGeometry!['artifact_sha256'], actualHash);
      expect(parsed.declaredSliceGeometry!['plate_index'], 1);
      final inspector = await ClusterSliceInspector().inspect(
        plate(path: file.path, hash: actualHash),
      );
      expect(inspector.blockers, isEmpty);
      expect(inspector.declaredSliceGeometry!['artifact_sha256'], actualHash);
      final wrong = await ClusterSliceInspector().inspect(
        plate(path: file.path, hash: hashB),
      );
      expect(wrong.declaredSliceGeometry, isNull);
      expect(wrong.blockers, isNotEmpty);
    },
  );

  test(
    'planning propagates only audit data; occupied geometry and model inputs stay unchanged',
    () async {
      final evidence = parse(settings());
      final snapshot = await buildPlan(plate(), evidence);
      final plan = snapshot.plates.single;
      expect(plan.declaredSliceGeometry, evidence);
      expect(
        plan.toModelFeatures().containsKey('declared_slice_geometry'),
        isFalse,
      );
      expect(
        jsonEncode(snapshot.toModelInput()),
        isNot(contains('printable_area')),
      );
      final observation = clusterTrainingObservation(
        snapshot,
        plan,
        const [],
        'request',
      );
      expect(observation['declared_slice_geometry'], evidence);
      expect((observation['geometry'] as Map)['status'], 'not_measured');
      expect((observation['geometry'] as Map)['footprint_mm'], isNull);
      void checkBudget(Object? value, int depth) {
        expect(depth, lessThanOrEqualTo(6));
        if (value is Map) {
          expect(value.length, lessThanOrEqualTo(64));
          for (final item in value.values) {
            checkBudget(item, depth + 1);
          }
        } else if (value is List) {
          expect(value.length, lessThanOrEqualTo(64));
          for (final item in value) {
            checkBudget(item, depth + 1);
          }
        }
      }

      checkBudget(observation, 0);
    },
  );

  test(
    'observation rejects mismatched audit bindings and finished plates are not reopened',
    () async {
      final mismatch = await buildPlan(plate(hash: hashB), parse(settings()));
      expect(
        () => clusterTrainingObservation(
          mismatch,
          mismatch.plates.single,
          const [],
          'request',
        ),
        throwsStateError,
      );
      var inspections = 0;
      final completed =
          await ClusterPlanningService(
            inspectArtifact: (_) async {
              inspections++;
              return ClusterArtifactEvidence(
                declaredSliceGeometry: parse(settings()),
              );
            },
          ).build(
            studio: studio(plate(), pending: false),
            printers: const [],
            fleet: const {},
            allowedConsumableIds: const {},
            channelAvailableGrams: const {},
            activeQueueCounts: const {},
            now: fixtureTime,
          );
      expect(inspections, 0);
      expect(completed.plates.single.declaredSliceGeometry, isNull);
    },
  );
}
