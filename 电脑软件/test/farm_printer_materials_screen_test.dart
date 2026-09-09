import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/core/services/studio_video_relay_service.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/printer_feed_models.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_printer_materials_screen.dart';
import 'package:consumable_tracker_desktop/providers/printer_connection_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestVideoRelayController extends StudioVideoRelayController {
  _TestVideoRelayController(
    Ref ref,
    StudioVideoRelayState initialState,
  ) : super(ref, active: false) {
    state = initialState;
  }
}

void main() {
  testWidgets('设备耗材卡片显示打印进度和竖向槽位剩余克数', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 8, 5, 12);
    final spool = Consumable(
      id: 7,
      uid: 'farm-loaded-spool',
      manufacturer: '拓竹',
      model: 'PLA Basic',
      materialType: 'PLA',
      colorHex: '#00B42A',
      colorName: '绿色',
      totalGrams: 1000,
      remainingGrams: 0,
      createdAt: now,
      updatedAt: now,
    );
    final printer = Printer(
      id: 1,
      uid: 'farm-a1',
      name: 'A1 一号机',
      brand: '拓竹',
      model: 'A1',
      channelCount: 1,
      isCustomImage: false,
      createdAt: now,
      updatedAt: now,
    );
    final printerWithChannels = PrinterWithChannels(
      printer,
      [
        ChannelWithConsumable(
          PrinterChannel(
            id: 1,
            printerId: printer.id,
            channelIndex: externalFeedRightChannel,
            label: '外挂',
            consumableId: spool.id,
            loadedRemainingGrams: 642,
            updatedAt: now,
          ),
          spool,
        ),
      ],
      serial: 'A1-TEST-001',
    );
    final fleetState = FleetPrinterState(
      serial: 'A1-TEST-001',
      displayLabel: 'A1 一号机',
      connectionState: PrinterConnectionState.connected,
      lastStatus: BambuPrinterStatus(
        serial: 'A1-TEST-001',
        gcodeState: BambuGcodeState.running,
        mcPercent: 37,
        mcRemainingTime: 48,
        currLayer: 18,
        totalLayers: 120,
        amsUnits: const [],
      ),
      statusUpdatedAt: now,
      isLanCapable: true,
      mode: BambuConnectionMode.lan,
      reportedModel: 'A1',
      installedNozzleDiameter: 0.4,
      isConnecting: false,
    );
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
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value([printerWithChannels]),
          ),
          fleetPrinterStatesProvider.overrideWithValue([fleetState]),
          farmConsumablesProvider.overrideWith(
            (ref) => Stream.value([spool]),
          ),
          studioSnapshotProvider.overrideWith(
            (ref) => Stream.value(snapshot),
          ),
          currentFarmPermissionProvider.overrideWith((ref, code) => true),
          mergedPrinterListProvider.overrideWithValue([
            PrinterConnectionConfig.cloud(
              serial: 'A1-TEST-001',
              devProductName: 'A1',
            ),
          ]),
          studioVideoRelayControllerProvider.overrideWith(
            (ref) => _TestVideoRelayController(
              ref,
              const StudioVideoRelayState(
                activeStreams: 1,
                activePrinterSerials: {'A1-TEST-001'},
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: FarmPrinterMaterialsScreen()),
        ),
      ),
    );
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('设备与耗材'), findsOneWidget);
    expect(find.text('设备矩阵'), findsNothing);
    expect(find.text('摄像头占用'), findsNothing);
    final cameraViewerDot = find.byKey(
      const ValueKey('farm-camera-viewer-A1-TEST-001-active'),
    );
    expect(cameraViewerDot, findsOneWidget);
    final keyedPrinterCard = find.byKey(
      const ValueKey('farm-printer-card-A1-TEST-001'),
    );
    expect(keyedPrinterCard, findsOneWidget);
    final printerIcon = find.byIcon(Icons.precision_manufacturing_outlined);
    expect(printerIcon, findsOneWidget);
    final cameraCenter = tester.getRect(cameraViewerDot).center;
    final cardRect = tester.getRect(keyedPrinterCard);
    expect(cameraCenter.dx, closeTo(cardRect.left + 14, 0.01));
    expect(cameraCenter.dy, closeTo(cardRect.top + 14, 0.01));
    expect(
      tester.getRect(cameraViewerDot).bottom,
      lessThanOrEqualTo(tester.getRect(printerIcon).top),
    );
    expect(find.text('局域网绑定'), findsOneWidget);
    expect(find.text('拓竹账号'), findsOneWidget);
    expect(find.text('刷新连接'), findsOneWidget);
    expect(find.text('打印中'), findsOneWidget);
    expect(find.text('37%'), findsOneWidget);
    expect(find.textContaining('剩余 48 分钟'), findsOneWidget);
    expect(find.textContaining('18 / 120 层'), findsOneWidget);
    expect(find.textContaining('拓竹云端绑定'), findsNothing);
    expect(find.textContaining('拓竹局域网绑定'), findsNothing);
    final cloudBadge = find.byKey(
      const ValueKey('farm-printer-connection-cloud'),
    );
    expect(cloudBadge, findsOneWidget);
    expect(find.text('云端'), findsOneWidget);
    final cloudBadgeRect = tester.getRect(cloudBadge);
    expect(cloudBadgeRect.right, closeTo(cardRect.right - 8, 0.01));
    expect(cloudBadgeRect.bottom, closeTo(cardRect.bottom - 7, 0.01));
    expect(find.text('PB'), findsOneWidget);
    expect(find.text('剩余642g'), findsOneWidget);
    expect(find.text('外挂 R'), findsOneWidget);
    expect(find.text('AMS 1'), findsNothing);
    expect(find.byTooltip('拓竹 PLA Basic'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Tooltip && (widget.message ?? '').contains('外挂'),
      ),
      findsNothing,
    );

    final slot = find
        .ancestor(
          of: find.text('剩余642g'),
          matching: find.byType(InkWell),
        )
        .first;
    final slotSize = tester.getSize(slot);
    expect(slotSize.height, greaterThan(slotSize.width));
    expect(slotSize.height, lessThanOrEqualTo(84));
    final printerCard = find.byType(Card).first;
    expect(tester.getSize(printerCard).width, lessThanOrEqualTo(440));
    expect(tester.getSize(printerCard).height, lessThanOrEqualTo(190));
    await tester.tap(
      find.byKey(const ValueKey('farm-camera-preview-trigger-A1-TEST-001')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.byKey(const ValueKey('farm-camera-preview-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('实时画面'), findsWidgets);
    await tester.tap(find.byTooltip('关闭实时画面'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('AMS 按设备分组横向分页并区分不同类型', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime(2026, 8, 5, 12);
    final printer = Printer(
      id: 2,
      uid: 'farm-x1c',
      name: 'X1C 一号机',
      brand: '拓竹',
      model: 'X1C',
      channelCount: 13,
      isCustomImage: false,
      createdAt: now,
      updatedAt: now,
    );
    final channels = <ChannelWithConsumable>[];
    final typeNames = <String>['AMS 1', 'AMS 1', 'AMS 2 Pro'];
    var id = 10;
    for (var unit = 0; unit < typeNames.length; unit++) {
      for (var slot = 0; slot < 4; slot++) {
        channels.add(
          ChannelWithConsumable(
            PrinterChannel(
              id: id++,
              printerId: printer.id,
              channelIndex: unit * 4 + slot,
              label: '第 ${unit + 1} 台 ${typeNames[unit]} · 第 ${slot + 1} 通道',
              loadedRemainingGrams: 0,
              updatedAt: now,
            ),
            null,
          ),
        );
      }
    }
    channels.add(
      ChannelWithConsumable(
        PrinterChannel(
          id: id,
          printerId: printer.id,
          channelIndex: 16,
          label: '第 4 台 AMS HT · 第 1 通道',
          loadedRemainingGrams: 0,
          updatedAt: now,
        ),
        null,
      ),
    );
    final configured = PrinterWithChannels(
      printer,
      channels,
      serial: 'X1C-TEST-001',
    );
    final fleetState = FleetPrinterState(
      serial: 'X1C-TEST-001',
      displayLabel: 'X1C 一号机',
      connectionState: PrinterConnectionState.connected,
      lastStatus: BambuPrinterStatus(
        serial: 'X1C-TEST-001',
        gcodeState: BambuGcodeState.idle,
        mcPercent: 0,
        amsUnits: const [
          AmsUnit(
            id: 0,
            type: AmsUnitType.ams,
            isPresent: true,
            trays: const [],
          ),
          AmsUnit(
            id: 1,
            type: AmsUnitType.ams,
            isPresent: true,
            trays: const [],
          ),
          AmsUnit(
            id: 2,
            type: AmsUnitType.ams2Pro,
            isPresent: true,
            trays: const [],
          ),
          AmsUnit(
            id: 128,
            type: AmsUnitType.amsHt,
            isPresent: true,
            trays: const [],
          ),
        ],
      ),
      statusUpdatedAt: now,
      isLanCapable: true,
      mode: BambuConnectionMode.lan,
      reportedModel: 'X1C',
      installedNozzleDiameter: 0.4,
      isConnecting: false,
    );
    final snapshot = StudioSnapshot(
      workspace: StudioWorkspace(
        id: 'farm-ams-test',
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
            (ref) => Stream.value([configured]),
          ),
          fleetPrinterStatesProvider.overrideWithValue([fleetState]),
          farmConsumablesProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          studioSnapshotProvider.overrideWith(
            (ref) => Stream.value(snapshot),
          ),
          currentFarmPermissionProvider.overrideWith((ref, code) => true),
          mergedPrinterListProvider.overrideWithValue(const [
            PrinterConnectionConfig(
              serial: 'X1C-TEST-001',
              host: '192.168.1.26',
              accessCode: 'lan-access-code',
              devProductName: 'X1C',
            ),
          ]),
          studioVideoRelayControllerProvider.overrideWith(
            (ref) => StudioVideoRelayController(ref, active: false),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: FarmPrinterMaterialsScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rail = find.byWidgetPredicate(
      (widget) =>
          widget is ListView && widget.scrollDirection == Axis.horizontal,
    );
    expect(rail, findsOneWidget);
    final railWidget = tester.widget<ListView>(rail);
    expect(railWidget.childrenDelegate.estimatedChildCount, 7);
    expect(find.text('1槽'), findsOneWidget);
    expect(find.text('①'), findsOneWidget);
    expect(find.byType(Scrollbar), findsOneWidget);
    expect(
      find.byKey(const ValueKey('farm-printer-connection-lan')),
      findsOneWidget,
    );
    expect(find.text('局域网'), findsOneWidget);

    await tester.drag(rail, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(find.text('1槽'), findsOneWidget);
    expect(find.text('HT'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('farm-camera-viewer-X1C-TEST-001-idle'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
