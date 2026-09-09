import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:consumable_tracker_desktop/core/services/studio_quote_calculator.dart';
import 'package:consumable_tracker_desktop/data/database/daos/filament_cost_config_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_quote_config_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/filament_cost_config.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_quote_config_models.dart';

void main() {
  late AppDatabase db;
  late StudioDao studioDao;
  late StudioQuoteConfigDao quoteConfigDao;
  late FilamentCostConfigDao filamentDao;
  late String workspaceId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    studioDao = StudioDao(db);
    quoteConfigDao = StudioQuoteConfigDao(db);
    filamentDao = FilamentCostConfigDao(db);
    workspaceId = (await studioDao.getDefaultSnapshot()).workspace.id;
  });

  tearDown(() async {
    studioDao.dispose();
    quoteConfigDao.dispose();
    filamentDao.dispose();
    await db.close();
  });

  test('统一参数和机器型号损耗可保存并按优先级匹配', () async {
    await quoteConfigDao.saveSettings(
      StudioQuoteSettings(
        id: 0,
        workspaceId: workspaceId,
        laborRatePerHour: 40,
        electricityRatePerHour: 2,
        riskReservePercent: 10,
        markupPercent: 20,
        packagingCost: 5,
        minimumOrderPrice: 12,
        updatedAt: DateTime.now(),
      ),
    );
    await quoteConfigDao.saveMachine(
      StudioMachineCostConfig(
        id: 0,
        workspaceId: workspaceId,
        brand: '拓竹',
        model: 'A1',
        wearCostPerHour: 4,
        active: true,
        updatedAt: DateTime.now(),
      ),
    );
    await quoteConfigDao.saveMachine(
      StudioMachineCostConfig(
        id: 0,
        workspaceId: workspaceId,
        brand: '',
        model: '',
        wearCostPerHour: 1,
        active: true,
        updatedAt: DateTime.now(),
      ),
    );

    final settings = await quoteConfigDao.getSettings(workspaceId);
    final exact = await quoteConfigDao.matchMachine(
      workspaceId: workspaceId,
      brand: '拓竹',
      model: 'A1',
    );
    final fallback = await quoteConfigDao.matchMachine(
      workspaceId: workspaceId,
      brand: '其他',
      model: '未知',
    );

    expect(settings.laborRatePerHour, 40);
    expect(settings.minimumOrderPrice, 12);
    expect(exact?.wearCostPerHour, 4);
    expect(fallback?.wearCostPerHour, 1);
  });

  test('生产订单按耗材、机损、人工、电费、风险和利润自动报价', () async {
    final now = DateTime.now();
    await filamentDao.create(
      FilamentCostConfig(
        vendor: '拓竹',
        materialType: 'PETG Basic',
        colorHex: '',
        costPerKg: 80,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final settings = StudioQuoteSettings(
      id: 0,
      workspaceId: workspaceId,
      laborRatePerHour: 40,
      electricityRatePerHour: 2,
      riskReservePercent: 10,
      markupPercent: 20,
      packagingCost: 5,
      minimumOrderPrice: 0,
      updatedAt: now,
    );
    final machines = [
      StudioMachineCostConfig(
        id: 1,
        workspaceId: workspaceId,
        brand: '拓竹',
        model: 'A1',
        wearCostPerHour: 4,
        active: true,
        updatedAt: now,
      ),
    ];
    final packages = [_package(runs: 2)];

    final result =
        await StudioQuoteCalculator(filamentDao).calculateProductionOrder(
      settings: settings,
      machines: machines,
      packages: packages,
      laborHours: 0.5,
    );

    expect(result.materialCost, closeTo(16, 0.001));
    expect(result.machineWearCost, closeTo(8, 0.001));
    expect(result.laborCost, closeTo(20, 0.001));
    expect(result.electricityCost, closeTo(4, 0.001));
    expect(result.totalCost, closeTo(58.3, 0.001));
    expect(result.quotedPrice, closeTo(69.96, 0.001));
    expect(result.needsReview, isFalse);
  });

  test('缺少机器或耗材配置时标记待核对且不静默视为已匹配', () async {
    final result =
        await StudioQuoteCalculator(filamentDao).calculateProductionOrder(
      settings: StudioQuoteSettings.defaults(workspaceId),
      machines: const [],
      packages: [_package()],
    );

    expect(result.needsReview, isTrue);
    expect(result.missingMachines, isNotEmpty);
    expect(result.missingMaterials, isNotEmpty);
  });

  test('生产订单和自动报价在同一事务中保存并建立关联', () async {
    final now = DateTime.now();
    final quote = StudioQuote(
      id: const Uuid().v4(),
      workspaceId: workspaceId,
      quoteNo: 'QT-TEST-001',
      title: '联动测试',
      status: StudioQuoteStatus.draft,
      materialLabel: '拓竹 / PETG Basic',
      estimatedGrams: 100,
      materialCostPerKgSnapshot: 80,
      machineHours: 1,
      machineRatePerHour: 4,
      laborHours: 0.5,
      laborRatePerHour: 40,
      electricityCost: 2,
      packagingCost: 5,
      riskPercent: 10,
      markupPercent: 20,
      totalCost: 42.9,
      quotedPrice: 51.48,
      createdAt: now,
      updatedAt: now,
    );

    final orderId = await studioDao.addProductionOrder(
      workspaceId: workspaceId,
      orderNo: 'SO-TEST-001',
      title: '联动测试',
      packages: [_package()],
      totalPrice: quote.quotedPrice,
      quote: quote,
    );
    final snapshot = await studioDao.getDefaultSnapshot();

    expect(snapshot.orders.single.totalPrice, quote.quotedPrice);
    expect(snapshot.quotes.single.orderId, orderId);
    expect(snapshot.quotes.single.materialCostPerKgSnapshot, 80);
  });
}

StudioProductionPackageDraft _package({int runs = 1}) =>
    StudioProductionPackageDraft(
      sourceName: 'quote-test.3mf',
      artifactKind: 'bambu3mf',
      targetModel: 'Bambu Lab A1',
      plates: [
        StudioProductionPlateDraft(
          plateIndex: 1,
          name: '第一盘',
          requiredRuns: runs,
          estimatedSeconds: 3600,
          estimatedGrams: 100,
          sliceStatus: StudioPlateSliceStatus.sliced,
          filaments: const [
            StudioPlateFilamentUsage(
              toolIndex: 0,
              grams: 100,
              vendor: 'Bambu Lab',
              materialType: 'PETG Basic',
              colorHex: '#000000',
            ),
          ],
          items: const [
            StudioOrderItemDraft(
              sourceKey: 'part-1',
              name: '测试件',
              perRunQuantity: 1,
              requiredQuantity: 1,
            ),
          ],
        ),
      ],
    );
