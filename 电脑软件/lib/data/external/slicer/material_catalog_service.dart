import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Loads the material families exposed by Bambu Studio.
///
/// Bambu's manifest contains one entry per printer/nozzle combination. This
/// service collapses those entries to the user-facing material name before
/// the `@BBL ...` suffix, then merges local inventory names and a packaged
/// fallback catalog.
class MaterialCatalogService {
  MaterialCatalogService._();

  static Future<List<String>>? _installedCatalog;

  static const fallbackMaterials = <String>[
    'Bambu ABS',
    'Bambu ABS-GF',
    'Bambu ASA',
    'Bambu ASA-Aero',
    'Bambu ASA-CF',
    'Bambu PA6-CF',
    'Bambu PA6-GF',
    'Bambu PA-CF',
    'Bambu PAHT-CF',
    'Bambu PC',
    'Bambu PC FR',
    'Bambu PET-CF',
    'Bambu PETG Basic',
    'Bambu PETG HF',
    'Bambu PETG Matte',
    'Bambu PETG Translucent',
    'Bambu PETG-CF',
    'Bambu PLA Aero',
    'Bambu PLA Basic',
    'Bambu PLA Dynamic',
    'Bambu PLA Galaxy',
    'Bambu PLA Gradient',
    'Bambu PLA Glow',
    'Bambu PLA Lite',
    'Bambu PLA Marble',
    'Bambu PLA Matte',
    'Bambu PLA Metal',
    'Bambu PLA Pure',
    'Bambu PLA Silk',
    'Bambu PLA Silk+',
    'Bambu PLA Silk Multi-Color',
    'Bambu PLA Sparkle',
    'Bambu PLA Tough',
    'Bambu PLA Tough+',
    'Bambu PLA Translucent',
    'Bambu PLA Wood',
    'Bambu PLA-CF',
    'Bambu PPA-CF',
    'Bambu PPS-CF',
    'Bambu PVA',
    'Bambu Support for ABS',
    'Bambu Support For PA/PET',
    'Bambu Support For PLA',
    'Bambu Support For PLA/PETG',
    'Bambu Support G',
    'Bambu Support W',
    'Bambu TPU 85A',
    'Bambu TPU 90A',
    'Bambu TPU 95A',
    'Bambu TPU 95A HF',
    'Bambu TPU for AMS',
    'eSUN PLA+',
    'Fiberon PA12-CF',
    'Fiberon PA612-CF',
    'Fiberon PA6-CF',
    'Fiberon PA6-GF',
    'Fiberon PET-CF',
    'Fiberon PETG-ESD',
    'Fiberon PETG-rCF',
    'Generic ABS',
    'Generic ASA',
    'Generic BVOH',
    'Generic EVA',
    'Generic HIPS',
    'Generic PA',
    'Generic PA-CF',
    'Generic PC',
    'Generic PCTG',
    'Generic PE',
    'Generic PE-CF',
    'Generic PETG',
    'Generic PETG HF',
    'Generic PETG-CF',
    'Generic PHA',
    'Generic PLA',
    'Generic PLA High Speed',
    'Generic PLA Silk',
    'Generic PLA-CF',
    'Generic PP',
    'Generic PPA-CF',
    'Generic PPA-GF',
    'Generic PP-CF',
    'Generic PP-GF',
    'Generic PPS',
    'Generic PPS-CF',
    'Generic PVA',
    'Generic TPU',
    'Generic TPU for AMS',
    'Overture Matte PLA',
    'Overture PLA',
    'PolyLite ABS',
    'PolyLite ASA',
    'PolyLite PETG',
    'PolyLite PLA',
    'PolyTerra PLA',
    'SUNLU PETG',
    'SUNLU PLA Marble',
    'SUNLU PLA Matte',
    'SUNLU PLA+',
    'SUNLU PLA+ 2.0',
    'SUNLU Silk PLA+',
    'SUNLU Wood PLA',
  ];

  static Future<List<String>> load({
    Iterable<String> additional = const [],
  }) async {
    final installed = await (_installedCatalog ??= _loadInstalledCatalog());
    final values = <String>{...fallbackMaterials, ...installed};
    for (final value in additional) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) values.add(trimmed);
    }
    final result = values.toList();
    result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  static Future<List<String>> _loadInstalledCatalog() async {
    final candidates = <String>{};
    final appData = Platform.environment['APPDATA'];
    final programFiles = Platform.environment['ProgramFiles'];
    final programW6432 = Platform.environment['ProgramW6432'];
    if (appData != null) {
      candidates.add(
        p.join(appData, 'BambuStudio', 'ota', 'presets', 'BBL.json'),
      );
    }
    for (final root in {programFiles, programW6432}.whereType<String>()) {
      candidates.add(
        p.join(root, 'Bambu Studio', 'resources', 'profiles', 'BBL.json'),
      );
    }

    final values = <String>{};
    for (final path in candidates) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final decoded = jsonDecode(await file.readAsString());
        values.addAll(extractMaterialNames(decoded));
      } catch (_) {
        // A stale or partially-written OTA manifest must not break the picker.
      }
    }
    return values.toList();
  }

  static List<String> extractMaterialNames(dynamic manifest) {
    if (manifest is! Map) return const [];
    final rawList = manifest['filament_list'];
    if (rawList is! List) return const [];
    final values = <String>{};
    for (final entry in rawList) {
      if (entry is! Map) continue;
      final rawName = entry['name']?.toString().trim() ?? '';
      if (rawName.isEmpty || rawName.startsWith('fdm_')) continue;
      final suffixIndex = rawName.indexOf(' @');
      final name =
          suffixIndex > 0 ? rawName.substring(0, suffixIndex).trim() : rawName;
      if (name.isNotEmpty) values.add(name);
    }
    final result = values.toList();
    result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }
}
