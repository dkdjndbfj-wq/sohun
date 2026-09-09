import '../../data/database/database.dart';
import '../../core/services/farm_brand_catalog_service.dart';

/// A farm warehouse row represents one material SKU, never one physical roll
/// or one inbound-batch row. Physical rolls are deducted from the oldest
/// available backing record when the operator loads a printer slot.
class FarmWarehouseMaterialGroup {
  FarmWarehouseMaterialGroup(List<Consumable> items)
      : items = List.unmodifiable(_sortForPicking(items));

  final List<Consumable> items;

  Consumable get representative => items.firstWhere(
        (item) => item.colorName?.trim().isNotEmpty == true,
        orElse: () => items.first,
      );

  List<Consumable> get availableItems => items
      .where((item) => item.remainingGrams >= farmWarehouseRollGrams)
      .toList(growable: false);

  int get availableRolls => items.fold<int>(
        0,
        (sum, item) =>
            sum + (item.remainingGrams / farmWarehouseRollGrams).floor(),
      );

  double get availableGrams => items.fold<double>(
        0,
        (sum, item) => sum + item.remainingGrams,
      );

  int get batchCount => items
      .map((item) => item.batchNo?.trim() ?? '')
      .where((value) => value.isNotEmpty)
      .toSet()
      .length;

  bool containsConsumable(int? id) =>
      id != null && items.any((item) => item.id == id);

  /// Picks the actual backing inventory row to deduct from. Oldest inbound
  /// stock wins so repeated UI selections remain deterministic.
  Consumable? get nextWholeRoll => availableItems.firstOrNull;

  Consumable? bestReservationCandidate(
    double Function(Consumable item) availableForItem, {
    int? selectedId,
  }) {
    final selected = items.where((item) => item.id == selectedId).firstOrNull;
    if (selected != null) return selected;
    final candidates = [...items]
      ..sort((a, b) => availableForItem(b).compareTo(availableForItem(a)));
    return candidates.firstOrNull;
  }
}

const double farmWarehouseRollGrams = 1000;

List<FarmWarehouseMaterialGroup> groupFarmWarehouseMaterials(
  Iterable<Consumable> source,
) {
  final grouped = <String, List<Consumable>>{};
  for (final item in source) {
    grouped.putIfAbsent(farmWarehouseMaterialKey(item), () => []).add(item);
  }
  final result = [
    for (final items in grouped.values) FarmWarehouseMaterialGroup(items),
  ];
  result.sort((a, b) {
    final left = a.representative;
    final right = b.representative;
    for (final comparison in [
      left.manufacturer.compareTo(right.manufacturer),
      left.materialType.compareTo(right.materialType),
      left.model.compareTo(right.model),
      left.colorHex.compareTo(right.colorHex),
    ]) {
      if (comparison != 0) return comparison;
    }
    return 0;
  });
  return result;
}

String farmWarehouseMaterialKey(Consumable item) => [
      FarmBrandCatalogService.normalize(item.manufacturer).code,
      item.model.trim().toLowerCase(),
      item.materialType.trim().toLowerCase(),
      item.colorHex.trim().toUpperCase(),
    ].join('|');

List<Consumable> _sortForPicking(List<Consumable> source) {
  final result = [...source];
  result.sort((a, b) {
    final aDate = a.purchaseDate ?? a.createdAt;
    final bDate = b.purchaseDate ?? b.createdAt;
    final date = aDate.compareTo(bDate);
    return date != 0 ? date : a.id.compareTo(b.id);
  });
  return result;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
