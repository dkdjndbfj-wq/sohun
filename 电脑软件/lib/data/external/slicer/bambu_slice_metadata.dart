import 'dart:convert';

import 'package:xml/xml.dart';

/// Bambu's slice-info filament ids are 1-based, while G-code tools and
/// `layer_filament_list` entries are 0-based.
int bambuToolIndex(XmlElement filament) {
  final raw = int.tryParse(filament.getAttribute('id') ?? '') ?? 0;
  return raw > 0 ? raw - 1 : 0;
}

bool? bambuBoolAttribute(XmlElement element, String name) {
  final value = element.getAttribute(name)?.trim().toLowerCase();
  if (value == 'true' || value == '1') return true;
  if (value == 'false' || value == '0') return false;
  return null;
}

int totalLayersFromBambuFilamentRanges(XmlElement plate) {
  var highestLayer = -1;
  for (final item in plate.findAllElements('layer_filament_list')) {
    final ranges = item.getAttribute('layer_ranges') ?? '';
    for (final match in RegExp(r'\d+').allMatches(ranges)) {
      final layer = int.tryParse(match.group(0) ?? '');
      if (layer != null && layer > highestLayer) highestLayer = layer;
    }
  }
  return highestLayer < 0 ? 0 : highestLayer + 1;
}

/// Reconstructs the material sequence for every layer from Bambu Studio 2.7's
/// compact inclusive ranges. A list such as `0 1` means both tools are used on
/// each covered layer, in the stored order.
int toolChangesFromBambuFilamentRanges(
  XmlElement plate, {
  Set<int>? activeTools,
}) {
  final toolsByLayer = <int, List<int>>{};
  const maxSupportedLayer = 100000;

  for (final item in plate.findAllElements('layer_filament_list')) {
    final tools = RegExp(r'\d+')
        .allMatches(item.getAttribute('filament_list') ?? '')
        .map((match) => int.tryParse(match.group(0) ?? ''))
        .whereType<int>()
        .where((tool) => activeTools == null || activeTools.contains(tool))
        .toList(growable: false);
    if (tools.isEmpty) continue;

    final bounds = RegExp(r'\d+')
        .allMatches(item.getAttribute('layer_ranges') ?? '')
        .map((match) => int.tryParse(match.group(0) ?? ''))
        .whereType<int>()
        .toList(growable: false);
    for (var index = 0; index < bounds.length; index += 2) {
      final start = bounds[index];
      final end = index + 1 < bounds.length ? bounds[index + 1] : start;
      if (start < 0 || end < start || end > maxSupportedLayer) continue;
      for (var layer = start; layer <= end; layer++) {
        final existing = toolsByLayer.putIfAbsent(layer, () => <int>[]);
        for (final tool in tools) {
          if (!existing.contains(tool)) existing.add(tool);
        }
      }
    }
  }

  int? currentTool;
  var changes = 0;
  final layers = toolsByLayer.keys.toList()..sort();
  for (final layer in layers) {
    for (final tool in toolsByLayer[layer]!) {
      if (currentTool != null && currentTool != tool) changes++;
      currentTool = tool;
    }
  }
  return changes;
}

/// Reads only explicit tool-selection commands from an embedded G-code. This
/// is intended as a conditional multicolor fallback, not a general G-code
/// parser. The first selected tool is the initial load and is not a change.
int toolChangesFromBambuGcode(
  List<int> bytes, {
  Set<int>? activeTools,
}) {
  final text = utf8.decode(bytes, allowMalformed: true);
  final marker = text.indexOf('EXECUTABLE_BLOCK_START');
  final body = marker >= 0 ? text.substring(marker) : text;
  final command = RegExp(
    r'^\s*(?:M620\s+S(\d+)A?|T(\d+)(?:\s|;|$))',
    multiLine: true,
    caseSensitive: false,
  );
  int? currentTool;
  var changes = 0;
  for (final match in command.allMatches(body)) {
    final tool = int.tryParse(match.group(1) ?? match.group(2) ?? '');
    if (tool == null || tool >= 254 || tool == 1000) continue;
    if (activeTools != null && !activeTools.contains(tool)) continue;
    if (currentTool != null && currentTool != tool) changes++;
    currentTool = tool;
  }
  return changes;
}
