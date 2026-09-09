import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/database/daos/filament_cost_config_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/features/inventory/consumable_card.dart';
import 'package:consumable_tracker_desktop/providers/filament_cost_provider.dart';
import 'package:consumable_tracker_desktop/widgets/filament_spool_icon.dart';

void main() {
  testWidgets('库存耗材卷悬在卡片左上且品牌图位于白卡背景内', (tester) async {
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime(2026, 7, 31);
    final item = Consumable(
      id: 7,
      uid: 'inventory-card-test',
      manufacturer: 'eSUN',
      model: 'Basic PLA',
      materialType: 'PLA',
      colorHex: '#E5484D',
      colorName: '珊瑚红',
      totalGrams: 1000,
      remainingGrams: 760,
      createdAt: now,
      updatedAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          filamentCostConfigsProvider.overrideWith(
            (ref) => Stream.value(const <FilamentCostConfig>[]),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            backgroundColor: const Color(0xFFE9ECEB),
            body: Center(
              child: InteractionEffectsScope(
                enabled: false,
                child: SizedBox(
                  key: const ValueKey('inventory-card-host'),
                  width: 236,
                  height: 268,
                  child: MaterialShelfCard(item: item),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final hostRect = tester.getRect(
      find.byKey(const ValueKey('inventory-card-host')),
    );
    final surfaceFinder = find.byKey(
      const ValueKey('material-shelf-surface-7'),
    );
    final surfaceRect = tester.getRect(surfaceFinder);
    final spoolRect = tester.getRect(find.byType(FilamentSpoolIcon));

    expect(surfaceRect.left, hostRect.left);
    expect(surfaceRect.right, hostRect.right);
    expect(surfaceRect.top, hostRect.top + 54);
    expect(surfaceRect.bottom, hostRect.bottom);
    expect(spoolRect.left, hostRect.left + 14);
    expect(spoolRect.top, lessThan(surfaceRect.top));
    expect(spoolRect.bottom, greaterThan(surfaceRect.top));
    final watermarkRect = tester.getRect(
      find.byKey(const ValueKey('material-shelf-brand-watermark-7')),
    );
    expect(watermarkRect, surfaceRect);
    final surface = tester.widget<DecoratedBox>(surfaceFinder);
    expect((surface.decoration as BoxDecoration).color, Colors.white);
  });
}
