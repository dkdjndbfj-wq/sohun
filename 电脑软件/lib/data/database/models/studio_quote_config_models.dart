/// Workspace-level pricing inputs used by the production quote calculator.
class StudioQuoteSettings {
  const StudioQuoteSettings({
    required this.id,
    required this.workspaceId,
    required this.laborRatePerHour,
    required this.electricityRatePerHour,
    required this.riskReservePercent,
    required this.markupPercent,
    required this.packagingCost,
    required this.minimumOrderPrice,
    required this.updatedAt,
  });

  final int id;
  final String workspaceId;
  final double laborRatePerHour;
  final double electricityRatePerHour;
  final double riskReservePercent;
  final double markupPercent;
  final double packagingCost;
  final double minimumOrderPrice;
  final DateTime updatedAt;

  static StudioQuoteSettings defaults(String workspaceId) =>
      StudioQuoteSettings(
        id: 0,
        workspaceId: workspaceId,
        laborRatePerHour: 30,
        electricityRatePerHour: 1,
        riskReservePercent: 8,
        markupPercent: 30,
        packagingCost: 2,
        minimumOrderPrice: 0,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
}

class StudioMachineCostConfig {
  const StudioMachineCostConfig({
    required this.id,
    required this.workspaceId,
    required this.brand,
    required this.model,
    required this.wearCostPerHour,
    required this.active,
    required this.updatedAt,
    this.note,
  });

  final int id;
  final String workspaceId;
  final String brand;
  final String model;
  final double wearCostPerHour;
  final bool active;
  final String? note;
  final DateTime updatedAt;

  bool get isDefault => brand.trim().isEmpty && model.trim().isEmpty;
}
