import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/data/database/daos/filament_cost_config_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/studio_quote_config_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/filament_cost_config.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_quote_config_models.dart';
import 'package:consumable_tracker_desktop/features/studio/studio_quote_config_panel.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';

void main() {
  testWidgets('报价页按统一参数、机器损耗、耗材成本顺序紧凑展示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final studioDao = StudioDao(db);
    final quoteDao = StudioQuoteConfigDao(db);
    final filamentDao = FilamentCostConfigDao(db);
    final workspaceId = (await studioDao.getDefaultSnapshot()).workspace.id;
    final now = DateTime.now();

    await quoteDao.saveSettings(
      StudioQuoteSettings(
        id: 0,
        workspaceId: workspaceId,
        laborRatePerHour: 40,
        electricityRatePerHour: 2,
        riskReservePercent: 10,
        markupPercent: 25,
        packagingCost: 5,
        minimumOrderPrice: 15,
        updatedAt: now,
      ),
    );
    await quoteDao.saveMachine(
      StudioMachineCostConfig(
        id: 0,
        workspaceId: workspaceId,
        brand: '拓竹',
        model: 'A1',
        wearCostPerHour: 4,
        active: true,
        updatedAt: now,
      ),
    );
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: StudioQuoteConfigPanel(
                workspaceId: workspaceId,
                canManage: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quote-unified-settings')), findsOneWidget);
    expect(find.byKey(const Key('quote-machine-costs')), findsOneWidget);
    expect(find.byKey(const Key('quote-material-costs')), findsOneWidget);
    expect(find.text('40 元/小时'), findsOneWidget);
    expect(find.text('拓竹 / A1'), findsOneWidget);
    expect(find.text('拓竹 / PETG Basic'), findsOneWidget);
    expect(find.text('80 元/kg'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    studioDao.dispose();
    quoteDao.dispose();
    filamentDao.dispose();
    await db.close();
    await tester.binding.setSurfaceSize(null);
  });
}
