/// Merges incremental feed reports by physical ID before interpreting bitmasks.
/// A temperature-only AMS update must not erase its trays or nozzle route.
class BambuFeedTelemetryCache {
  Map<String, dynamic>? _ams;
  Map<String, dynamic>? _extruder;

  void clear() {
    _ams = null;
    _extruder = null;
  }

  Map<String, dynamic> merge(Map<String, dynamic> message) {
    final result = Map<String, dynamic>.from(message);
    final rawPrint = message['print'];
    final print = rawPrint is Map
        ? Map<String, dynamic>.from(rawPrint)
        : <String, dynamic>{};
    final ams = print['ams'] ?? message['ams'];
    if (ams is Map) {
      _ams = _merge(_ams ?? {}, Map<String, dynamic>.from(ams));
      print['ams'] = _ams;
    }
    final extruder = print['extruder'];
    if (extruder is Map) {
      _extruder = _merge(_extruder ?? {}, Map<String, dynamic>.from(extruder));
      print['extruder'] = _extruder;
    }
    if (print.isNotEmpty) result['print'] = print;
    return result;
  }

  static Map<String, dynamic> _merge(
    Map<String, dynamic> previous,
    Map<String, dynamic> update,
  ) {
    final result = {...previous};
    for (final entry in update.entries) {
      final key = entry.key;
      final value = entry.value;
      if ((key == 'ams' || key == 'tray' || key == 'info') &&
          (value is List || value is Map)) {
        final incoming = _byId(value);
        // An explicitly empty list clears it; omission preserves it.
        final merged = incoming.isEmpty
            ? <String, Map<String, dynamic>>{}
            : _byId(result[key]);
        for (final item in incoming.entries) {
          merged[item.key] = _merge(merged[item.key] ?? {}, item.value);
        }
        result[key] = merged.values.toList(growable: false);
      } else if (value is Map && result[key] is Map) {
        result[key] = _merge(Map<String, dynamic>.from(result[key] as Map),
            Map<String, dynamic>.from(value));
      } else {
        result[key] = value;
      }
    }
    return result;
  }

  static Map<String, Map<String, dynamic>> _byId(dynamic value) {
    final entries = value is List
        ? value.asMap().entries
        : value is Map
            ? value.entries
            : const <MapEntry<dynamic, dynamic>>[];
    return {
      for (final entry in entries)
        if (entry.value is Map)
          (entry.value['id'] ?? entry.key).toString(): {
            'id': entry.key.toString(),
            ...Map<String, dynamic>.from(entry.value as Map),
          },
    };
  }
}
