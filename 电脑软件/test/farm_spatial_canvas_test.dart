import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_ui/farm_design.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_ui/farm_theme.dart';
import 'package:consumable_tracker_desktop/features/studio/studio_operations_screens.dart';
import 'package:consumable_tracker_desktop/providers/farm_slice_intake_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:consumable_tracker_desktop/providers/scheduler_provider.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('农场总控台按打印机数量生成俯视节点并支持拖动画布', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: const FarmThemeScope(
          child: Scaffold(body: _CanvasHost()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('设备 1'), findsOneWidget);
    expect(find.text('设备 8'), findsOneWidget);
    expect(find.text('拖动画布 · 滚轮缩放 · 点击设备查看详情'), findsOneWidget);

    await tester.drag(find.byType(InteractiveViewer), const Offset(-180, -90));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('重置画布视角'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('农场总控台把俯视空间作为主视图', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 9, 12);
    final printer = PrinterWithChannels(
      Printer(
        id: 1,
        uid: 'farm-overview-1',
        name: '总控台设备',
        brand: '拓竹',
        model: 'P1S',
        channelCount: 4,
        isCustomImage: false,
        createdAt: now,
        updatedAt: now,
      ),
      const <ChannelWithConsumable>[],
      serial: 'OVERVIEW-1',
    );
    final snapshot = StudioSnapshot(
      workspace: StudioWorkspace(
        id: 'farm-overview',
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
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value([printer]),
          ),
          fleetPrinterStatesProvider.overrideWithValue(const []),
          farmConsumablesProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          schedulerTasksProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          studioSnapshotProvider.overrideWith(
            (ref) => Stream.value(snapshot),
          ),
          currentFarmPermissionProvider.overrideWith((ref, code) => true),
          farmSliceIntakeProvider.overrideWith(
            (ref) => FarmSliceIntakeNotifier(),
          ),
        ],
        child: const MaterialApp(
          home: FarmThemeScope(child: StudioFarmOverviewScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FarmPrinterSpatialCanvas), findsOneWidget);
    expect(find.text('总控台设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _CanvasHost extends StatelessWidget {
  const _CanvasHost();

  @override
  Widget build(BuildContext context) {
    final now = DateTime(2026, 9, 12);
    return Padding(
      padding: const EdgeInsets.all(18),
      child: FarmPrinterSpatialCanvas(
        printers: [
          for (var index = 0; index < 8; index++)
            PrinterWithChannels(
              Printer(
                id: index + 1,
                uid: 'farm-spatial-$index',
                name: '设备 ${index + 1}',
                brand: '拓竹',
                model: index.isEven ? 'P1S' : 'A1',
                channelCount: 4,
                isCustomImage: false,
                createdAt: now,
                updatedAt: now,
              ),
              const <ChannelWithConsumable>[],
              serial: 'FARM-${index + 1}',
            ),
        ],
      ),
    );
  }
}
