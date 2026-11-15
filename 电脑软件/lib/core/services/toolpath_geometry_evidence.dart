import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'slice_geometry_evidence.dart';

/// A bounded interpretation of commanded positive-extrusion centerlines.
/// This is neither deposited material geometry nor a printer-fit permission.
/// G-code already contains slicer transforms. Unsupported firmware macros,
/// coordinate systems, offsets and motions permanently invalidate coverage.
/// Semantics follow the documented Marlin G0/G1/G2/G3/G90/G91/M82/M83/G92
/// subset; unknown firmware extensions are not silently treated as no-ops.
/// Sources: https://marlinfw.org/docs/gcode/G002-G003.html and
/// https://github.com/bambulab/BambuStudio/blob/master/src/libslic3r/GCodeWriter.cpp
class ToolpathGeometryEvidence {
  ToolpathGeometryEvidence._();

  static const maxGcodeBytes = 16 * 1024 * 1024;
  static const maxCommands = 300000;
  static const maxLineLength = 4096;
  static const maxTools = 16;

  static Map<String, Object?>? fromArchive(
    Archive archive, {
    required String archiveBytesSha256,
    required String stableArtifactSha256,
    required int plateIndex,
  }) {
    // The same declaration reader already checks the exact plate identity,
    // duplicate metadata, archive budget and both file-content hashes.
    if (SliceGeometryEvidence.fromArchive(
          archive,
          archiveBytesSha256: archiveBytesSha256,
          stableArtifactSha256: stableArtifactSha256,
          plateIndex: plateIndex,
        ) ==
        null) {
      return null;
    }
    final path = 'Metadata/plate_$plateIndex.gcode';
    final base = <String, Object?>{
      'schema': 'slice-toolpath-geometry-v1',
      'source': '3mf_selected_gcode',
      'artifact_sha256': stableArtifactSha256.toLowerCase(),
      'plate_index': plateIndex,
      'gcode_entry': path,
      'gcode_sha256': null,
      'status': 'not_present',
      'coverage': 'unknown',
      'coordinate_units': null,
      'coordinate_frame': 'gcode_program',
      'interpretation': 'explicit_marlin_modal_subset_v1',
      'physical_fit': 'not_evaluated',
      'occupied_footprint': 'not_measured',
      'line_width_mm': null,
      'centerline_bounds_mm': null,
      'tool_bounds': <Object?>[],
      'extruding_moves': 0,
      'commands_scanned': 0,
      'reasons': <String>[],
    };
    final entries = archive
        .where((entry) => entry.name.toLowerCase() == path.toLowerCase())
        .toList();
    if (entries.isEmpty) return Map.unmodifiable(base);
    if (entries.length != 1 ||
        !entries.single.isFile ||
        entries.single.size > maxGcodeBytes) {
      return Map.unmodifiable({
        ...base,
        'status': 'unreadable',
        'reasons': ['ambiguous_or_oversized_gcode'],
      });
    }
    try {
      final bytes = entries.single.content as List<int>;
      if (bytes.length > maxGcodeBytes) {
        return Map.unmodifiable({
          ...base,
          'status': 'unreadable',
          'reasons': ['expanded_gcode_budget_exceeded'],
        });
      }
      base['gcode_sha256'] = sha256.convert(bytes).toString();
      return Map.unmodifiable({
        ...base,
        ..._Interpreter().parse(utf8.decode(bytes)),
      });
    } catch (_) {
      return Map.unmodifiable({
        ...base,
        'status': 'unreadable',
        'reasons': ['invalid_gcode_encoding_or_content'],
      });
    }
  }

  static bool matchesBinding(
    Map<String, Object?> evidence, {
    required String? artifactSha256,
    required int plateIndex,
  }) =>
      artifactSha256 != null &&
      RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(artifactSha256) &&
      evidence['schema'] == 'slice-toolpath-geometry-v1' &&
      evidence['artifact_sha256'] == artifactSha256.toLowerCase() &&
      evidence['plate_index'] == plateIndex &&
      evidence['gcode_entry'] == 'Metadata/plate_$plateIndex.gcode' &&
      evidence['physical_fit'] == 'not_evaluated' &&
      evidence['occupied_footprint'] == 'not_measured';
}

class _Bounds {
  final low = List<double>.filled(3, double.infinity);
  final high = List<double>.filled(3, double.negativeInfinity);
  int moves = 0;

  void point(List<double> point) {
    for (var i = 0; i < 3; i++) {
      low[i] = math.min(low[i], point[i]);
      high[i] = math.max(high[i], point[i]);
    }
  }

  List<double> get values => [...low, ...high];
}

class _Interpreter {
  static final words = RegExp(r'([A-Z])([+-]?(?:\d+(?:\.\d*)?|\.\d+))');
  final reasons = <String>{};
  final position = List<double?>.filled(3, null);
  final offset = List<double>.filled(3, 0);
  final all = _Bounds();
  final tools = <int, _Bounds>{};
  double? units;
  bool? absolute, eAbsolute;
  double? extrusion;
  int? tool;
  bool xyPlane = false;
  bool ended = false;
  int commands = 0, moves = 0;

  void unknown(String reason) {
    if (reasons.length < 8) reasons.add(reason);
  }

  Map<String, Object?> parse(String text) {
    final lines = const LineSplitter().convert(text);
    for (final raw in lines) {
      if (raw.length > ToolpathGeometryEvidence.maxLineLength) {
        unknown('line_budget_exceeded');
        break;
      }
      final line = raw.split(';').first.trim().toUpperCase();
      if (line.isEmpty) continue;
      if (ended) {
        unknown('commands_after_program_end');
        break;
      }
      if (++commands > ToolpathGeometryEvidence.maxCommands) {
        unknown('command_budget_exceeded');
        break;
      }
      final tokens = words.allMatches(line).toList();
      final remainder = line
          .replaceAll(words, '')
          .replaceAll(RegExp(r'\s'), '');
      if (tokens.isEmpty || remainder.isNotEmpty) {
        unknown('unsupported_command_syntax');
        continue;
      }
      final command = tokens.first.group(1)!;
      final code = double.parse(tokens.first.group(2)!);
      final args = <String, double>{};
      var valid = code.isFinite;
      for (final token in tokens.skip(1)) {
        final key = token.group(1)!;
        final number = double.parse(token.group(2)!);
        if (args.containsKey(key) ||
            !number.isFinite ||
            number.abs() > 1000000) {
          valid = false;
        }
        args[key] = number;
      }
      if (!valid) {
        unknown('invalid_or_duplicate_parameter');
        continue;
      }
      if (command == 'T' && code == code.roundToDouble() && args.isEmpty) {
        if (code < 0 ||
            code >= 256 ||
            (!tools.containsKey(code.toInt()) &&
                tools.length >= ToolpathGeometryEvidence.maxTools)) {
          unknown('tool_index_or_count_unsupported');
        } else {
          tool = code.toInt();
          tools.putIfAbsent(tool!, _Bounds.new);
          // An explicit E reset or relative E is needed after each tool switch;
          // firmware may keep either shared or per-tool absolute E positions.
          extrusion = null;
        }
      } else if (command == 'G') {
        if ([0, 1, 2, 3].contains(code)) {
          motion(code.toInt(), args);
        } else if ([17, 20, 21, 90, 91].contains(code) && args.isEmpty) {
          if (code == 17) xyPlane = true;
          if (code == 20) units = 25.4;
          if (code == 21) units = 1;
          if (code == 90 || code == 91) {
            absolute = code == 90;
            eAbsolute = absolute; // G90/G91 clear Marlin's M82/M83 override.
          }
        } else if (code == 92) {
          reset(args);
        } else if (code == 4 && args.keys.every({'P', 'S'}.contains)) {
          // Dwell does not change the interpreted coordinates.
        } else {
          unknown('unsupported_motion_or_coordinate_mode');
        }
      } else if (command == 'M' && (code == 82 || code == 83) && args.isEmpty) {
        eAbsolute = code == 82;
      } else if (command == 'M' && (code == 2 || code == 30) && args.isEmpty) {
        ended = true;
      } else if (command == 'M' &&
          [104, 109, 140, 190, 106, 107, 400].contains(code) &&
          args.keys.every({'S', 'R', 'P', 'T'}.contains)) {
        // Only documented heating/fan/wait commands are ignored. In
        // particular M206/M218, firmware macros and conditional blocks fail.
      } else {
        unknown('unsupported_firmware_command');
      }
    }
    if (!ended) unknown('program_end_not_verified');
    if (moves == 0) unknown('no_verified_positive_extrusion');
    final complete = reasons.isEmpty;
    return {
      'status': complete ? 'parsed_centerline' : 'requires_verification',
      'coverage': complete ? 'full_selected_gcode' : 'unknown',
      'coordinate_units': units == null ? null : 'mm',
      'centerline_bounds_mm': complete ? all.values : null,
      'tool_bounds': complete
          ? [
              for (final entry in tools.entries.where((e) => e.value.moves > 0))
                {
                  'tool_index': entry.key,
                  'bounds_mm': entry.value.values,
                  'moves': entry.value.moves,
                },
            ]
          : <Object?>[],
      'extruding_moves': moves,
      'commands_scanned': commands,
      'reasons': reasons.toList(),
    };
  }

  void reset(Map<String, double> args) {
    if (units == null ||
        args.isEmpty ||
        !args.keys.every({'X', 'Y', 'Z', 'E'}.contains)) {
      unknown('unsupported_position_reset');
      return;
    }
    for (var i = 0; i < 3; i++) {
      final value = args['XYZ'[i]];
      if (value == null) continue;
      if (position[i] == null) {
        unknown('position_reset_before_known_position');
      } else {
        offset[i] = position[i]! - value * units!;
      }
    }
    if (args.containsKey('E')) extrusion = args['E']! * units!;
  }

  void motion(int code, Map<String, double> args) {
    if (units == null ||
        absolute == null ||
        (args.containsKey('F') && args['F']! <= 0) ||
        !args.keys.every(
          (code < 2
                  ? {'X', 'Y', 'Z', 'E', 'F'}
                  : {'X', 'Y', 'Z', 'E', 'F', 'I', 'J', 'R'})
              .contains,
        )) {
      unknown('motion_units_mode_or_parameters_unknown');
      return;
    }
    final before = [...position];
    for (var i = 0; i < 3; i++) {
      final value = args['XYZ'[i]];
      if (value == null) continue;
      position[i] = absolute!
          ? value * units! + offset[i]
          : position[i] == null
          ? null
          : position[i]! + value * units!;
    }
    double? delta;
    if (args.containsKey('E')) {
      final value = args['E']! * units!;
      if (eAbsolute == null) {
        unknown('extrusion_mode_unknown');
      } else if (eAbsolute!) {
        if (extrusion == null) {
          unknown('absolute_extrusion_origin_unknown');
        } else {
          delta = value - extrusion!;
        }
        extrusion = value;
      } else {
        delta = value;
        extrusion = extrusion == null ? null : extrusion! + value;
      }
    }
    if (position.whereType<double>().any(
      (v) => !v.isFinite || v.abs() > 1000000,
    )) {
      unknown('coordinate_out_of_supported_range');
      return;
    }
    // A non-extruding unsupported arc still invalidates complete interpretation.
    final points = code >= 2 ? arc(code, args, before, position) : null;
    if (delta == null || delta <= 0) return;
    if (tool == null ||
        before.any((v) => v == null) ||
        position.any((v) => v == null)) {
      unknown('extrusion_position_or_tool_unknown');
      return;
    }
    if (code >= 2 && points == null) return;
    final bounds = tools[tool]!;
    for (final point
        in points ?? [before.cast<double>(), position.cast<double>()]) {
      all.point(point);
      bounds.point(point);
    }
    moves++;
    all.moves++;
    bounds.moves++;
  }

  List<List<double>>? arc(
    int code,
    Map<String, double> args,
    List<double?> start,
    List<double?> end,
  ) {
    if (!xyPlane || start.any((v) => v == null) || end.any((v) => v == null)) {
      unknown('arc_plane_or_position_unknown');
      return null;
    }
    final a = start.cast<double>(), b = end.cast<double>();
    final hasOffsets = args.containsKey('I') || args.containsKey('J');
    final hasRadius = args.containsKey('R');
    if (hasOffsets == hasRadius) {
      unknown('arc_center_ambiguous');
      return null;
    }
    double cx, cy, radius;
    final clockwise = code == 2;
    if (hasOffsets) {
      cx = a[0] + (args['I'] ?? 0) * units!;
      cy = a[1] + (args['J'] ?? 0) * units!;
      radius = math.sqrt(math.pow(a[0] - cx, 2) + math.pow(a[1] - cy, 2));
      final endRadius = math.sqrt(
        math.pow(b[0] - cx, 2) + math.pow(b[1] - cy, 2),
      );
      if (radius <= 1e-9 || (radius - endRadius).abs() > 1e-4) {
        unknown('arc_radius_inconsistent');
        return null;
      }
    } else {
      final signed = args['R']! * units!;
      radius = signed.abs();
      final dx = b[0] - a[0], dy = b[1] - a[1];
      final chord = math.sqrt(dx * dx + dy * dy);
      if (chord <= 1e-9 || radius < chord / 2 || radius > 1000000) {
        unknown('arc_radius_inconsistent');
        return null;
      }
      final height = math.sqrt(
        math.max(0, radius * radius - chord * chord / 4),
      );
      final side = (clockwise ? -1.0 : 1.0) * (signed < 0 ? -1 : 1);
      cx = (a[0] + b[0]) / 2 - side * dy * height / chord;
      cy = (a[1] + b[1]) / 2 + side * dx * height / chord;
    }
    final begin = math.atan2(a[1] - cy, a[0] - cx);
    final finish = math.atan2(b[1] - cy, b[0] - cx);
    final direction = clockwise ? -1.0 : 1.0;
    double normalize(double angle) =>
        (angle % (2 * math.pi) + 2 * math.pi) % (2 * math.pi);
    var sweep = normalize(direction * (finish - begin));
    if (sweep < 1e-10) sweep = 2 * math.pi;
    final result = <List<double>>[
      [...a],
      [...b],
    ];
    for (var quadrant = 0; quadrant < 4; quadrant++) {
      final angle = quadrant * math.pi / 2;
      final travel = normalize(direction * (angle - begin));
      if (travel <= sweep + 1e-10) {
        result.add([
          cx + radius * math.cos(angle),
          cy + radius * math.sin(angle),
          a[2] + (b[2] - a[2]) * travel / sweep,
        ]);
      }
    }
    if (result.expand((p) => p).any((v) => !v.isFinite || v.abs() > 1000000)) {
      unknown('arc_out_of_supported_range');
      return null;
    }
    return result;
  }
}
