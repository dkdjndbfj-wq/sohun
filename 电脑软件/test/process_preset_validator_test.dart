import 'dart:convert';

import 'package:consumable_tracker_desktop/data/external/slicer/bambu_studio_param_exporter.dart';
import 'package:consumable_tracker_desktop/data/models/print_parameter.dart';
import 'package:consumable_tracker_desktop/features/parameters/process_preset_validator.dart';
import 'package:flutter_test/flutter_test.dart';

PrintParameterPreset _preset({String layerHeight = '0.2'}) {
  final now = DateTime.utc(2026, 8, 1);
  return PrintParameterPreset(
    id: 'range-test',
    name: 'Range test',
    createdAt: now,
    updatedAt: now,
    quality: PrintQualityParams(layerHeight: layerHeight),
    strength: const PrintStrengthParams(),
    speed: const PrintSpeedParams(),
    support: const PrintSupportParams(),
    other: const PrintOtherParams(),
  );
}

void main() {
  test('accepts a normal process preset through import and export boundaries',
      () {
    final preset = _preset();

    expect(ProcessPresetValidator.validate(preset), isEmpty);
    expect(
      BambuStudioParamExporter.importFromBbsparam(
        BambuStudioParamExporter.exportToBbsparam(preset),
      ).quality.layerHeight,
      '0.2',
    );
    expect(
      BambuStudioParamExporter.exportToBambuStudioJson(preset),
      contains('layer_height'),
    );
  });

  test('rejects an out-of-range community value before slicer application', () {
    final payload = _preset().toBbsparamMap();
    final preset = payload['preset'] as Map<String, dynamic>;
    final params = preset['params'] as Map<String, dynamic>;
    final quality = params['quality'] as Map<String, dynamic>;
    quality['layer_height'] = '100';

    expect(
      () => BambuStudioParamExporter.importFromBbsparam(jsonEncode(payload)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('layer_height'),
        ),
      ),
    );
    expect(
      () => BambuStudioParamExporter.exportToBambuStudioJson(
        _preset(layerHeight: '100'),
      ),
      throwsFormatException,
    );
  });
}
