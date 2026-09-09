import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:consumable_tracker_desktop/data/external/slicer/production_package_inspector.dart';
import 'package:consumable_tracker_desktop/features/studio/farm_work_order_dialog.dart';
import 'package:consumable_tracker_desktop/providers/farm_slice_intake_provider.dart';
import 'package:consumable_tracker_desktop/providers/printer_provider.dart';

void main() {
  testWidgets('手动新建工单先显示文件区，未添加文件时不能进入详情', (tester) async {
    await _pumpLauncher(tester);

    await tester.tap(find.text('打开新建工单'));
    await tester.pumpAndSettle();

    expect(find.text('新建生产工单'), findsOneWidget);
    expect(find.text('0 / 5 个打印文件'), findsOneWidget);
    expect(find.text('把源 3MF 拖到这里，或点击选择'), findsOneWidget);
    expect(find.textContaining('关联用户'), findsNothing);

    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '新建工单'),
    );
    expect(next.onPressed, isNull);
  });

  testWidgets('自动识别入口最多接收五个打印包并直接进入订单信息', (tester) async {
    final inspections = [
      for (var index = 1; index <= 6; index++) _inspection(index),
    ];
    await _pumpLauncher(tester, inspections: inspections);

    await tester.tap(find.text('打开新建工单'));
    await tester.pumpAndSettle();

    expect(find.text('5 / 5 个打印文件'), findsOneWidget);
    expect(find.text('订单信息'), findsOneWidget);
    expect(find.text('生产清单与设备'), findsOneWidget);
    expect(find.textContaining('关联用户'), findsNothing);

    final addMore = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '继续添加'),
    );
    expect(addMore.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未切片单盘项目默认勾选该盘，也允许先建单后切片', (tester) async {
    await _pumpLauncher(tester, inspections: [_sourceInspection()]);

    await tester.tap(find.text('打开新建工单'));
    await tester.pumpAndSettle();

    expect(find.text('切片已选 1 盘'), findsOneWidget);
    expect(find.text('用 Bambu Studio 打开'), findsOneWidget);
    expect(find.textContaining('1 盘待切'), findsOneWidget);
    expect(find.textContaining('外壳 × 2'), findsOneWidget);
    expect(find.textContaining('底座 × 1'), findsOneWidget);
    expect(find.textContaining('待切片'), findsWidgets);
    expect(find.text('订单信息'), findsNothing);

    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '新建工单'),
    );
    expect(next.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多盘项目逐盘展示原始对象名并允许只选择一盘先切', (tester) async {
    await _pumpLauncher(tester, inspections: [_multiPlateSourceInspection()]);

    await tester.tap(find.text('打开新建工单'));
    await tester.pumpAndSettle();

    expect(find.textContaining('第 1 盘 · 外壳盘'), findsOneWidget);
    expect(find.textContaining('第 2 盘 · 底座盘'), findsOneWidget);
    expect(find.text('外壳 × 2'), findsOneWidget);
    expect(find.text('底座 × 1'), findsOneWidget);
    expect(find.text('请先勾选要切的盘'), findsOneWidget);

    final checkboxes = find.byType(Checkbox);
    expect(checkboxes, findsNWidgets(2));
    await tester.tap(checkboxes.first);
    await tester.pumpAndSettle();

    expect(find.text('切片已选 1 盘'), findsOneWidget);
    expect(find.textContaining('对象 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多盘项目设置两套时同步计算每盘运行数量', (tester) async {
    await _pumpLauncher(tester, inspections: [_multiPlateSourceInspection()]);
    await tester.tap(find.text('打开新建工单'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '新建工单'));
    await tester.pumpAndSettle();
    expect(find.text('生产清单与设备'), findsOneWidget);

    final copiesField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '整套份数',
    );
    await tester.enterText(copiesField, '2');
    await tester.pumpAndSettle();

    final quantityFields = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '订单数量',
    );
    final quantities = tester
        .widgetList<TextField>(quantityFields)
        .map((field) => field.controller!.text)
        .toList();
    expect(quantities, containsAll(['4', '2']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Bambu 切片输出按源工程路径自动补回当前工单', (tester) async {
    await _pumpLauncher(tester, inspections: [_sourceInspection()]);
    await tester.tap(find.text('打开新建工单'));
    await tester.pumpAndSettle();

    final context = tester.element(find.text('新建生产工单'));
    final container = ProviderScope.containerOf(context);
    container
        .read(farmSliceIntakeProvider.notifier)
        .submit(_slicedOutputInspection());
    await tester.pump(const Duration(milliseconds: 2300));
    await tester.pumpAndSettle();

    expect(find.textContaining('切片已选'), findsNothing);
    final next = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '新建工单'),
    );
    expect(next.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多盘项目只关联已切盘并继续保留其他盘', (tester) async {
    await _pumpLauncher(tester, inspections: [_multiPlateSourceInspection()]);
    await tester.tap(find.text('打开新建工单'));
    await tester.pumpAndSettle();

    final context = tester.element(find.text('新建生产工单'));
    final container = ProviderScope.containerOf(context);
    container
        .read(farmSliceIntakeProvider.notifier)
        .submit(_partialMultiPlateOutputInspection());
    await tester.pump(const Duration(milliseconds: 2300));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 已切 / 1 待切'), findsOneWidget);
    expect(find.textContaining('第 2 盘 · 底座盘'), findsOneWidget);
    expect(find.text('请先勾选要切的盘'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpLauncher(
  WidgetTester tester, {
  List<ProductionPackageInspection> inspections = const [],
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        printersWithChannelsProvider.overrideWith(
          (ref) => Stream.value(const []),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => unawaited(
                showFarmWorkOrderDialog(
                  context,
                  initialInspections: inspections,
                ),
              ),
              child: const Text('打开新建工单'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ProductionPackageInspection _inspection(int index) {
  return ProductionPackageInspection(
    artifactPath: 'C:/fixtures/order-$index.3mf',
    displayName: '订单文件 $index',
    kind: ProductionArtifactKind.bambu3mf,
    isSliced: true,
    requiresReview: false,
    plates: [
      const ProductionPlateInspection(
        plateIndex: 1,
        name: '第 1 盘',
        hasToolpath: true,
        estimatedSeconds: 1800,
        totalLayers: 100,
        toolChangeCount: 0,
        estimatedGrams: 20,
        parts: [
          ProductionPartInspection(
            key: 'part-1',
            name: '测试件',
            instancesPerRun: 1,
          ),
        ],
        filaments: [],
      ),
    ],
    detectedAt: DateTime(2026, 8, 3, 12),
    targetModel: 'Bambu Lab A1',
    nozzleDiameter: 0.4,
  );
}

ProductionPackageInspection _sourceInspection() {
  return ProductionPackageInspection(
    artifactPath: 'C:/fixtures/source-project.3mf',
    displayName: '源工程',
    kind: ProductionArtifactKind.bambu3mf,
    isSliced: false,
    requiresReview: true,
    plates: const [
      ProductionPlateInspection(
        plateIndex: 1,
        name: '待排版',
        hasToolpath: false,
        estimatedSeconds: 0,
        totalLayers: 0,
        toolChangeCount: 0,
        estimatedGrams: 0,
        parts: [
          ProductionPartInspection(
            key: 'shell',
            name: '外壳',
            instancesPerRun: 2,
          ),
          ProductionPartInspection(
            key: 'base',
            name: '底座',
            instancesPerRun: 1,
          ),
        ],
        filaments: [],
      ),
    ],
    detectedAt: DateTime(2026, 8, 3, 12),
    warning: '待切片',
    hasEmbeddedSettings: true,
  );
}

ProductionPackageInspection _multiPlateSourceInspection() {
  return ProductionPackageInspection(
    artifactPath: 'C:/fixtures/multi-plate-project.3mf',
    displayName: '多盘源工程',
    kind: ProductionArtifactKind.bambu3mf,
    isSliced: false,
    requiresReview: true,
    plates: const [
      ProductionPlateInspection(
        plateIndex: 1,
        name: '外壳盘',
        hasToolpath: false,
        estimatedSeconds: 0,
        totalLayers: 0,
        toolChangeCount: 0,
        estimatedGrams: 0,
        parts: [
          ProductionPartInspection(
            key: 'object:11',
            name: '外壳',
            instancesPerRun: 2,
          ),
        ],
        filaments: [],
      ),
      ProductionPlateInspection(
        plateIndex: 2,
        name: '底座盘',
        hasToolpath: false,
        estimatedSeconds: 0,
        totalLayers: 0,
        toolChangeCount: 0,
        estimatedGrams: 0,
        parts: [
          ProductionPartInspection(
            key: 'object:22',
            name: '底座',
            instancesPerRun: 1,
          ),
        ],
        filaments: [],
      ),
    ],
    detectedAt: DateTime(2026, 8, 3, 12),
    warning: '待切片',
    hasEmbeddedSettings: true,
  );
}

ProductionPackageInspection _slicedOutputInspection() {
  return ProductionPackageInspection(
    artifactPath: 'C:/temp/bamboo_model/plate_1.gcode',
    displayName: '源工程',
    kind: ProductionArtifactKind.gcode,
    isSliced: true,
    requiresReview: false,
    plates: const [
      ProductionPlateInspection(
        plateIndex: 1,
        name: '第 1 盘',
        hasToolpath: true,
        estimatedSeconds: 1200,
        totalLayers: 80,
        toolChangeCount: 0,
        estimatedGrams: 18,
        parts: [
          ProductionPartInspection(
            key: 'shell',
            name: '外壳',
            instancesPerRun: 2,
          ),
          ProductionPartInspection(
            key: 'base',
            name: '底座',
            instancesPerRun: 1,
          ),
        ],
        filaments: [],
      ),
    ],
    detectedAt: DateTime(2026, 8, 3, 12, 5),
    correlationKey: 'C:/fixtures/source-project.3mf',
    projectPath: 'C:/fixtures/source-project.3mf',
  );
}

ProductionPackageInspection _partialMultiPlateOutputInspection() {
  return ProductionPackageInspection(
    artifactPath: 'C:/temp/multi/plate_1_sliced.3mf',
    displayName: '多盘源工程',
    kind: ProductionArtifactKind.bambu3mf,
    isSliced: true,
    requiresReview: true,
    plates: const [
      ProductionPlateInspection(
        plateIndex: 1,
        name: '外壳盘',
        hasToolpath: true,
        estimatedSeconds: 1200,
        totalLayers: 80,
        toolChangeCount: 1,
        estimatedGrams: 18,
        parts: [
          ProductionPartInspection(
            key: 'object:11',
            name: '外壳',
            instancesPerRun: 2,
          ),
        ],
        filaments: [],
      ),
      ProductionPlateInspection(
        plateIndex: 2,
        name: '底座盘',
        hasToolpath: false,
        estimatedSeconds: 0,
        totalLayers: 0,
        toolChangeCount: 0,
        estimatedGrams: 0,
        parts: [
          ProductionPartInspection(
            key: 'object:22',
            name: '底座',
            instancesPerRun: 1,
          ),
        ],
        filaments: [],
      ),
    ],
    detectedAt: DateTime(2026, 8, 3, 12, 5),
    correlationKey: 'C:/fixtures/multi-plate-project.3mf',
    projectPath: 'C:/fixtures/multi-plate-project.3mf',
    hasEmbeddedSettings: true,
  );
}
