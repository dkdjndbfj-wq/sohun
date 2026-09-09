import 'dart:io';

import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_continuous_print_screen.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'print_queue_enabled': true,
      'unattended_mode_enabled': false,
    });
  });

  testWidgets('连续生产页以单文件批量发布为主体，策略设置独立弹出', (tester) async {
    tester.view.physicalSize = const Size(892, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime(2026, 8, 4);
    final snapshot = StudioSnapshot(
      workspace: StudioWorkspace(
        id: 'farm-test',
        name: '测试农场',
        createdAt: now,
        updatedAt: now,
      ),
      members: const [],
      customers: const [],
      orders: const [],
      workOrders: const [],
      quotes: const [],
      inventoryEvents: const [],
      inventoryBatches: const [],
      shareLinks: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          studioSnapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
          farmConsumablesProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          fleetPrinterStatesProvider.overrideWithValue(const []),
          currentFarmPermissionProvider.overrideWith((ref, code) => true),
        ],
        child: const MaterialApp(
          home: Scaffold(body: FarmContinuousPrintScreen()),
        ),
      ),
    );
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('批量连续生产'), findsOneWidget);
    expect(find.text('队列策略'), findsOneWidget);
    expect(find.text('尚未选择已切片文件'), findsOneWidget);
    expect(find.text('选择文件'), findsOneWidget);
    expect(find.textContaining('忙机不动，空闲机先开始'), findsOneWidget);
    expect(find.text('暂无需要排产的订单'), findsNothing);
    expect(find.text('自动取件 G-code'), findsNothing);
    expect(find.text('生产轨道'), findsNothing);
    expect(find.text('添加到轨道'), findsNothing);
    expect(find.text('添加文件'), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);

    await tester.tap(find.text('队列策略'));
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('启用打印队列'), findsOneWidget);
    expect(find.text('打印中允许预排下个任务'), findsNothing);
    expect(find.textContaining('打印中可直接预排后续任务'), findsOneWidget);
    expect(find.text('无人值守连续打印'), findsOneWidget);

    final switches =
        tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
    expect(switches, hasLength(2));
    expect(switches.first.value, isTrue);
    expect(switches.last.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  test('旧的禁止预排偏好不再参与调度', () {
    final scheduler =
        File('lib/providers/scheduler_provider.dart').readAsStringSync();
    final screen = File(
      'lib/features/studio/farm_continuous_print_screen.dart',
    ).readAsStringSync();

    expect(scheduler, isNot(contains('farm_allow_queue_while_printing')));
    expect(screen, isNot(contains('farm_allow_queue_while_printing')));
    expect(scheduler, isNot(contains('allowQueueWhilePrinting')));
  });
}
