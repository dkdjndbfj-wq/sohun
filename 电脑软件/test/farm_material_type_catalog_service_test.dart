import 'package:consumable_tracker_desktop/core/services/farm_material_type_catalog_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('农场耗材类型目录只采用拓竹官方类型且移除所有品牌前缀', () {
    final values = FarmMaterialTypeCatalogService.compose(
      officialCatalog: const [
        'Bambu PLA Basic',
        'Bambu Lab PETG Basic',
        'Generic PLA',
        'eSUN PLA+',
      ],
      additionalTypes: const [
        'SUNLU PLA Matte',
        '拓竹 PLA Basic',
        'PETG-CF',
      ],
    );

    expect(values,
        containsAll(['PLA Basic', 'PETG Basic', 'PLA Matte', 'PETG-CF']));
    expect(values.where((value) => value.contains('Bambu')), isEmpty);
    expect(values.where((value) => value.contains('Generic')), isEmpty);
    expect(values.where((value) => value.contains('eSUN')), isEmpty);
    expect(values.where((value) => value.contains('SUNLU')), isEmpty);
    expect(values.where((value) => value.contains('拓竹')), isEmpty);
    expect(values.where((value) => value == 'PLA Basic'), hasLength(1));
  });
}
