import 'dart:io';

import 'package:consumable_tracker_desktop/data/external/slicer/bambu_studio_param_exporter.dart';
import 'package:consumable_tracker_desktop/data/models/print_parameter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects an oversized .bbsparam file before reading it', () async {
    final directory = await Directory.systemTemp.createTemp(
      'bbsparam_import_limit_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file =
        File('${directory.path}${Platform.pathSeparator}large.bbsparam');
    final handle = await file.open(mode: FileMode.write);
    await handle.truncate(BambuStudioParamExporter.maxImportBytes + 1);
    await handle.close();

    await expectLater(
      BambuStudioParamExporter.importFromBbsparamFile(file),
      throwsFormatException,
    );
  });

  test('imports a valid .bbsparam file within the limit', () async {
    final directory = await Directory.systemTemp.createTemp(
      'bbsparam_import_valid_',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file =
        File('${directory.path}${Platform.pathSeparator}valid.bbsparam');
    final now = DateTime.utc(2026, 8, 1);
    final preset = PrintParameterPreset(
      id: 'valid-preset',
      name: 'Valid preset',
      createdAt: now,
      updatedAt: now,
      quality: const PrintQualityParams(),
      strength: const PrintStrengthParams(),
      speed: const PrintSpeedParams(),
      support: const PrintSupportParams(),
      other: const PrintOtherParams(),
    );
    await file.writeAsString(preset.toBbsparamJson());

    final imported =
        await BambuStudioParamExporter.importFromBbsparamFile(file);
    expect(imported.id, preset.id);
    expect(imported.name, preset.name);
  });
}
