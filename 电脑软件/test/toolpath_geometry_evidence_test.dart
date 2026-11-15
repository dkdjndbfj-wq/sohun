import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:consumable_tracker_desktop/core/services/cluster_planning_service.dart';
import 'package:consumable_tracker_desktop/core/services/cluster_training_observation.dart';
import 'package:consumable_tracker_desktop/core/services/toolpath_geometry_evidence.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/threemf_parser.dart';

import 'slice_geometry_evidence_test.dart' as fixture;

const header = 'G21\nG90\nG17\nT0\nM83\nG1 X10 Y10 Z0.2\n';

Archive archive(String? gcode, {int index = 1}) {
  final result = fixture.fixtureArchive(index: index);
  if (gcode != null) {
    result.addFile(fixture.textFile('Metadata/plate_$index.gcode', gcode));
  }
  return result;
}

Map<String, Object?> parse(String text) => ToolpathGeometryEvidence.fromArchive(
  archive(text),
  archiveBytesSha256: fixture.hashA,
  stableArtifactSha256: fixture.hashA,
  plateIndex: 1,
)!;

void main() {
  test('full selected program measures all positive-extrusion layers only', () {
    final value = parse('${header}G1 X20 E1\nG1 Z4\nG1 Y30 E2\nM2');
    expect(value['status'], 'parsed_centerline');
    expect(value['coverage'], 'full_selected_gcode');
    expect(value['centerline_bounds_mm'], [10.0, 10.0, .2, 20.0, 30.0, 4.0]);
    expect(value['extruding_moves'], 2);
    expect(value['line_width_mm'], isNull);
    expect(value['occupied_footprint'], 'not_measured');
    expect(value['physical_fit'], 'not_evaluated');
  });

  test('relative XYZ and explicit relative extrusion retain program frame', () {
    final value = parse('${header}G91\nM83\nG1 X5 Y-2 Z1 E1\nM30');
    expect(value['centerline_bounds_mm'], [10.0, 8.0, .2, 15.0, 10.0, 1.2]);
    expect(value['coordinate_frame'], 'gcode_program');
  });

  test('G92 resets logical coordinates without moving physical centerline', () {
    final value = parse('${header}M82\nG92 X0 E100\nG1 X5 E101\nM2');
    expect(value['centerline_bounds_mm'], [10.0, 10.0, .2, 15.0, 10.0, .2]);
    expect(value['extruding_moves'], 1);
  });

  test(
    'absolute extrusion retract and prime do not omit later positive move',
    () {
      final value = parse(
        '${header}M82\nG92 E0\nG1 X20 E1\nG1 E0.5\nG1 X30 E1.5\nM2',
      );
      expect(value['status'], 'parsed_centerline');
      expect(value['extruding_moves'], 2);
      expect((value['centerline_bounds_mm'] as List)[3], 30);
    },
  );

  test('G90 clears the Marlin relative extrusion override', () {
    final value = parse('${header}G90\nG92 E0\nG1 X20 E1\nG1 X30 E0.5\nM2');
    expect(value['extruding_moves'], 1);
    expect((value['centerline_bounds_mm'] as List)[3], 20);
  });

  test('XY I/J arcs include intermediate extrema and helical height', () {
    final clockwise = parse('${header}G2 X20 Y10 Z1.2 I5 J0 E1\nM2');
    expect(clockwise['status'], 'parsed_centerline');
    expect((clockwise['centerline_bounds_mm'] as List)[4], closeTo(15, 1e-8));
    expect((clockwise['centerline_bounds_mm'] as List)[5], closeTo(1.2, 1e-8));
    final anticlockwise = parse('${header}G3 X20 Y10 I5 J0 E1\nM2');
    expect(
      (anticlockwise['centerline_bounds_mm'] as List)[1],
      closeTo(5, 1e-8),
    );
    final circle = parse('${header}G2 I5 J0 E1\nM2');
    final bounds = circle['centerline_bounds_mm'] as List;
    expect(bounds[0], closeTo(10, 1e-8));
    expect(bounds[1], closeTo(5, 1e-8));
    expect(bounds[3], closeTo(20, 1e-8));
    expect(bounds[4], closeTo(15, 1e-8));
  });

  test('signed R arcs distinguish minor and major arcs', () {
    final minor = parse('${header}G3 X15 Y15 R5 E1\nM2');
    final major = parse('${header}G3 X15 Y15 R-5 E1\nM2');
    expect(minor['status'], 'parsed_centerline');
    expect(major['status'], 'parsed_centerline');
    expect(
      (major['centerline_bounds_mm'] as List)[1],
      lessThan((minor['centerline_bounds_mm'] as List)[1]),
    );
    expect(
      (major['centerline_bounds_mm'] as List)[3],
      greaterThan((minor['centerline_bounds_mm'] as List)[3]),
    );
  });

  test('tool bounds separate explicit tools and do not guess unknown tool', () {
    final value = parse('${header}G1 X20 E1\nT1\nG1 Y30 E1\nM2');
    final tools = value['tool_bounds'] as List;
    expect(tools.length, 2);
    expect((tools[0] as Map)['tool_index'], 0);
    expect((tools[1] as Map)['tool_index'], 1);
    expect(
      parse('G21\nG90\nM83\nG1 X1 Y1 Z1\nG1 X2 E1\nM2')['status'],
      'requires_verification',
    );
  });

  test('inch units are explicit and converted to millimeter coordinates', () {
    final value = parse('G20\nG90\nT0\nM83\nG1 X1 Y1 Z1\nG1 X2 E1\nM2');
    expect(value['coordinate_units'], 'mm');
    expect((value['centerline_bounds_mm'] as List)[3], closeTo(50.8, 1e-8));
  });

  test(
    'unknown commands modes offsets and invalid arcs never regain completeness',
    () {
      for (final command in [
        'G68 R45',
        'M206 X1',
        'M218 X1',
        'M1002 S1',
        'G28',
        'G18',
        'G2 X20 R1 E1',
        'G2 X20 I5 R5 E1',
        'G1 Xnan E1',
        'G1 X1 X2 E1',
      ]) {
        final value = parse(
          '$header$command\nG21\nG90\nG17\nM83\nG1 X20 E1\nM2',
        );
        expect(value['status'], 'requires_verification', reason: command);
        expect(value['coverage'], 'unknown', reason: command);
        expect(value['centerline_bounds_mm'], isNull, reason: command);
        expect(value['tool_bounds'], isEmpty, reason: command);
      }
    },
  );

  test(
    'fragments, missing modes, long lines and commands after end are incomplete',
    () {
      for (final program in [
        '${header}G1 X20 E1',
        'G90\nT0\nM83\nG1 X10 Y10 Z1\nG1 X20 E1\nM2',
        'G21\nG90\nT0\nM82\nG1 X10 Y10 Z1\nG1 X20 E1\nM2',
        '$header${' '.padRight(4100)}\nG1 X20 E1\nM2',
        '${header}G1 X20 E1\nM2\nG1 X30 E1',
      ]) {
        final value = parse(program);
        expect(value['status'], 'requires_verification');
        expect(value['coverage'], 'unknown');
      }
    },
  );

  test(
    'absent and ambiguous selected entries stay distinct; hashes bind exact plate',
    () {
      Map<String, Object?>? read(
        Archive input, {
        String? hash,
        int index = 1,
      }) => ToolpathGeometryEvidence.fromArchive(
        input,
        archiveBytesSha256: fixture.hashA,
        stableArtifactSha256: hash ?? fixture.hashA,
        plateIndex: index,
      );
      expect(read(archive(null))!['status'], 'not_present');
      expect(read(archive('$header\nM2'), hash: fixture.hashB), isNull);
      expect(read(archive('$header\nM2'), index: 2), isNull);
      final duplicate = archive('${header}G1 X20 E1\nM2')
        ..addFile(
          fixture.textFile('metadata/plate_1.gcode', '${header}G1 X30 E1\nM2'),
        );
      expect(read(duplicate)!['status'], 'unreadable');
    },
  );

  test(
    'size command and tool budgets reject whole evidence without a partial box',
    () {
      final oversized = archive(null)
        ..addFile(
          ArchiveFile(
            'Metadata/plate_1.gcode',
            ToolpathGeometryEvidence.maxGcodeBytes + 1,
            <int>[],
          ),
        );
      final sizeResult = ToolpathGeometryEvidence.fromArchive(
        oversized,
        archiveBytesSha256: fixture.hashA,
        stableArtifactSha256: fixture.hashA,
        plateIndex: 1,
      )!;
      expect(sizeResult['status'], 'unreadable');
      final commands = parse(
        '$header${List.filled(ToolpathGeometryEvidence.maxCommands, 'G4 P0\n').join()}G1 X20 E1\nM2',
      );
      expect(commands['coverage'], 'unknown');
      expect(commands['centerline_bounds_mm'], isNull);
      expect(commands['reasons'], contains('command_budget_exceeded'));
      final manyTools = parse(
        '$header${List.generate(17, (i) => 'T$i\n').join()}G1 X20 E1\nM2',
      );
      expect(manyTools['coverage'], 'unknown');
      expect(manyTools['reasons'], contains('tool_index_or_count_unsupported'));
    },
  );

  test(
    'actual 3MF parse carries selected toolpath through plan and observation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mifu-toolpath-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/selected.3mf';
      await File(path).writeAsBytes(
        ZipEncoder().encode(
          archive(
            '; HEADER_BLOCK_START\n'
            '; BambuStudio 02.07.01.57\n'
            '; total filament weight [g] : 10\n'
            '; total filament length [mm] : 3000\n'
            '; total estimated time: 1h\n'
            '; HEADER_BLOCK_END\n'
            '; CONFIG_BLOCK_START\n'
            '; printer_settings_id = "Bambu Lab P1S 0.4 nozzle"\n'
            '; nozzle_diameter = [0.4]\n'
            '; filament_type = PLA\n'
            '; filament_colour = #FFFFFF\n'
            '; CONFIG_BLOCK_END\n'
            '${header}G1 X20 E1\nG1 Z5\nG1 Y30 E1\nM2',
          ),
        )!,
      );
      final parsed = await ThreemfParser.parseFile(path);
      expect(parsed, isNotNull);
      expect(parsed!.toolpathGeometry!['status'], 'parsed_centerline');
      final plate = fixture.plate(path: path, hash: parsed.artifactSha256);
      final inspector = ClusterSliceInspector();
      final actualEvidence = await inspector.inspect(plate);
      expect(actualEvidence.blockers, isEmpty);
      expect(actualEvidence.toolpathGeometry, parsed.toolpathGeometry);
      final source = fixture.studio(plate);
      final snapshot =
          await ClusterPlanningService(
            inspectArtifact: inspector.inspect,
          ).build(
            studio: source,
            printers: const [],
            fleet: const {},
            allowedConsumableIds: const {},
            channelAvailableGrams: const {},
            activeQueueCounts: const {},
            now: fixture.fixtureTime,
          );
      final plan = snapshot.plates.single;
      expect(plan.toolpathGeometry, parsed.toolpathGeometry);
      final observation = clusterTrainingObservation(
        snapshot,
        plan,
        const [],
        'test-request',
      );
      expect(observation['toolpath_geometry'], parsed.toolpathGeometry);
      expect(jsonEncode(observation), isNot(contains('filePath')));
      expect((observation['geometry'] as Map)['status'], 'not_measured');
    },
  );
}
