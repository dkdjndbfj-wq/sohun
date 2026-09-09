import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/core/startup/startup_handoff.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/features/dashboard/material_playground_hero.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:consumable_tracker_desktop/providers/stock_alert_provider.dart';
import 'package:consumable_tracker_desktop/widgets/filament_spool_icon.dart';
import 'package:consumable_tracker_desktop/widgets/sohun_wordmark.dart';

void main() {
  testWidgets('工作台静态展示真实库存并允许点破低频提醒', (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var enteredWorkspace = false;
    final now = DateTime(2026, 7, 30);
    final items = [
      Consumable(
        id: 1,
        uid: 'red-pla',
        manufacturer: 'sohun',
        model: 'Basic PLA',
        materialType: 'PLA',
        colorHex: '#E5484D',
        colorName: '珊瑚红',
        totalGrams: 1000,
        remainingGrams: 860,
        createdAt: now,
        updatedAt: now,
      ),
      Consumable(
        id: 2,
        uid: 'blue-petg',
        manufacturer: 'sohun',
        model: 'Ocean PETG',
        materialType: 'PETG',
        colorHex: '#1677FF',
        colorName: '海蓝',
        totalGrams: 1000,
        remainingGrams: 420,
        createdAt: now,
        updatedAt: now,
      ),
    ];
    final alerts = [
      const StockAlertItem(
        manufacturer: 'sohun',
        materialType: 'PETG',
        colorHex: '#1677FF',
        colorName: '海蓝',
        totalRemainingGrams: 420,
        rollCount: 1,
        lowRollCount: 1,
        costPerKg: null,
        monthlyConsumptionGrams: 600,
        estimatedDaysLeft: 21,
        level: StockLevel.low,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          consumablesProvider.overrideWith((ref) => Stream.value(items)),
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value(const <PrinterWithChannels>[]),
          ),
          stockAlertsProvider.overrideWith((ref) async => alerts),
          materialHeroPrinterStatusProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          home: InteractionEffectsScope(
            enabled: false,
            child: Scaffold(
              body: SizedBox(
                width: 1100,
                child: MaterialPlaygroundHero(
                  height: 620,
                  onEnterWorkspace: () => enteredWorkspace = true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('准备好下一次打印'), findsOneWidget);
    expect(find.textContaining('2 种在库材料'), findsOneWidget);
    expect(find.byType(FilamentSpoolIcon), findsOneWidget);
    expect(find.byType(SohunWordmark), findsOneWidget);
    expect(find.byType(StartupLandingTarget), findsOneWidget);
    expect(find.text('MATERIAL PLAYGROUND'), findsNothing);
    expect(tester.getSize(find.byType(ClipRRect)).height, 620);
    final spoolCenter = tester.getCenter(find.byType(FilamentSpoolIcon));
    final titleCenter = tester.getCenter(find.text('准备好下一次打印'));
    expect(spoolCenter.dx, closeTo(550, 32));
    expect(spoolCenter.dy, lessThan(titleCenter.dy));
    expect(find.byTooltip('珊瑚红 · PLA\n860g'), findsNothing);
    expect(find.byTooltip('海蓝 · PETG\n420g'), findsNothing);
    expect(find.text('拖动或滚轮切换'), findsNothing);
    expect(find.byKey(const ValueKey('spool-selector-hint')), findsNothing);
    const reminderKey =
        ValueKey('hero-reminder-bubble-stock:sohun|PETG|#1677FF:low');
    expect(find.byKey(reminderKey), findsOneWidget);
    expect(find.text('海蓝库存偏低，预计可用 21 天'), findsOneWidget);
    expect(find.byKey(const ValueKey('hero-stock-alert-button')), findsNothing);
    expect(
      tester
          .widget<FilamentSpoolIcon>(find.byType(FilamentSpoolIcon))
          .dimensional,
      isTrue,
    );
    expect(
      tester.widget<FilamentSpoolIcon>(find.byType(FilamentSpoolIcon)).color,
      const Color(0xFFE5484D),
    );

    await tester.tap(find.byKey(reminderKey));
    await tester.pump();
    expect(find.byKey(reminderKey), findsNothing);
    expect(
      find.textContaining('珊瑚红 · PLA · 860g'),
      findsOneWidget,
    );

    await tester.tap(find.text('进入工作区'));
    expect(enteredWorkspace, isTrue);
  });

  testWidgets('AMS 高湿度以可点破气泡提醒且干燥中不重复提醒', (tester) async {
    tester.view.physicalSize = const Size(1000, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> pumpHero(BambuPrinterStatus status) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            consumablesProvider.overrideWith(
              (ref) => Stream.value(const <Consumable>[]),
            ),
            printersWithChannelsProvider.overrideWith(
              (ref) => Stream.value(const <PrinterWithChannels>[]),
            ),
            stockAlertsProvider.overrideWith(
              (ref) async => const <StockAlertItem>[],
            ),
            materialHeroPrinterStatusProvider.overrideWithValue(status),
          ],
          child: const MaterialApp(
            home: InteractionEffectsScope(
              enabled: false,
              child: Scaffold(
                body: MaterialPlaygroundHero(
                  height: 600,
                  onEnterWorkspace: _noop,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pumpHero(
      BambuPrinterStatus(
        serial: 'ams-humidity-test',
        amsHumidity: 68,
        amsDrying: false,
      ),
    );
    const humidityKey =
        ValueKey('hero-reminder-bubble-ams-humidity:ams-humidity-test');
    expect(find.byKey(humidityKey), findsOneWidget);
    expect(find.text('AMS 湿度 68%，建议开启干燥'), findsOneWidget);

    await tester.tap(find.byKey(humidityKey));
    await tester.pump();
    expect(find.byKey(humidityKey), findsNothing);

    await pumpHero(
      BambuPrinterStatus(
        serial: 'ams-drying-test',
        amsHumidity: 72,
        amsDrying: true,
      ),
    );
    expect(find.textContaining('AMS 湿度 72%'), findsNothing);
  });
}

void _noop() {}
