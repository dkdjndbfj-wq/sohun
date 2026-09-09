import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/database/daos/filament_cost_config_dao.dart';
import 'package:consumable_tracker_desktop/features/filament_cost/filament_cost_screen.dart';
import 'package:consumable_tracker_desktop/providers/filament_cost_provider.dart';

void main() {
  testWidgets('耗材成本页提供实时试算、保存反馈与趋势悬停检查', (tester) async {
    SharedPreferences.setMockInitialValues({
      'cost_elec_price': 0.6,
      'cost_printer_power': 150.0,
      'cost_idle_power': 30.0,
      'cost_wear_rate': 0.5,
      'cost_labor_rate': 0.0,
      'cost_quote_filament_price_per_kg': 120.0,
    });
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime(2026, 7, 31);
    final config = FilamentCostConfig(
      id: 1,
      vendor: 'eSUN',
      materialType: 'PLA',
      colorHex: '',
      costPerKg: 100,
      createdAt: now,
      updatedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          filamentCostConfigsProvider.overrideWith(
            (ref) => Stream.value([config]),
          ),
          consumptionSummaryProvider.overrideWith(
            (ref, range) => Stream.value(
              ConsumptionSummary(
                totalGrams: range == ConsumptionRange.month ? 2400 : 320,
                totalCost: range == ConsumptionRange.month ? 240 : 32,
                rows: const [],
              ),
            ),
          ),
          consumptionTimelineProvider.overrideWith(
            (ref, range) => Stream.value([
              ConsumptionPoint(time: DateTime(2026, 7, 1), grams: 100),
              ConsumptionPoint(time: DateTime(2026, 7, 15), grams: 200),
              ConsumptionPoint(time: DateTime(2026, 7, 31), grams: 300),
            ]),
          ),
        ],
        child: const MaterialApp(
          home: InteractionEffectsScope(
            enabled: false,
            child: FilamentCostScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('cost-scenario-lab')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quote-filament-price-input')),
      findsOneWidget,
    );
    expect(find.text('报价成本 ¥120/kg'), findsOneWidget);
    expect(find.byKey(const ValueKey('cost-grams-slider')), findsOneWidget);
    expect(find.byKey(const ValueKey('cost-hours-slider')), findsOneWidget);
    expect(find.text('¥33.54'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cost-preset-0')));
    await tester.pump();
    expect(find.text('¥10.78'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cost-stat-month-value')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cost-range-month')), findsOneWidget);

    final chart = find.byKey(const ValueKey('cost-consumption-chart'));
    expect(chart, findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(chart));
    await tester.pump();
    expect(find.byKey(const ValueKey('cost-chart-tooltip')), findsOneWidget);
    expect(find.text('7/15  200g'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '0.8');
    await tester.pump();
    expect(find.text('保存中'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('即时报价不会自动把库存耗材均价当作报价成本', (tester) async {
    SharedPreferences.setMockInitialValues({
      'cost_elec_price': 0.6,
      'cost_printer_power': 150.0,
      'cost_idle_power': 30.0,
      'cost_wear_rate': 0.5,
      'cost_labor_rate': 0.0,
    });
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime(2026, 8, 3);
    final inventoryCost = FilamentCostConfig(
      id: 1,
      vendor: 'eSUN',
      materialType: 'PLA',
      colorHex: '',
      costPerKg: 100,
      createdAt: now,
      updatedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          filamentCostConfigsProvider.overrideWith(
            (ref) => Stream.value([inventoryCost]),
          ),
          consumptionSummaryProvider.overrideWith(
            (ref, range) => Stream.value(
              const ConsumptionSummary(
                totalGrams: 0,
                totalCost: 0,
                rows: [],
              ),
            ),
          ),
          consumptionTimelineProvider.overrideWith(
            (ref, range) => Stream.value(const []),
          ),
        ],
        child: const MaterialApp(
          home: InteractionEffectsScope(
            enabled: false,
            child: FilamentCostScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未设置报价耗材成本'), findsOneWidget);
    expect(find.text('¥3.54'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('quote-use-average-price')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('quote-use-average-price')));
    await tester.pump();
    expect(find.text('报价成本 ¥100/kg'), findsOneWidget);
    expect(find.text('¥28.54'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble('cost_quote_filament_price_per_kg'), 100.0);
    expect(tester.takeException(), isNull);
  });
}
