import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/farm_material_type_catalog_service.dart';
import 'studio_provider.dart';

/// 农场批量库存专用目录，不读取普通用户的材料库。
final farmMaterialTypeCatalogProvider = FutureProvider<List<String>>((ref) {
  final inventory = ref.watch(farmConsumablesProvider).valueOrNull ?? const [];
  final localTypes = inventory.map((item) {
    final source = item.model.trim().isEmpty
        ? item.materialType.trim()
        : item.model.trim();
    return FarmMaterialTypeCatalogService.stripBrandPrefix(
      source,
      manufacturer: item.manufacturer,
    );
  });
  return FarmMaterialTypeCatalogService.load(additionalTypes: localTypes);
});
