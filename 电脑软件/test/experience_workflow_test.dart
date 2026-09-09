import 'dart:ui';

import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/print_task.dart';
import 'package:consumable_tracker_desktop/data/database/models/scheduler_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/features/firmware/firmware_panel.dart';
import 'package:consumable_tracker_desktop/features/print_history/print_history_screen.dart';
import 'package:consumable_tracker_desktop/features/restock/restock_screen.dart';
import 'package:consumable_tracker_desktop/features/scheduler/scheduler_screen.dart';
import 'package:consumable_tracker_desktop/providers/print_history_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:consumable_tracker_desktop/providers/scheduler_provider.dart';
import 'package:consumable_tracker_desktop/providers/stock_alert_provider.dart';
import 'package:consumable_tracker_desktop/widgets/experience_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('时间轴悬停显示真实日期与数值', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              child: ExperienceTimeline(
                values: const [10, 20, 15],
                labels: const ['7/29', '7/30', '7/31'],
                valueFormatter: (value) => '${value.toStringAsFixed(0)} g',
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer();
    final rect = tester.getRect(find.byType(ExperienceTimeline));
    await gesture.moveTo(Offset(rect.right - 4, rect.center.dy));
    await tester.pump();

    expect(find.textContaining('7/31'), findsOneWidget);
    expect(find.textContaining('15 g'), findsOneWidget);

    await tester.tapAt(Offset(rect.right - 4, rect.center.dy));
    await tester.pump();
    await gesture.moveTo(Offset.zero);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('experience-timeline-tooltip')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
  });

  testWidgets('采购篮勾选会即时更新真实选择数量', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const alerts = [
      StockAlertItem(
        manufacturer: 'Bambu Lab',
        materialType: 'PLA',
        colorHex: '#1DC886',
        colorName: '极光绿',
        totalRemainingGrams: 120,
        rollCount: 1,
        lowRollCount: 1,
        costPerKg: 99,
        monthlyConsumptionGrams: 780,
        estimatedDaysLeft: 4,
        level: StockLevel.critical,
      ),
      StockAlertItem(
        manufacturer: 'Bambu Lab',
        materialType: 'PETG',
        colorHex: '#1677FF',
        colorName: '海蓝',
        totalRemainingGrams: 340,
        rollCount: 1,
        lowRollCount: 1,
        costPerKg: 109,
        monthlyConsumptionGrams: 620,
        estimatedDaysLeft: 16,
        level: StockLevel.low,
      ),
    ];
    const suggestions = [
      PurchaseSuggestion(
        manufacturer: 'Bambu Lab',
        materialType: 'PLA',
        colorHex: '#1DC886',
        colorName: '极光绿',
        currentRemainingGrams: 120,
        monthlyConsumptionGrams: 780,
        suggestedPurchaseGrams: 2000,
        suggestedRolls: 2,
        estimatedCost: 198,
        estimatedDaysLeft: 4,
        level: StockLevel.critical,
      ),
      PurchaseSuggestion(
        manufacturer: 'Bambu Lab',
        materialType: 'PETG',
        colorHex: '#1677FF',
        colorName: '海蓝',
        currentRemainingGrams: 340,
        monthlyConsumptionGrams: 620,
        suggestedPurchaseGrams: 1000,
        suggestedRolls: 1,
        estimatedCost: 109,
        estimatedDaysLeft: 16,
        level: StockLevel.low,
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stockAlertsProvider.overrideWith((ref) async => alerts),
          purchaseListProvider.overrideWith((ref) async => suggestions),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const RestockScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('已选 2 项'), findsOneWidget);
    const alertBasketKey =
        ValueKey('restock-alert-basket-Bambu Lab|PLA|#1DC886');
    expect(find.byKey(alertBasketKey), findsOneWidget);
    await tester.tap(find.byKey(alertBasketKey));
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);
    await tester.tap(find.byKey(alertBasketKey));
    await tester.pump();
    expect(find.text('已选 2 项'), findsOneWidget);

    await tester.tap(find.text('Bambu Lab · PLA · 极光绿').last);
    await tester.pump();
    expect(find.text('已选 1 项'), findsOneWidget);
  });

  testWidgets('打印历史状态图例可筛选并再次点击清除', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 7, 31, 12);
    final tasks = [
      _printTask(
        uid: 'finished-task',
        name: '完成样件',
        status: PrintTaskStatus.finished,
        now: now,
      ),
      _printTask(
        uid: 'failed-task',
        name: '失败样件',
        status: PrintTaskStatus.failed,
        now: now,
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        filteredPrintTasksProvider.overrideWith(
          (ref) => Stream.value(tasks),
        ),
        printHistoryStatsProvider.overrideWith(
          (ref) async => PrintHistoryStats.from(tasks),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PrintHistoryScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    const finishedKey = ValueKey('history-status-filter-finished');
    expect(find.byKey(finishedKey), findsOneWidget);
    await tester.tap(find.byKey(finishedKey));
    await tester.pump();
    expect(
      container.read(printHistoryFilterProvider).status,
      PrintTaskStatus.finished,
    );

    await tester.tap(find.byKey(finishedKey));
    await tester.pump();
    expect(container.read(printHistoryFilterProvider).status, isNull);
  });

  testWidgets('打印历史切换时间范围时保留旧内容而不整页闪烁', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now();
    final tasks = [
      _printTask(
        uid: 'retained-task',
        name: '保留显示的任务',
        status: PrintTaskStatus.finished,
        now: now,
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        filteredPrintTasksProvider.overrideWith((ref) async* {
          final filter = ref.watch(printHistoryFilterProvider);
          if (filter.start != null) {
            await Future<void>.delayed(const Duration(milliseconds: 180));
          }
          yield tasks;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const PrintHistoryScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('保留显示的任务'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('print-history-range-week')),
    );
    await tester.pump();

    expect(find.text('加载打印历史…'), findsNothing);
    expect(find.text('保留显示的任务'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('print-history-inline-refresh')),
      findsOneWidget,
    );

    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('保留显示的任务'), findsOneWidget);
  });

  testWidgets('固件星图设备节点会切换真实活跃打印机', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const printers = [
      PrinterConnectionConfig(
        serial: 'SERIAL-A',
        host: '192.168.1.10',
        accessCode: '12345678',
        devProductName: 'X1 Carbon',
        displayName: '一号机',
      ),
      PrinterConnectionConfig(
        serial: 'SERIAL-B',
        host: '192.168.1.11',
        accessCode: '87654321',
        devProductName: 'P1S',
        displayName: '二号机',
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        mergedPrinterListProvider.overrideWith((ref) => printers),
        activePrinterConfigProvider.overrideWith((ref) => null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(activePrinterSerialProvider.notifier).set('SERIAL-A');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const FirmwarePanel(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    const secondDeviceKey = ValueKey(
      'firmware-topology-device-SERIAL-B',
    );
    expect(find.byKey(secondDeviceKey), findsOneWidget);
    await tester.tap(find.byKey(secondDeviceKey));
    await tester.pump();
    expect(container.read(activePrinterSerialProvider), 'SERIAL-B');
    expect(find.text('正在读取 二号机'), findsOneWidget);
  });

  testWidgets('调度任务只接受精确机型的打印机拖放目标', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1200, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 7, 31);
    final task = SchedulerTask(
      id: 1,
      gcodePath: 'C:/qa/lamp.3mf',
      gcodeFilename: '柔光台灯外壳.3mf',
      modelGroup: PrinterModelGroup.p1,
      requiredMaterial: 'PLA',
      estimatedGrams: 180,
      targetModel: 'P1S',
      targetNozzleDiameter: 0.4,
      createdAt: now,
    );
    final printers = [
      _printer(id: 1, name: '匹配设备', model: 'P1S', now: now),
      _printer(id: 2, name: '不匹配设备', model: 'A1 mini', now: now),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          schedulerTasksProvider.overrideWith(
            (ref) => Stream.value([task]),
          ),
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value(printers),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SchedulerScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.byType(Draggable<SchedulerTask>), findsOneWidget);
    final targets = tester
        .widgetList<DragTarget<SchedulerTask>>(
          find.byType(DragTarget<SchedulerTask>),
        )
        .toList(growable: false);
    expect(targets, hasLength(2));
    final details = DragTargetDetails<SchedulerTask>(
      data: task,
      offset: Offset.zero,
    );
    expect(targets[0].onWillAcceptWithDetails!(details), isTrue);
    expect(targets[1].onWillAcceptWithDetails!(details), isFalse);
  });
}

PrintTask _printTask({
  required String uid,
  required String name,
  required PrintTaskStatus status,
  required DateTime now,
}) {
  return PrintTask(
    uid: uid,
    gcodePath: 'C:/qa/$uid.3mf',
    taskName: name,
    estimatedGrams: 30,
    estimatedSeconds: 1800,
    actualGrams: status == PrintTaskStatus.finished ? 29 : 12,
    startedAt: now.subtract(const Duration(minutes: 30)),
    finishedAt: now,
    lastMcPercent: status == PrintTaskStatus.finished ? 100 : 42,
    lastLayer: 20,
    status: status,
    source: 'test',
    createdAt: now,
    updatedAt: now,
  );
}

PrinterWithChannels _printer({
  required int id,
  required String name,
  required String model,
  required DateTime now,
}) {
  return PrinterWithChannels(
    Printer(
      id: id,
      uid: 'printer-$id',
      name: name,
      brand: '拓竹',
      model: model,
      channelCount: 4,
      isCustomImage: false,
      createdAt: now,
      updatedAt: now,
    ),
    const [],
    serial: 'SERIAL-$id',
  );
}
