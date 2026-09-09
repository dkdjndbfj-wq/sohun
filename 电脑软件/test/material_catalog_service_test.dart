import 'package:consumable_tracker_desktop/data/external/slicer/material_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('官方材料清单按材料型号去除打印机和喷嘴后缀', () {
    final result = MaterialCatalogService.extractMaterialNames({
      'filament_list': [
        {
          'name': 'Bambu PLA Silk @BBL X1C',
          'sub_path': 'filament/a.json',
        },
        {
          'name': 'Bambu PLA Silk @BBL A1 0.2 nozzle',
          'sub_path': 'filament/b.json',
        },
        {
          'name': 'Bambu PETG Basic @base',
          'sub_path': 'filament/c.json',
        },
        {
          'name': 'fdm_filament_common',
          'sub_path': 'filament/common.json',
        },
      ],
    });

    expect(result, ['Bambu PETG Basic', 'Bambu PLA Silk']);
  });

  test('内置兜底目录包含官方细分材料', () {
    expect(
      MaterialCatalogService.fallbackMaterials,
      containsAll(['Bambu PLA Silk', 'Bambu PETG Basic', 'Generic PLA Silk']),
    );
  });
}
