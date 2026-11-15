import 'package:consumable_tracker_desktop/core/services/cluster_planning_service.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_device_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ClusterPlanningSnapshot _snapshot({
  bool allowMaterial = true,
  double grams = 30,
  ChannelRollHoldState hold = ChannelRollHoldState.maintenance,
  String name = '精细一号',
}) {
  final date = DateTime(2026, 11, 11, 16);
  final material = Consumable(
    id: 7,
    uid: 'private-material',
    manufacturer: '专用测试品牌',
    model: 'test',
    materialType: 'PETG',
    colorHex: '#42ab71',
    colorName: '测试绿',
    totalGrams: 1000,
    remainingGrams: grams,
    createdAt: date,
    updatedAt: date,
  );
  return ClusterPlanningSnapshot(
    studio: StudioSnapshot(
      workspace: StudioWorkspace(
        id: 'scope-1',
        name: '个人空间',
        createdAt: date,
        updatedAt: date,
      ),
      members: const [],
      customers: const [],
      orders: const [],
      workOrders: const [],
      quotes: const [],
      inventoryEvents: const [],
      inventoryBatches: const [],
      shareLinks: const [],
    ),
    tasks: const [],
    printers: [
      ClusterPrinter(
        source: PrinterWithChannels(
          Printer(
            id: 1,
            uid: 'p1',
            brand: 'Bambu',
            model: 'P1S',
            name: name,
            channelCount: 1,
            isCustomImage: false,
            createdAt: date,
            updatedAt: date,
          ),
          [
            ChannelWithConsumable(
              PrinterChannel(
                id: 2,
                printerId: 1,
                channelIndex: 0,
                label: 'A1',
                consumableId: 7,
                loadedRemainingGrams: grams,
                updatedAt: date,
              ),
              material,
              rollHoldState: hold,
            ),
          ],
          serial: 'secret-printer-serial',
        ),
        state: null,
        activeQueueCount: 2,
        availableAfterSeconds: null,
        blockers: const ['尚未获取新鲜状态'],
      ),
    ],
    generatedAt: date,
    visibleConsumableIds: allowMaterial ? {7} : {},
  );
}

Future<void> _open(
  WidgetTester tester,
  ClusterPlanningSnapshot snapshot, {
  Brightness brightness = Brightness.light,
  Size size = const Size(1100, 900),
  double scale = 1,
  ClusterPlatePlan? plan,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showClusterDeviceDetails(
              context,
              printer: snapshot.printers.single,
              snapshot: snapshot,
              plan: plan,
            ),
            child: const Text('打开设备档案'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开设备档案'));
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    200,
    scrollable: find.descendant(
      of: find.byType(ListView),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'planner carries immutable UI material scope outside model input',
    () async {
      final allowed = <int>{7};
      final result = await ClusterPlanningService().build(
        studio: _snapshot().studio,
        printers: const [],
        fleet: const {},
        allowedConsumableIds: allowed,
        channelAvailableGrams: const {},
        activeQueueCounts: const {},
      );
      allowed.clear();
      expect(result.visibleConsumableIds, {7});
      expect(() => result.visibleConsumableIds.add(8), throwsUnsupportedError);
      expect(
        result.toModelInput().containsKey('visibleConsumableIds'),
        isFalse,
      );
    },
  );

  testWidgets('centered device dossier shows observed facts without scores', (
    tester,
  ) async {
    await _open(tester, _snapshot());
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('精细一号'), findsOneWidget);
    expect(find.text('2 盘次'), findsOneWidget);
    expect(find.text('待核对'), findsOneWidget);
    expect(find.textContaining('secret-printer-serial'), findsNothing);
    await tester.tap(find.text('评分档案'));
    await tester.pumpAndSettle();
    expect(find.text('待评估'), findsWidgets);
    expect(find.text('运行可靠性'), findsOneWidget);
    expect(find.textContaining('95'), findsNothing);
    await tester.tap(find.text('维护与证据'));
    await tester.pumpAndSettle();
    expect(find.text('尚未接入'), findsOneWidget);
    expect(find.text('解除维修锁'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'material scope denies foreign name color weight and hold state',
    (tester) async {
      await _open(tester, _snapshot(allowMaterial: false, grams: 487.6));
      await _scrollTo(tester, '材料资料不在当前范围');
      expect(find.textContaining('专用测试品牌'), findsNothing);
      expect(find.text('测试绿'), findsNothing);
      expect(find.textContaining('487.6'), findsNothing);
      expect(find.text('耗材暂取'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'candidate details separate upper limit from permission to start',
    (tester) async {
      final snapshot = _snapshot();
      final plan = ClusterPlatePlan(
        plate: StudioProductionPlate(
          id: 'plate',
          workspaceId: snapshot.studio.workspace.id,
          orderId: 'order',
          packageId: 'package',
          plateIndex: 1,
          name: '底板',
          requiredRuns: 4,
          estimatedSeconds: 3600,
          estimatedGrams: 50,
          createdAt: snapshot.generatedAt,
        ),
        remainingRuns: 4,
        assignedRuns: 0,
        completedRuns: 0,
        candidates: const [
          ClusterPrinterCandidate(
            printerId: 1,
            printerSerial: 'secret-printer-serial',
            printerName: '精细一号',
            maxRuns: 2,
            materialMatches: [],
            queuedRuns: 2,
            availableAfterSeconds: null,
          ),
        ],
        blockers: const [],
        rejections: const {},
      );
      await _open(tester, snapshot, plan: plan);
      await _scrollTo(tester, '通过当前候选检查');
      expect(find.text('可排上限'), findsOneWidget);
      expect(find.text('检查并排产'), findsNothing);
      expect(find.textContaining('候选检查不等于已开打'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'authorized material retains 30g and supply hold is not machine repair',
    (tester) async {
      await _open(tester, _snapshot());
      await _scrollTo(tester, '耗材暂取');
      expect(find.text('专用测试品牌 · PETG'), findsOneWidget);
      expect(find.text('测试绿'), findsOneWidget);
      expect(find.text('30.0 g'), findsOneWidget);
      expect(find.text('整机维修中'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid historical weight remains visible without a false full bar',
    (tester) async {
      await _open(
        tester,
        _snapshot(grams: 1200, hold: ChannelRollHoldState.loaded),
      );
      await _scrollTo(tester, '余量异常 · 待核对');
      expect(find.text('1200.0 g'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('30g threshold is strict and the stored balance is retained', (
    tester,
  ) async {
    await _open(tester, _snapshot(hold: ChannelRollHoldState.loaded));
    await _scrollTo(tester, '余量不足以继续使用');
    expect(find.text('30.0 g'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark narrow dialog supports long names and enlarged text', (
    tester,
  ) async {
    await _open(
      tester,
      _snapshot(name: '这是一个很长的打印机名称用于检查窄窗口布局和文字放大'),
      brightness: Brightness.dark,
      size: const Size(360, 700),
      scale: 1.7,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('评分档案'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('维护与证据'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
}
