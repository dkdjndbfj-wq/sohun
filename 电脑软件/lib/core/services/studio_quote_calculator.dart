import '../../data/database/daos/filament_cost_config_dao.dart';
import '../../data/database/models/studio_models.dart';
import '../../data/database/models/studio_quote_config_models.dart';

class StudioQuoteCalculation {
  const StudioQuoteCalculation({
    required this.materialCost,
    required this.machineWearCost,
    required this.laborCost,
    required this.electricityCost,
    required this.packagingCost,
    required this.riskReserve,
    required this.totalCost,
    required this.quotedPrice,
    required this.missingMaterials,
    required this.missingMachines,
  });

  final double materialCost;
  final double machineWearCost;
  final double laborCost;
  final double electricityCost;
  final double packagingCost;
  final double riskReserve;
  final double totalCost;
  final double quotedPrice;
  final List<String> missingMaterials;
  final List<String> missingMachines;

  bool get needsReview =>
      missingMaterials.isNotEmpty || missingMachines.isNotEmpty;
}

/// One calculation path used by the quote page and new production orders.
class StudioQuoteCalculator {
  const StudioQuoteCalculator(this.filamentDao);

  final FilamentCostConfigDao filamentDao;

  Future<StudioQuoteCalculation> calculate({
    required StudioQuoteSettings settings,
    required List<StudioMachineCostConfig> machines,
    required Iterable<StudioPlateFilamentUsage> filaments,
    required double machineHours,
    double laborHours = 0,
    String? machineBrand,
    String? machineModel,
    int runs = 1,
  }) async {
    final missingMaterials = <String>[];
    var materialCost = 0.0;
    for (final filament in StudioPlateFilamentUsage.activeByTool(filaments)) {
      final config = await filamentDao.matchCost(
        vendor: filament.vendor?.trim() ?? '',
        materialType: filament.materialType?.trim() ?? '',
        colorHex: filament.colorHex?.trim() ?? '',
      );
      final grams = filament.grams * (runs < 1 ? 1 : runs);
      if (config == null) {
        missingMaterials.add([
          if (filament.vendor?.trim().isNotEmpty == true)
            filament.vendor!.trim(),
          filament.materialType?.trim().isNotEmpty == true
              ? filament.materialType!.trim()
              : '未知材质',
          if (filament.colorHex?.trim().isNotEmpty == true)
            filament.colorHex!.trim(),
        ].join(' / '));
      } else {
        materialCost += config.costForGrams(grams);
      }
    }
    final machine = _matchMachine(machines, machineBrand, machineModel);
    final missingMachines = <String>[];
    if (machine == null && machineHours > 0) {
      missingMachines.add(
        [machineBrand, machineModel]
            .where((item) => item?.trim().isNotEmpty == true)
            .join(' '),
      );
    }
    final wear = machineHours * (machine?.wearCostPerHour ?? 0);
    final labor = laborHours * settings.laborRatePerHour;
    final electricity = machineHours * settings.electricityRatePerHour;
    final base =
        materialCost + wear + labor + electricity + settings.packagingCost;
    final risk = base * settings.riskReservePercent / 100;
    final total = base + risk;
    final price = (total * (1 + settings.markupPercent / 100))
        .clamp(settings.minimumOrderPrice, double.infinity)
        .toDouble();
    return StudioQuoteCalculation(
      materialCost: materialCost,
      machineWearCost: wear,
      laborCost: labor,
      electricityCost: electricity,
      packagingCost: settings.packagingCost,
      riskReserve: risk,
      totalCost: total,
      quotedPrice: price,
      missingMaterials: missingMaterials,
      missingMachines: missingMachines,
    );
  }

  Future<StudioQuoteCalculation> calculateProductionOrder({
    required StudioQuoteSettings settings,
    required List<StudioMachineCostConfig> machines,
    required List<StudioProductionPackageDraft> packages,
    double laborHours = 0,
  }) async {
    var materialCost = 0.0;
    var machineWear = 0.0;
    var totalMachineHours = 0.0;
    final missingMaterials = <String>{};
    final missingMachines = <String>{};

    for (final package in packages) {
      for (final plate in package.plates) {
        final runs = plate.requiredRuns < 1 ? 1 : plate.requiredRuns;
        final hours = plate.estimatedSeconds * runs / 3600;
        totalMachineHours += hours;
        final targetModel = plate.sliceTargetModel ?? package.targetModel;
        final machine = _matchMachine(machines, null, targetModel);
        if (machine == null && hours > 0) {
          missingMachines.add(
            targetModel?.trim().isNotEmpty == true
                ? targetModel!.trim()
                : '未识别机型',
          );
        } else {
          machineWear += hours * (machine?.wearCostPerHour ?? 0);
        }

        final active = plate.activeFilaments;
        if (active.isEmpty && plate.estimatedGrams > 0) {
          missingMaterials.add('未识别耗材（${plate.name}）');
        }
        for (final filament in active) {
          final config = await filamentDao.matchCost(
            vendor: filament.vendor?.trim() ?? '',
            materialType: filament.materialType?.trim() ?? '',
            colorHex: filament.colorHex?.trim() ?? '',
          );
          if (config == null) {
            missingMaterials.add([
              if (filament.vendor?.trim().isNotEmpty == true)
                filament.vendor!.trim(),
              filament.materialType?.trim().isNotEmpty == true
                  ? filament.materialType!.trim()
                  : '未知材质',
              if (filament.colorHex?.trim().isNotEmpty == true)
                filament.colorHex!.trim(),
            ].join(' / '));
          } else {
            materialCost += config.costForGrams(filament.grams * runs);
          }
        }
      }
    }

    final laborCost = laborHours * settings.laborRatePerHour;
    final electricityCost = totalMachineHours * settings.electricityRatePerHour;
    final base = materialCost +
        machineWear +
        laborCost +
        electricityCost +
        settings.packagingCost;
    final risk = base * settings.riskReservePercent / 100;
    final total = base + risk;
    final calculated = total * (1 + settings.markupPercent / 100);
    return StudioQuoteCalculation(
      materialCost: materialCost,
      machineWearCost: machineWear,
      laborCost: laborCost,
      electricityCost: electricityCost,
      packagingCost: settings.packagingCost,
      riskReserve: risk,
      totalCost: total,
      quotedPrice: calculated < settings.minimumOrderPrice
          ? settings.minimumOrderPrice
          : calculated,
      missingMaterials: missingMaterials.toList(growable: false),
      missingMachines: missingMachines.toList(growable: false),
    );
  }

  StudioMachineCostConfig? _matchMachine(
    List<StudioMachineCostConfig> machines,
    String? brand,
    String? model,
  ) {
    final b = brand?.trim() ?? '';
    final m = model?.trim() ?? '';
    final target = '$b $m'.trim().toLowerCase();
    StudioMachineCostConfig? first(
        bool Function(StudioMachineCostConfig) test) {
      for (final item in machines) {
        if (item.active && test(item)) return item;
      }
      return null;
    }

    return first((item) => item.brand == b && item.model == m) ??
        first((item) {
          final itemModel = item.model.trim().toLowerCase();
          final itemBrand = item.brand.trim().toLowerCase();
          if (itemModel.isEmpty ||
              target.isEmpty ||
              !target.contains(itemModel)) {
            return false;
          }
          return itemBrand.isEmpty ||
              target.contains(itemBrand) ||
              (_isBambuBrand(itemBrand) && _isBambuBrand(target));
        }) ??
        first((item) => item.brand == b && item.model.isEmpty) ??
        first((item) => item.brand.isEmpty && item.model.isEmpty);
  }

  bool _isBambuBrand(String value) {
    final normalized = value.toLowerCase().replaceAll(' ', '');
    return normalized.contains('bambu') || normalized.contains('拓竹');
  }
}
