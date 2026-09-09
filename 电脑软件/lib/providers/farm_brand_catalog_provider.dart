import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/services/farm_brand_catalog_service.dart';
import 'studio_provider.dart';

final farmBrandCatalogProvider =
    FutureProvider<List<FarmBrandOption>>((ref) async {
  final inventory = await ref.watch(farmConsumablesProvider.future);
  return FarmBrandCatalogService.merge(
    inventory.map((item) => item.manufacturer),
  );
});
