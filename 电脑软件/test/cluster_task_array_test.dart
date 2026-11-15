import 'package:consumable_tracker_desktop/core/services/cluster_planning_service.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_task_array.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ClusterPlanningSnapshot taskArrayFixture({
  bool empty = false,
  bool invalidCounts = false,
  bool longNames = false,
}) {
  final time = DateTime(2026, 11, 11);
  final order = StudioOrder(
    id: 'order',
    workspaceId: 'workspace',
    orderNo: 'TASK-01',
    title: longNames ? '这是用于验证窄屏与文字放大的超长多盘生产任务名称' : '多盘任务',
    status: StudioOrderStatus.production,
    totalPrice: 0,
    dueAt: time.add(const Duration(days: 1, hours: 18)),
    createdAt: time,
    updatedAt: time,
  );
  final package = StudioProductionPackage(
    id: 'package',
    workspaceId: 'workspace',
    orderId: order.id,
    sourceName: 'production.3mf',
    artifactKind: 'bambu3mf',
    createdAt: time,
  );
  final plans = List.generate(
    3,
    (index) => ClusterPlatePlan(
      plate: StudioProductionPlate(
        id: 'plate-$index',
        workspaceId: 'workspace',
        orderId: order.id,
        packageId: package.id,
        plateIndex: index + 1,
        name: longNames
            ? '超长打印盘名称用于验证省略与自动换行表现$index'
            : ['外壳', '底板', '连接件'][index],
        requiredRuns: 4,
        estimatedSeconds: 3600,
        estimatedGrams: 50,
        createdAt: time,
      ),
      remainingRuns: index == 0 ? (invalidCounts ? 8 : 4) : 0,
      assignedRuns: index == 1 ? 2 : 0,
      completedRuns: index == 0 ? 0 : (index == 1 ? 1 : 4),
      candidates: const [],
      blockers: index == 0 ? const ['耗材不足'] : const [],
      rejections: const {},
    ),
  );
  return ClusterPlanningSnapshot(
    studio: StudioSnapshot(
      workspace: StudioWorkspace(
        id: 'workspace',
        name: 'test',
        createdAt: time,
        updatedAt: time,
      ),
      members: const [],
      customers: const [],
      orders: empty ? [] : [order],
      workOrders: const [],
      quotes: const [],
      inventoryEvents: const [],
      inventoryBatches: const [],
      shareLinks: const [],
    ),
    tasks: empty
        ? []
        : [
            ClusterTaskGroup(
              order: order,
              packages: [ClusterPackageGroup(package: package, plates: plans)],
            ),
          ],
    printers: const [],
    generatedAt: time,
  );
}

Future<void> pumpTaskArray(
  WidgetTester tester, {
  ClusterPlanningSnapshot? snapshot,
  ValueChanged<ClusterPlatePlan>? onSelect,
  String? selectedPlateId,
  double width = 460,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: ClusterTaskArray(
            snapshot: snapshot ?? taskArrayFixture(),
            selectedPlateId: selectedPlateId,
            onSelectPlate: onSelect,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'shows package, plate counts, unclassified runs and honest completion',
    (tester) async {
      await pumpTaskArray(tester);
      expect(find.text('任务阵列'), findsOneWidget);
      expect(find.text('多盘任务'), findsOneWidget);
      expect(find.text('production.3mf'), findsOneWidget);
      expect(find.text('P01  外壳'), findsOneWidget);
      expect(find.text('P02  底板'), findsOneWidget);
      expect(find.text('3 盘 · 需求 12 次'), findsOneWidget);
      expect(find.text('未归类 1'), findsOneWidget);
      expect(find.text('技术完成 1'), findsOneWidget);
      final progressSegments = find.descendant(
        of: find.byKey(const ValueKey('cluster-plate-progress-plate-1')),
        matching: find.byType(ColoredBox),
      );
      expect(progressSegments, findsNWidgets(3));
      for (final segment in progressSegments.evaluate()) {
        expect(tester.getSize(find.byWidget(segment.widget)).height, 5);
      }
      expect(find.byTooltip('技术完成 ≠ 质检通过或交付'), findsOneWidget);
      expect(find.text('交期 11/12 18:00'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selection only calls the supplied plate callback', (
    tester,
  ) async {
    final selected = <String>[];
    await pumpTaskArray(
      tester,
      onSelect: (plan) => selected.add(plan.plate.id),
    );
    await tester.tap(find.text('P02  底板'));
    await tester.pumpAndSettle();
    expect(selected, ['plate-1']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search supports plate names and differs from a truly empty workspace',
    (tester) async {
      await pumpTaskArray(tester);
      await tester.enterText(find.byType(TextField), '底板');
      await tester.pumpAndSettle();
      expect(find.text('P02  底板'), findsOneWidget);
      expect(find.text('P01  外壳'), findsNothing);
      await tester.enterText(find.byType(TextField), 'no-such-plate');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的打印盘'), findsOneWidget);
      expect(find.text('暂无任务'), findsNothing);
      await tester.tap(find.text('清除筛选'));
      await tester.pumpAndSettle();
      expect(find.text('P01  外壳'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('blocked and assigned filters use real counts and blockers', (
    tester,
  ) async {
    await pumpTaskArray(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, '受阻'));
    await tester.pumpAndSettle();
    expect(find.text('P01  外壳'), findsOneWidget);
    expect(find.text('受阻 · 耗材不足'), findsOneWidget);
    expect(find.text('P02  底板'), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, '已安排'));
    await tester.pumpAndSettle();
    expect(find.text('P01  外壳'), findsNothing);
    expect(find.text('P02  底板'), findsOneWidget);
    expect(find.text('已安排 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapsed tasks expand during search without losing selection', (
    tester,
  ) async {
    await pumpTaskArray(tester, selectedPlateId: 'plate-0');
    await tester.tap(find.text('多盘任务'));
    await tester.pumpAndSettle();
    expect(find.text('P01  外壳'), findsNothing);
    await tester.enterText(find.byType(TextField), '外壳');
    await tester.pumpAndSettle();
    expect(find.text('P01  外壳'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid ledger stays visible and does not fabricate progress', (
    tester,
  ) async {
    await pumpTaskArray(
      tester,
      snapshot: taskArrayFixture(invalidCounts: true),
    );
    expect(find.text('待安排 8'), findsOneWidget);
    expect(find.text('所需 4'), findsWidgets);
    expect(find.text('盘次需核对'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty workspace and narrow dark scaled type have no overflow', (
    tester,
  ) async {
    await pumpTaskArray(tester, snapshot: taskArrayFixture(empty: true));
    expect(find.text('暂无任务'), findsOneWidget);
    expect(find.text('没有匹配的打印盘'), findsNothing);
    await pumpTaskArray(
      tester,
      snapshot: taskArrayFixture(longNames: true),
      width: 260,
      scale: 1.8,
      brightness: Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
