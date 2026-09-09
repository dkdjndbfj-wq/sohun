import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/filament_change_point.dart';
import 'package:consumable_tracker_desktop/data/external/slicer/slice_result.dart';
import 'package:consumable_tracker_desktop/features/inventory/consumable_card.dart';
import 'package:consumable_tracker_desktop/features/print_task/external_multicolor_plan_dialog.dart';
import 'package:consumable_tracker_desktop/features/print_task/filament_change_reminder_dialog.dart';
import 'package:consumable_tracker_desktop/providers/consumable_provider.dart';
import 'package:consumable_tracker_desktop/providers/external_multicolor_plan_provider.dart';
import 'package:consumable_tracker_desktop/providers/filament_cost_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 8, 2);
  final inventory = [
    Consumable(
      id: 1,
      uid: 'red',
      manufacturer: 'Bambu Lab',
      model: 'PLA Basic',
      materialType: 'PLA',
      colorHex: '#F04444',
      colorName: '红色',
      totalGrams: 1000,
      remainingGrams: 760,
      createdAt: now,
      updatedAt: now,
    ),
    Consumable(
      id: 2,
      uid: 'green-esun',
      manufacturer: 'eSUN',
      model: 'PLA+',
      materialType: 'PLA+',
      colorHex: '#44CC77',
      colorName: '翠绿',
      totalGrams: 2000,
      remainingGrams: 1430,
      createdAt: now,
      updatedAt: now,
    ),
  ];

  testWidgets('color plan shows every sliced color and stock/create actions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final request = ExternalMulticolorPlanRequest(
      taskId: 1,
      printerId: 1,
      printerSerial: 'P1',
      printerLabel: '工作室 P1S',
      taskName: '三色标牌',
      filaments: [
        FilamentUsage(
          toolIndex: 0,
          grams: 12,
          lengthMm: 1,
          colorHex: '#F04444',
          materialType: 'PLA',
        ),
        FilamentUsage(
          toolIndex: 1,
          grams: 8,
          lengthMm: 1,
          colorHex: '#44CC77',
          materialType: 'PLA',
        ),
        FilamentUsage(
          toolIndex: 2,
          grams: 5,
          lengthMm: 1,
          colorHex: '#4477EE',
          materialType: 'PETG',
        ),
      ],
      changePoints: const [
        FilamentChangePoint(
          layerNum: 5,
          toolIndex: 1,
          previousToolIndex: 0,
          colorHex: '#44CC77',
        ),
        FilamentChangePoint(
          layerNum: 9,
          toolIndex: 2,
          previousToolIndex: 1,
          colorHex: '#4477EE',
        ),
      ],
      createdAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          consumablesProvider.overrideWith((ref) => Stream.value(inventory)),
          personalRfidSpoolBindingsProvider.overrideWith(
            (ref) => const {},
          ),
          // These fixtures are ordinary aggregate stock, not individually
          // registered RFID receipts. Keep both identity sources isolated.
          personalRfidStockSourcesProvider.overrideWith((ref) => const {}),
          filamentCostConfigsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: MaterialApp(
          home: InteractionEffectsScope(
            enabled: false,
            child: ExternalMulticolorPlanDialog(request: request),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('确认外挂多色耗材'), findsOneWidget);
    expect(find.textContaining('工作室 P1S'), findsOneWidget);
    expect(find.textContaining('T0 · #F04444'), findsOneWidget);
    expect(find.textContaining('T1 · #44CC77'), findsOneWidget);
    expect(find.textContaining('T2 · #4477EE'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('choose-consumable-tool-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('choose-consumable-tool-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('choose-consumable-tool-2')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(ExternalMulticolorPlanDialog),
      matchesGoldenFile('goldens/external_multicolor_plan_dialog.png'),
    );

    await tester.tap(
      find.byKey(const ValueKey('choose-consumable-tool-0')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('external-consumable-picker')),
      findsOneWidget,
    );
    expect(find.text('Bambu Lab'), findsWidgets);
    expect(find.text('eSUN'), findsWidgets);
    expect(find.byType(MaterialShelfCard), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('external-picker-create')),
      findsOneWidget,
    );
    await expectLater(
      find.byKey(const ValueKey('external-consumable-picker')),
      matchesGoldenFile('goldens/external_consumable_picker_dialog.png'),
    );
    await tester.enterText(
      find.byKey(const ValueKey('external-picker-search')),
      'eSUN',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('external-picker-consumable-1')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('external-picker-consumable-2')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('logical colors may share stock and combined shortage is blocked',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final lowStock = [
      Consumable(
        id: 9,
        uid: 'shared-green',
        manufacturer: 'Bambu Lab',
        model: 'PLA Basic',
        materialType: 'PLA',
        colorHex: '#44CC77',
        colorName: '绿色',
        totalGrams: 1000,
        remainingGrams: 15,
        createdAt: now,
        updatedAt: now,
      ),
    ];
    final request = ExternalMulticolorPlanRequest(
      taskId: 9,
      printerId: 1,
      printerSerial: 'P1',
      printerLabel: '工作室 P1S',
      taskName: '自由配色标牌',
      filaments: [
        FilamentUsage(
          toolIndex: 0,
          grams: 12,
          lengthMm: 1,
          colorHex: '#FFD43B',
          materialType: 'PLA',
        ),
        FilamentUsage(
          toolIndex: 1,
          grams: 8,
          lengthMm: 1,
          colorHex: '#44CC77',
          materialType: 'PLA',
        ),
      ],
      changePoints: const [
        FilamentChangePoint(
          layerNum: 5,
          toolIndex: 1,
          previousToolIndex: 0,
        ),
      ],
      createdAt: now,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          consumablesProvider.overrideWith((ref) => Stream.value(lowStock)),
          personalRfidSpoolBindingsProvider.overrideWith(
            (ref) => const {},
          ),
          personalRfidStockSourcesProvider.overrideWith((ref) => const {}),
          filamentCostConfigsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: MaterialApp(
          home: InteractionEffectsScope(
            enabled: false,
            child: ExternalMulticolorPlanDialog(request: request),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final tool in [0, 1]) {
      await tester.tap(
        find.byKey(ValueKey('choose-consumable-tool-$tool')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('external-picker-consumable-9')),
      );
      await tester.pumpAndSettle();
    }

    expect(find.textContaining('T0 + T1 共用'), findsOneWidget);
    expect(find.textContaining('还差 5g'), findsOneWidget);
    expect(find.byKey(const ValueKey('restock-9')), findsOneWidget);
    await expectLater(
      find.byType(ExternalMulticolorPlanDialog),
      matchesGoldenFile(
        'goldens/external_multicolor_shared_shortage_dialog.png',
      ),
    );

    await tester.tap(find.byKey(const ValueKey('confirm-external-plan')));
    await tester.pump();
    expect(find.byKey(const ValueKey('external-plan-error')), findsOneWidget);
    expect(find.textContaining('请先补入同款卷或重新分配'), findsOneWidget);
  });

  testWidgets(
      'feed reminder is blocking and identifies printer and stock spool',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(520, 690));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final phase = ValueNotifier(FilamentFeedPhase.loading);
    addTearDown(phase.dispose);
    const data = FilamentChangeReminderData(
      point: FilamentChangePoint(
        layerNum: 18,
        toolIndex: 2,
        previousToolIndex: 1,
        colorHex: '#4477EE',
        materialType: 'PETG',
      ),
      printerLabel: '二号打印机',
      taskName: '三色模型',
      changeIndex: 2,
      changeCount: 4,
      upcoming: [
        FilamentChangePoint(layerNum: 26, toolIndex: 0),
      ],
      currentColorHex: '#44CC77',
      targetSpool: ReminderSpool(
        manufacturer: 'Bambu Lab',
        materialType: 'PETG',
        colorHex: '#4477EE',
        colorName: '深海蓝',
        remainingGrams: 620,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: InteractionEffectsScope(
          enabled: false,
          child: FilamentChangeReminderDialog(data: data, phase: phase),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('请装入下一卷耗材'), findsOneWidget);
    expect(find.textContaining('二号打印机'), findsOneWidget);
    expect(find.textContaining('Bambu Lab · 深海蓝'), findsOneWidget);
    expect(find.text('正在检测新耗材进料'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byType(FilamentChangeReminderDialog),
      matchesGoldenFile('goldens/filament_change_reminder_dialog.png'),
    );
  });

  testWidgets('feed reminder ignores back and closes on machine completion',
      (tester) async {
    final phase = ValueNotifier(FilamentFeedPhase.waiting);
    addTearDown(phase.dispose);
    const data = FilamentChangeReminderData(
      point: FilamentChangePoint(
        layerNum: 6,
        toolIndex: 1,
        previousToolIndex: 0,
        colorHex: '#44CC77',
      ),
      printerLabel: 'P1S',
      taskName: '双色件',
      changeIndex: 1,
      changeCount: 1,
      upcoming: [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () => FilamentChangeReminderDialog.show(
                context,
                data: data,
                phase: phase,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('请装入下一卷耗材'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('请装入下一卷耗材'), findsOneWidget);

    phase.value = FilamentFeedPhase.completed;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('请装入下一卷耗材'), findsNothing);
  });
}
