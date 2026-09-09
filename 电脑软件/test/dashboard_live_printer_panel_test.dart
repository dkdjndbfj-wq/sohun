import 'package:consumable_tracker_desktop/core/services/printer_fault_service.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_task_consumable_dao.dart';
import 'package:consumable_tracker_desktop/data/database/daos/print_task_dao.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/dashboard/dashboard_screen.dart';
import 'package:consumable_tracker_desktop/providers/database_provider.dart';
import 'package:consumable_tracker_desktop/providers/print_task_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('宽屏实时打印卡将耗材与成本紧凑放在控制按钮左侧', (tester) async {
    SharedPreferences.setMockInitialValues({
      'active_printer_serial': 'TEST-SN',
    });
    await tester.binding.setSurfaceSize(const Size(1180, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 8, 5, 10);
    final consumableId = await db.customInsert(
      "INSERT INTO consumables(manufacturer, model, material_type, color_hex, "
      "total_grams, remaining_grams) VALUES "
      "('拓竹', 'PLA Basic', 'PLA', '#FFFFFF', 1000, 640)",
    );
    final status = BambuPrinterStatus(
      serial: 'TEST-SN',
      gcodeState: BambuGcodeState.running,
      mcPercent: 42,
      mcRemainingTime: 95,
      currLayer: 84,
      totalLayers: 200,
      nozzleTemper: 214,
      nozzleTargetTemper: 220,
      bedTemper: 59,
      bedTargetTemper: 60,
      spdMag: 100,
      spdLvl: 2,
      subtaskName: '紧凑进度卡测试任务',
      updatedAt: now,
    );
    final taskTemplate = PrintTask(
      uid: 'task-1',
      printerId: null,
      gcodePath: 'compact-card.gcode',
      taskName: '紧凑进度卡测试任务',
      estimatedGrams: 30,
      estimatedSeconds: 7200,
      actualGrams: 12.6,
      startedAt: now.subtract(const Duration(minutes: 45)),
      lastMcPercent: 42,
      lastLayer: 84,
      status: PrintTaskStatus.printing,
      source: 'test',
      createdAt: now,
      updatedAt: now,
    );
    final taskId = await PrintTaskDao(db).create(taskTemplate);
    final task = taskTemplate.copyWith(id: taskId);
    await PrintTaskConsumableDao(db).createForTask(taskId, [
      PrintTaskConsumable(
        taskId: taskId,
        printerId: null,
        channelIndex: 0,
        consumableId: consumableId,
        toolIndex: 0,
        estimatedGrams: 30,
        lastDeductedGrams: 12.6,
        costPerKgSnapshot: 120,
        createdAt: now,
        updatedAt: now,
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          activePrinterSerialProvider.overrideWith(
            (ref) => _FixedSerialNotifier('TEST-SN'),
          ),
          activePrinterConfigProvider.overrideWithValue(
            PrinterConnectionConfig.cloud(
              serial: 'TEST-SN',
              displayName: '工作室 P1S',
              devProductName: 'P1S',
            ),
          ),
          activePrinterConnectionProvider.overrideWith(
            (ref) => _FixedConnectionNotifier(
              ref,
              ActivePrinterState(
                connectionState: PrinterConnectionState.connected,
                status: status,
              ),
            ),
          ),
          activePrintTaskProvider.overrideWithValue(task),
          printerFaultServiceProvider.overrideWith(
            (ref) async => PrinterFaultService(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 70),
              children: const [LivePrinterPanel()],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final card = find.byKey(const ValueKey('dashboard-live-task-card'));
    final inlineFilament =
        find.byKey(const ValueKey('dashboard-inline-filament'));
    final inlineCost = find.byKey(const ValueKey('dashboard-inline-cost'));
    final pauseLabel = find.text('暂停');
    expect(card, findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(inlineFilament, findsOneWidget);
    expect(inlineCost, findsOneWidget);
    expect(find.text('12.6/30g'), findsOneWidget);
    expect(find.text('PB'), findsOneWidget);
    expect(
      find.byTooltip('库存已同步 12.6g\nPB = 拓竹 PLA Basic'),
      findsOneWidget,
    );
    expect(find.text('耗材与成本'), findsNothing);
    expect(find.text('收起耗材与成本'), findsNothing);
    expect(find.text('查看耗材与成本'), findsNothing);

    final filamentRect = tester.getRect(inlineFilament);
    final costRect = tester.getRect(inlineCost);
    final pauseRect = tester.getRect(pauseLabel);
    expect(filamentRect.right, lessThan(costRect.left));
    expect(costRect.right, lessThan(pauseRect.left));
    expect((costRect.center.dy - pauseRect.center.dy).abs(), lessThan(4));
    expect(tester.getSize(card).height, lessThan(220));
    expect(tester.takeException(), isNull);
  });
}

class _FixedSerialNotifier extends ActivePrinterSerialNotifier {
  _FixedSerialNotifier(String serial) : super() {
    state = serial;
  }
}

class _FixedConnectionNotifier extends ActivePrinterConnectionNotifier {
  _FixedConnectionNotifier(super.ref, ActivePrinterState value) {
    state = value;
  }
}
