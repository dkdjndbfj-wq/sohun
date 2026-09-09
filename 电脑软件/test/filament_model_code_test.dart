import 'package:consumable_tracker_desktop/core/utils/filament_model_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('compact filament model codes', () {
    test('common Bambu variants stay within four characters', () {
      expect(FilamentModelCode.of(model: 'Bambu PLA Basic'), 'PB');
      expect(FilamentModelCode.of(model: 'Bambu PETG Basic'), 'GB');
      expect(FilamentModelCode.of(model: 'Bambu PLA Silk+'), 'PS+');
      expect(FilamentModelCode.of(model: 'Bambu TPU 95A HF'), 'T95H');
      expect(FilamentModelCode.of(model: 'Bambu PETG-CF'), 'GCF');
    });

    test('support materials get short distinct codes', () {
      expect(FilamentModelCode.of(model: 'Bambu Support For PLA'), 'SPL');
      expect(
        FilamentModelCode.of(model: 'Bambu Support For PLA/PETG'),
        'SPG',
      );
      expect(FilamentModelCode.of(model: 'Bambu Support for ABS'), 'SAB');
      expect(FilamentModelCode.of(model: 'Bambu Support For PA/PET'), 'SNP');
    });

    test('tooltip retains the complete model name', () {
      expect(
        FilamentModelCode.tooltip(
          manufacturer: '拓竹',
          model: 'PETG Basic',
          materialType: 'PETG',
        ),
        'GB = 拓竹 PETG Basic',
      );
    });

    test('RFID SKU falls back to readable material while staying traceable',
        () {
      expect(
        FilamentModelCode.of(model: 'GFA00', materialType: 'PLA'),
        'PLA',
      );
      expect(
        FilamentModelCode.tooltip(
          manufacturer: '拓竹',
          model: 'GFA00',
          materialType: 'PLA',
        ),
        'PLA = 拓竹 PLA（RFID GFA00）',
      );
    });
  });
}
