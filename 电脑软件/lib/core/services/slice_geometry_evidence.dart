import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import '../utils/zip_safety.dart';

/// Audits actual 3MF settings; never measures an occupied footprint or tests fit.
///
/// The parser supplies the hash of the SAME compressed bytes it decoded and its
/// subsequent stable on-disk hash. No inherited/default printer preset is used.
/// Project settings apply to the project, not proof of a particular installed
/// machine or tool. Missing unit declarations remain unknown; mesh units are not
/// copied onto slicer settings. Unsupported geometry is retained only as bounded
/// raw evidence with an invalid status, never silently repaired or truncated.
class SliceGeometryEvidence {
  SliceGeometryEvidence._();

  static const maxSettingsBytes = 256 * 1024;
  static const maxPolygonVertices = 32;
  static const maxExtruders = 16;
  static const _settingsPath = 'Metadata/project_settings.config';
  static final _hash = RegExp(r'^[a-fA-F0-9]{64}$');
  static final _number = RegExp(
    r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$',
  );

  static Map<String, Object?>? fromArchive(
    Archive archive, {
    required String archiveBytesSha256,
    required String stableArtifactSha256,
    required int plateIndex,
  }) {
    if (!_hash.hasMatch(archiveBytesSha256) ||
        !_hash.hasMatch(stableArtifactSha256) ||
        archiveBytesSha256.toLowerCase() !=
            stableArtifactSha256.toLowerCase() ||
        plateIndex < 1 ||
        !isSafe3mfArchive(archive) ||
        !_hasExactPlate(archive, plateIndex)) {
      return null;
    }
    final result = <String, Object?>{
      'schema': 'slice-declared-geometry-v1',
      'source': '3mf_project_settings',
      'artifact_sha256': stableArtifactSha256.toLowerCase(),
      'plate_index': plateIndex,
      'settings_entry': _settingsPath,
      'settings_scope': 'project_wide_declaration_not_installed_machine',
      'settings_sha256': null,
      'status': 'not_present',
      'coordinate_units': null,
      'unit_status': 'not_declared',
      'physical_fit': 'not_evaluated',
      'occupied_footprint': 'not_measured',
    };
    final entries = archive
        .where(
          (entry) => entry.name.toLowerCase() == _settingsPath.toLowerCase(),
        )
        .toList();
    if (entries.isEmpty) return Map.unmodifiable(result);
    if (entries.length != 1 ||
        !entries.single.isFile ||
        entries.single.size > maxSettingsBytes) {
      return Map.unmodifiable({
        ...result,
        'status': 'unreadable',
        'reason': 'ambiguous_or_oversized_settings',
      });
    }
    try {
      final bytes = entries.single.content as List<int>;
      if (bytes.length > maxSettingsBytes) {
        return Map.unmodifiable({
          ...result,
          'status': 'unreadable',
          'reason': 'expanded_settings_budget_exceeded',
        });
      }
      result['settings_sha256'] = sha256.convert(bytes).toString();
      final text = utf8.decode(bytes);
      if (!_uniqueRootKeys(text)) {
        throw const FormatException('duplicate setting');
      }
      final settings = jsonDecode(text);
      if (settings is! Map<String, dynamic>) {
        throw const FormatException('settings object required');
      }
      final units = _units(settings);
      result.addAll(units);
      final fields = <String, Object?>{
        'printable_area': _polygonField(
          settings,
          'printable_area',
          allowEmpty: false,
        ),
        'printable_height': _heightField(settings),
        'bed_exclude_area': _polygonField(
          settings,
          'bed_exclude_area',
          allowEmpty: true,
        ),
        'extruder_printable_area': _extruderField(settings),
      };
      result['fields'] = fields;
      final statuses = fields.values.map((field) => (field as Map)['status']);
      result['status'] = statuses.any((status) => status == 'invalid')
          ? 'invalid_declared_field'
          : statuses.any((status) => status == 'missing') ||
                units['coordinate_units'] != 'mm'
          ? 'partial_declaration'
          : 'declared_fields_parsed';
      return Map.unmodifiable(result);
    } catch (_) {
      return Map.unmodifiable({
        ...result,
        'status': 'unreadable',
        'reason': 'settings_not_strict_json',
      });
    }
  }

  static bool matchesBinding(
    Map<String, Object?> evidence, {
    required String? artifactSha256,
    required int plateIndex,
  }) =>
      artifactSha256 != null &&
      _hash.hasMatch(artifactSha256) &&
      evidence['schema'] == 'slice-declared-geometry-v1' &&
      evidence['artifact_sha256'] == artifactSha256.toLowerCase() &&
      evidence['plate_index'] == plateIndex &&
      evidence['physical_fit'] == 'not_evaluated' &&
      evidence['occupied_footprint'] == 'not_measured';

  static bool _hasExactPlate(Archive archive, int selected) {
    final entries = archive
        .where(
          (entry) => entry.name.toLowerCase() == 'metadata/slice_info.config',
        )
        .toList();
    if (entries.length != 1 ||
        !entries.single.isFile ||
        entries.single.size > maxSettingsBytes) {
      return false;
    }
    try {
      final bytes = entries.single.content as List<int>;
      if (bytes.length > maxSettingsBytes) return false;
      final document = XmlDocument.parse(utf8.decode(bytes));
      final seen = <int>{};
      for (final plate in document.findAllElements('plate')) {
        final indices = plate
            .findElements('metadata')
            .where((item) => item.getAttribute('key') == 'index')
            .toList();
        if (indices.length != 1) return false;
        final raw = indices.single.getAttribute('value');
        if (raw == null || !RegExp(r'^[1-9]\d*$').hasMatch(raw)) return false;
        final index = int.tryParse(raw);
        if (index == null || !seen.add(index)) return false;
      }
      return seen.contains(selected);
    } catch (_) {
      return false;
    }
  }

  static Map<String, Object?> _units(Map<String, dynamic> settings) {
    final declarations = [
      for (final key in ['unit', 'units'])
        if (settings.containsKey(key)) settings[key],
    ];
    if (declarations.isEmpty) {
      return {'coordinate_units': null, 'unit_status': 'not_declared'};
    }
    final normalized = declarations
        .map(
          (value) =>
              value is String &&
                  [
                    'mm',
                    'millimeter',
                    'millimeters',
                  ].contains(value.trim().toLowerCase())
              ? 'mm'
              : null,
        )
        .toList();
    return {
      'coordinate_units': normalized.every((value) => value == 'mm')
          ? 'mm'
          : null,
      'unit_status': normalized.every((value) => value == 'mm')
          ? 'declared_mm'
          : 'unsupported_or_conflicting',
      'unit_raw': declarations.map(_boundedRaw).toList(),
    };
  }

  static Object? _boundedRaw(Object? value) {
    if (value == null || value is bool) return value;
    if (value is num) return value.isFinite ? value : null;
    if (value is String) return value.length <= 4096 ? value : null;
    if (value is List &&
        value.length <= 64 &&
        value.every(
          (item) =>
              item == null || item is bool || item is num || item is String,
        )) {
      return value.map(_boundedRaw).toList();
    }
    return null;
  }

  static Map<String, Object?> _polygonField(
    Map<String, dynamic> settings,
    String key, {
    required bool allowEmpty,
  }) {
    if (!settings.containsKey(key)) {
      return {'status': 'missing', 'raw': null, 'xy': null};
    }
    final raw = settings[key];
    final xy = _polygon(raw, allowEmpty: allowEmpty);
    return {
      'status': xy == null
          ? 'invalid'
          : xy.isEmpty
          ? 'declared_empty'
          : 'syntax_parsed',
      'raw': _boundedRaw(raw),
      'xy': xy,
    };
  }

  static Map<String, Object?> _heightField(Map<String, dynamic> settings) {
    if (!settings.containsKey('printable_height')) {
      return {'status': 'missing', 'raw': null, 'value': null};
    }
    final raw = settings['printable_height'];
    final value = _finiteNumber(raw);
    final usable = value != null && value > 0;
    return {
      'status': usable ? 'syntax_parsed' : 'invalid',
      'raw': _boundedRaw(raw),
      'value': usable ? value : null,
    };
  }

  static Map<String, Object?> _extruderField(Map<String, dynamic> settings) {
    if (!settings.containsKey('extruder_printable_area')) {
      return {'status': 'missing', 'raw': null, 'xy_by_extruder': null};
    }
    final raw = settings['extruder_printable_area'];
    final result = <String, Object?>{
      'status': 'invalid',
      'raw': _boundedRaw(raw),
      'xy_by_extruder': null,
      'tool_mapping': 'array_index_only_installed_tool_identity_unverified',
    };
    if (raw is! List || raw.length > maxExtruders) return result;
    final regions = raw
        .map(
          (value) =>
              value is String ? _polygon(value, allowEmpty: false) : null,
        )
        .toList();
    if (regions.any((value) => value == null)) return result;
    return {
      ...result,
      'status': regions.isEmpty ? 'declared_empty' : 'syntax_parsed',
      'xy_by_extruder': regions,
    };
  }

  static double? _finiteNumber(Object? value) {
    double? number;
    if (value is num) {
      number = value.toDouble();
    } else if (value is String &&
        value.length <= 64 &&
        _number.hasMatch(value.trim())) {
      number = double.tryParse(value.trim());
    }
    return number != null && number.isFinite && number.abs() <= 1000000
        ? number
        : null;
  }

  static List<double>? _polygon(Object? value, {required bool allowEmpty}) {
    final List<dynamic> values;
    if (value is String && value.length <= 4096) {
      values = value.split(',');
    } else if (value is List) {
      values = value;
    } else {
      return null;
    }
    if (values.isEmpty) return allowEmpty ? [] : null;
    if (values.length < 3 || values.length > maxPolygonVertices + 1) {
      return null;
    }
    final points = <List<double>>[];
    for (final point in values) {
      if (point is! String || point.length > 128) return null;
      final parts = point.split(RegExp('[xX]'));
      if (parts.length != 2) return null;
      final x = _finiteNumber(parts[0]), y = _finiteNumber(parts[1]);
      if (x == null || y == null) return null;
      points.add([x, y]);
    }
    if (points.first[0] == points.last[0] &&
        points.first[1] == points.last[1]) {
      points.removeLast();
    }
    if (points.length < 3 || points.length > maxPolygonVertices) return null;
    if (points.map((point) => '${point[0]},${point[1]}').toSet().length !=
        points.length) {
      return null;
    }
    double cross(List<double> a, List<double> b, List<double> c) =>
        (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    double area = 0;
    for (var i = 0; i < points.length; i++) {
      final a = points[i], b = points[(i + 1) % points.length];
      area += cross(points.first, a, b);
      for (var j = i + 1; j < points.length; j++) {
        if (j == i + 1 || (i == 0 && j == points.length - 1)) continue;
        final c = points[j], d = points[(j + 1) % points.length];
        bool straddles(double first, double second) =>
            (first <= 1e-9 && second >= -1e-9) ||
            (second <= 1e-9 && first >= -1e-9);
        final xOverlap =
            [a[0], b[0]].reduce((x, y) => x < y ? x : y) <=
                [c[0], d[0]].reduce((x, y) => x > y ? x : y) &&
            [c[0], d[0]].reduce((x, y) => x < y ? x : y) <=
                [a[0], b[0]].reduce((x, y) => x > y ? x : y);
        final yOverlap =
            [a[1], b[1]].reduce((x, y) => x < y ? x : y) <=
                [c[1], d[1]].reduce((x, y) => x > y ? x : y) &&
            [c[1], d[1]].reduce((x, y) => x < y ? x : y) <=
                [a[1], b[1]].reduce((x, y) => x > y ? x : y);
        if (xOverlap &&
            yOverlap &&
            straddles(cross(a, b, c), cross(a, b, d)) &&
            straddles(cross(c, d, a), cross(c, d, b))) {
          return null;
        }
      }
    }
    if (!area.isFinite || area.abs() <= 1e-9) return null;
    return points.expand((point) => point).toList(growable: false);
  }

  // JSON's usual last-key-wins behavior is unsuitable for audit evidence.
  // Inspect root key tokens, including escaped names, before normal decoding.
  static bool _uniqueRootKeys(String text) {
    var depth = 0;
    final keys = <String>{};
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '{' || char == '[') depth++;
      if (char == '}' || char == ']') depth--;
      if (char != '"') continue;
      final start = i;
      i++;
      for (; i < text.length; i++) {
        if (text[i] == r'\') {
          i++;
          continue;
        }
        if (text[i] == '"') break;
      }
      if (i >= text.length) return false;
      var next = i + 1;
      while (next < text.length && text[next].trim().isEmpty) {
        next++;
      }
      if (depth == 1 && next < text.length && text[next] == ':') {
        final key = jsonDecode(text.substring(start, i + 1));
        if (key is! String || !keys.add(key)) return false;
      }
    }
    return true;
  }
}
