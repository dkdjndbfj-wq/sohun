import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/external/slicer/material_catalog_service.dart';
import 'consumable_provider.dart';

/// Official Bambu material families merged with materials present in stock.
final materialCatalogProvider = FutureProvider<List<String>>((ref) async {
  final inventory = ref.watch(consumablesProvider).valueOrNull ?? const [];
  final localNames = inventory.expand((item) sync* {
    final manufacturer = item.manufacturer.trim();
    final model = item.model.trim();
    final material = item.materialType.trim();
    if (model.isNotEmpty) yield model;
    if (material.isNotEmpty) yield material;
    if (manufacturer.isNotEmpty && model.isNotEmpty) {
      yield '$manufacturer $model';
    }
    if (manufacturer.isNotEmpty && material.isNotEmpty) {
      yield '$manufacturer $material';
    }
  });
  return MaterialCatalogService.load(additional: localNames);
});
