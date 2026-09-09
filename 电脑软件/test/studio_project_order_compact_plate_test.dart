import 'dart:typed_data';

import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/studio/studio_operations_screens.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';
import 'package:consumable_tracker_desktop/providers/studio_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('项目订单把排产入口和折叠打印明细合并到切片盘行', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final snapshot = _snapshot();
    final configuredPrinter = _configuredPrinter();
    final fleetState = FleetPrinterState(
      serial: configuredPrinter.serial!,
      displayLabel: 'A1 空闲机',
      connectionState: PrinterConnectionState.connected,
      lastStatus: BambuPrinterStatus.idle(configuredPrinter.serial!),
      statusUpdatedAt: DateTime.now(),
      isLanCapable: true,
      mode: BambuConnectionMode.lan,
      reportedModel: 'A1',
      installedNozzleDiameter: 0.4,
      isConnecting: false,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          studioSnapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
          farmConsumablesProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          printersWithChannelsProvider.overrideWith(
            (ref) => Stream.value([configuredPrinter]),
          ),
          fleetPrinterStatesProvider.overrideWithValue([fleetState]),
          currentFarmPermissionProvider.overrideWith((ref, code) => true),
        ],
        child: const MaterialApp(
          home: Scaffold(body: StudioProjectOrdersScreen()),
        ),
      ),
    );
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await tester.tap(find.text('桌面摆件订单'));
    await tester.pumpAndSettle();

    final slice = find.text('切片');
    final schedule = find.text('排产');
    expect(slice, findsOneWidget);
    expect(schedule, findsOneWidget);
    expect(
      tester.getCenter(schedule).dx,
      greaterThan(tester.getCenter(slice).dx),
    );
    expect(find.textContaining('生产 0 / 3 · 待排产 1'), findsOneWidget);
    expect(find.text('打印明细 2'), findsOneWidget);
    expect(find.text('打印任务 A'), findsNothing);
    expect(find.text('打印任务 B'), findsNothing);

    await tester.tap(schedule);
    await tester.pumpAndSettle();
    expect(find.text('选择空闲打印机'), findsOneWidget);
    expect(find.text('A1 空闲机'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('打印明细 2'));
    await tester.pumpAndSettle();

    expect(find.text('打印任务 A'), findsOneWidget);
    expect(find.text('打印任务 B'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('项目订单在 150% DPI 的窄窗口保持紧凑且无溢出', (tester) async {
    tester.view.physicalSize = const Size(1650, 1350);
    tester.view.devicePixelRatio = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpProjectOrders(
      tester,
      canAssign: true,
      printers: [_configuredPrinter()],
    );
    await tester.tap(find.text('桌面摆件订单'));
    await tester.pumpAndSettle();

    expect(find.text('切片'), findsOneWidget);
    expect(find.text('排产'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('项目订单展开后以多列盘卡展示模型预览', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpProjectOrders(
      tester,
      canAssign: true,
      printers: [_configuredPrinter()],
      includeSecondPlate: true,
    );
    await tester.tap(find.text('桌面摆件订单'));
    await tester.pumpAndSettle();

    final first = find.byKey(const ValueKey('project-plate-card-plate'));
    final second = find.byKey(const ValueKey('project-plate-card-plate-2'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    expect(tester.getSize(first).width, lessThan(230));
    expect(
      tester.getSize(first).height,
      greaterThan(tester.getSize(first).width * 1.2),
    );
    expect(find.textContaining('需要'), findsNothing);
    expect(
      tester.getTopLeft(second).dx,
      greaterThan(tester.getTopLeft(first).dx),
    );
    expect(
      (tester.getTopLeft(second).dy - tester.getTopLeft(first).dy).abs(),
      lessThan(24),
    );
    expect(find.text('切片'), findsNWidgets(2));
    expect(find.text('排产'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有 job.assign 权限时盘行排产按钮禁用', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpProjectOrders(
      tester,
      canAssign: false,
      printers: [_configuredPrinter()],
    );
    await tester.tap(find.text('桌面摆件订单'));
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('schedule-production-plate-plate')),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有打印机时盘卡保留排产入口', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpProjectOrders(tester, canAssign: true, printers: const []);
    await tester.tap(find.text('桌面摆件订单'));
    await tester.pumpAndSettle();

    expect(find.text('排产'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('schedule-production-plate-plate')),
    );
    expect(button.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpProjectOrders(
  WidgetTester tester, {
  required bool canAssign,
  required List<PrinterWithChannels> printers,
  bool includeSecondPlate = false,
}) async {
  final configuredPrinter = _configuredPrinter();
  final fleetState = FleetPrinterState(
    serial: configuredPrinter.serial!,
    displayLabel: 'A1 空闲机',
    connectionState: PrinterConnectionState.connected,
    lastStatus: BambuPrinterStatus.idle(configuredPrinter.serial!),
    statusUpdatedAt: DateTime.now(),
    isLanCapable: true,
    mode: BambuConnectionMode.lan,
    reportedModel: 'A1',
    installedNozzleDiameter: 0.4,
    isConnecting: false,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studioSnapshotProvider.overrideWith(
          (ref) => Stream.value(
            _snapshot(includeSecondPlate: includeSecondPlate),
          ),
        ),
        farmConsumablesProvider.overrideWith((ref) => Stream.value(const [])),
        printersWithChannelsProvider.overrideWith(
          (ref) => Stream.value(printers),
        ),
        fleetPrinterStatesProvider.overrideWithValue(
          printers.isEmpty ? const [] : [fleetState],
        ),
        currentFarmPermissionProvider.overrideWith(
          (ref, code) => code == 'job.assign' ? canAssign : true,
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: StudioProjectOrdersScreen()),
      ),
    ),
  );
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

PrinterWithChannels _configuredPrinter() {
  final now = DateTime.now();
  return PrinterWithChannels(
    Printer(
      id: 99,
      uid: 'printer-99',
      name: 'A1 空闲机',
      brand: '拓竹',
      model: 'A1',
      channelCount: 1,
      isCustomImage: false,
      createdAt: now,
      updatedAt: now,
    ),
    const [],
    serial: 'A1-IDLE-099',
  );
}

StudioSnapshot _snapshot({bool includeSecondPlate = false}) {
  final now = DateTime(2026, 8, 5, 20);
  const workspaceId = 'farm';
  const orderId = 'order';
  const plateId = 'plate';
  return StudioSnapshot(
    workspace: StudioWorkspace(
      id: workspaceId,
      name: '测试农场',
      createdAt: now,
      updatedAt: now,
    ),
    members: const [],
    customers: const [],
    orders: [
      StudioOrder(
        id: orderId,
        workspaceId: workspaceId,
        orderNo: 'SO-260805-001',
        title: '桌面摆件订单',
        status: StudioOrderStatus.production,
        totalPrice: 100,
        createdAt: now,
        updatedAt: now,
      ),
    ],
    workOrders: [
      _workOrder(
        id: 'unassigned',
        title: '待排产任务',
        quantity: 1,
        now: now,
      ),
      _workOrder(
        id: 'assigned-a',
        title: '打印任务 A',
        quantity: 1,
        printerId: 1,
        now: now,
      ),
      _workOrder(
        id: 'assigned-b',
        title: '打印任务 B',
        quantity: 1,
        printerId: 2,
        now: now,
      ),
      if (includeSecondPlate)
        _workOrder(
          id: 'unassigned-2',
          title: '配件待排产任务',
          quantity: 2,
          productionPlateId: 'plate-2',
          now: now,
        ),
    ],
    quotes: const [],
    inventoryEvents: const [],
    inventoryBatches: const [],
    shareLinks: const [],
    productionPackages: [
      StudioProductionPackage(
        id: 'package',
        workspaceId: workspaceId,
        orderId: orderId,
        sourceName: '摆件.3mf',
        artifactKind: '3mf',
        createdAt: now,
        localPath: 'C:/fixtures/摆件.3mf',
      ),
    ],
    productionPlates: [
      StudioProductionPlate(
        id: plateId,
        workspaceId: workspaceId,
        orderId: orderId,
        packageId: 'package',
        plateIndex: 1,
        name: '主体',
        requiredRuns: 3,
        estimatedSeconds: 1800,
        estimatedGrams: 22,
        sliceStatus: StudioPlateSliceStatus.sliced,
        totalLayers: 120,
        sliceArtifactPath: 'C:/fixtures/摆件-plate-1.3mf',
        thumbnailBytes: _platePreviewBytes,
        createdAt: now,
      ),
      if (includeSecondPlate)
        StudioProductionPlate(
          id: 'plate-2',
          workspaceId: workspaceId,
          orderId: orderId,
          packageId: 'package',
          plateIndex: 2,
          name: '配件',
          requiredRuns: 2,
          estimatedSeconds: 900,
          estimatedGrams: 12,
          sliceStatus: StudioPlateSliceStatus.sliced,
          totalLayers: 80,
          sliceArtifactPath: 'C:/fixtures/摆件-plate-2.3mf',
          thumbnailBytes: _platePreviewBytes,
          createdAt: now,
        ),
    ],
    workOrderMaterials: [
      _reservedMaterial('material-a', 'assigned-a', 101, now),
      _reservedMaterial('material-b', 'assigned-b', 102, now),
    ],
  );
}

final _platePreviewBytes = Uint8List.fromList(const [
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x63,
  0xf8,
  0xcf,
  0xc0,
  0xf0,
  0x1f,
  0x00,
  0x05,
  0x00,
  0x01,
  0xff,
  0x89,
  0x99,
  0x3d,
  0x1d,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
]);

StudioWorkOrderMaterial _reservedMaterial(
  String id,
  String workOrderId,
  int consumableId,
  DateTime now,
) {
  return StudioWorkOrderMaterial(
    id: id,
    workspaceId: 'farm',
    workOrderId: workOrderId,
    productionPlateId: 'plate',
    toolIndex: 0,
    estimatedGrams: 22,
    consumableId: consumableId,
    reservedGrams: 22,
    consumedGrams: 0,
    status: StudioWorkOrderMaterialStatus.reserved,
    createdAt: now,
    updatedAt: now,
  );
}

StudioWorkOrder _workOrder({
  required String id,
  required String title,
  required int quantity,
  required DateTime now,
  int? printerId,
  String productionPlateId = 'plate',
}) {
  return StudioWorkOrder(
    id: id,
    workspaceId: 'farm',
    orderId: 'order',
    productionPlateId: productionPlateId,
    title: title,
    quantity: quantity,
    completedQuantity: 0,
    status: printerId == null
        ? StudioWorkOrderStatus.queued
        : StudioWorkOrderStatus.assigned,
    printerId: printerId,
    materialCostSnapshot: 0,
    quotedPriceSnapshot: 0,
    createdAt: now,
    updatedAt: now,
  );
}
