import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/core/theme/interaction_effects.dart';
import 'package:consumable_tracker_desktop/core/theme/personal_desktop_theme.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_screen.dart';
import 'package:consumable_tracker_desktop/providers/cluster_provider.dart';
import 'package:consumable_tracker_desktop/providers/mifu_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'cluster_screen_test.dart' as existing;

const _captureKey = ValueKey('mifu-fixture-preview');
const _captureEnabled = bool.fromEnvironment('MIFU_CAPTURE');

ClusterPlanningSnapshot _mixedFixture() {
  final base = existing.fixture();
  final sources = existing.fixture(candidateCount: 6).printers;
  final now = DateTime.now();
  final states = [
    BambuGcodeState.idle,
    BambuGcodeState.idle,
    BambuGcodeState.running,
    null,
    BambuGcodeState.pause,
    BambuGcodeState.failed,
  ];
  return ClusterPlanningSnapshot(
    studio: base.studio,
    tasks: [
      for (final task in base.tasks)
        ClusterTaskGroup(
          order: task.order,
          packages: [
            for (final package in task.packages)
              ClusterPackageGroup(
                package: package.package,
                plates: [
                  for (final plan in package.plates)
                    ClusterPlatePlan(
                      plate: plan.plate,
                      remainingRuns: plan.remainingRuns,
                      assignedRuns: plan.assignedRuns,
                      completedRuns: plan.completedRuns,
                      blockers: plan.blockers,
                      rejections: plan.rejections,
                      candidates: [
                        for (final candidate in plan.candidates)
                          ClusterPrinterCandidate(
                            printerId: candidate.printerId,
                            printerSerial: candidate.printerSerial,
                            printerName: candidate.printerName,
                            maxRuns: candidate.maxRuns,
                            materialMatches: candidate.materialMatches,
                            queuedRuns: candidate.printerId == 1 ? 3 : 0,
                            availableAfterSeconds: candidate.printerId == 1
                                ? 7200
                                : 0,
                          ),
                      ],
                    ),
                ],
              ),
          ],
        ),
    ],
    printers: [
      for (var index = 0; index < sources.length; index++)
        ClusterPrinter(
          source: sources[index].source,
          state: states[index] == null
              ? null
              : FleetPrinterState(
                  serial: sources[index].serial!,
                  displayLabel: sources[index].name,
                  connectionState: PrinterConnectionState.connected,
                  lastStatus: BambuPrinterStatus(
                    serial: sources[index].serial!,
                    gcodeState: states[index],
                    mcPercent: states[index] == BambuGcodeState.running
                        ? 42
                        : null,
                    mcRemainingTime: states[index] == BambuGcodeState.running
                        ? 35
                        : null,
                  ),
                  statusUpdatedAt: now,
                  isLanCapable: true,
                  mode: BambuConnectionMode.lan,
                  reportedModel: 'P1S',
                  installedNozzleDiameter: .4,
                  isConnecting: false,
                ),
          activeQueueCount: index == 0 ? 3 : (index == 2 ? 1 : 0),
          availableAfterSeconds: index == 0
              ? 7200
              : (index == 1 ? 0 : (index == 2 ? 2100 : null)),
          blockers: index >= 3 ? const ['设备状态需要核对'] : const [],
        ),
    ],
    generatedAt: now,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  Size size = const Size(1700, 1050),
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool capture = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final theme = buildPersonalDesktopTheme(
    brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
    personalProduct: true,
    studioMode: false,
  );
  final client = MifuClient(
    client: MockClient((request) async {
      if (request.url.path == '/v1/decisions') {
        final body = jsonDecode(request.body) as Map;
        return http.Response(
          jsonEncode({
            'requestId': body['requestId'],
            'trainingState': 'ready',
            'choice': '2',
            'probabilities': {'1': .32, '2': .68},
            'elapsedMs': 8,
            'model': {
              'name': 'Mifu',
              'version': 'mifu-fixture-v1',
              'checkpointConfigured': true,
            },
          }),
          200,
        );
      }
      return http.Response('{"error":{"message":"fixture only"}}', 503);
    }),
  );
  addTearDown(client.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clusterPlanningSnapshotProvider.overrideWith(
          (_) async => _mixedFixture(),
        ),
        mifuHealthProvider.overrideWith(
          (_) => Stream.value(
            capture
                ? const MifuHealth(
                    trainingState: 'ready',
                    version: 'mifu-fixture-v1',
                  )
                : const MifuHealth(trainingState: 'unconfigured'),
          ),
        ),
        mifuClientProvider.overrideWith((_) => client),
      ],
      child: InteractionEffectsScope(
        enabled: false,
        child: RepaintBoundary(
          key: _captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  if (capture)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      color: theme.colorScheme.primaryContainer,
                      child: Text(
                        '演示数据 · 实际 Flutter 界面预览 · 设备与模型输出均为隔离测试数据，未连接打印机',
                        style: TextStyle(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  const Expanded(child: ClusterScreen()),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _fonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final font = await File(
      r'C:\Windows\Fonts\HarmonyOS_Sans_SC_Regular.ttf',
    ).readAsBytes();
    for (final family in [
      AppTypography.chineseFontFamily,
      'HarmonyOS Sans',
      'Microsoft YaHei UI',
      'Roboto',
      'Ahem',
      AppTypography.monoFontFamily,
    ]) {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(font)))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
}

void main() {
  testWidgets(
    'device card icon opens centered score and maintenance evidence tabs',
    (tester) async {
      await _pump(tester);
      expect(
        tester
            .renderObject<RenderParagraph>(find.text('全部'))
            .text
            .style
            ?.fontFamily,
        AppTypography.chineseFontFamily,
      );
      await tester.tap(find.byTooltip('查看设备 1档案'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '评分档案'));
      await tester.pumpAndSettle();
      expect(find.text('设备综合分'), findsOneWidget);
      expect(find.text('待评估'), findsWidgets);
      expect(find.textContaining('尚未接入设备评分'), findsOneWidget);
      expect(find.text('95'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, '维护与证据'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未接入'), findsWidgets);
      expect(find.textContaining('private-serial'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'attention filtering excludes known idle devices without changing candidates',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.text('P01  外壳'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '需处理'));
      await tester.pumpAndSettle();
      expect(find.text('3 / 6 台 · 名称视图'), findsOneWidget);
      expect(find.byTooltip('查看设备 1档案'), findsNothing);
      expect(find.byTooltip('查看设备 4档案'), findsOneWidget);
      expect(find.text('候选设备'), findsOneWidget);
      // The center still contains the two candidates; a visibility filter is not
      // permission to silently shrink the model's candidate set.
      expect(find.text('设备 1'), findsOneWidget);
      expect(find.text('设备 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('queue sort changes visible device order', (tester) async {
    await _pump(tester);
    final before1 = tester.getTopLeft(find.byTooltip('查看设备 1档案'));
    final before2 = tester.getTopLeft(find.byTooltip('查看设备 2档案'));
    expect(before1.dx < before2.dx || before1.dy < before2.dy, isTrue);
    await tester.tap(find.byTooltip('设备排序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按队列数量'));
    await tester.pumpAndSettle();
    final after2 = tester.getTopLeft(find.byTooltip('查看设备 2档案'));
    final after4 = tester.getTopLeft(find.byTooltip('查看设备 4档案'));
    expect(after2.dx < after4.dx || after2.dy < after4.dy, isTrue);
    final after1 = tester.getTopLeft(find.byTooltip('查看设备 1档案'));
    expect(after1.dy, greaterThan(after2.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'model dialog distinguishes local status from the unconnected training node',
    (tester) async {
      await _pump(tester);
      await tester.tap(find.byTooltip('查看模型与训练节点'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('模型与计算节点'), findsOneWidget);
      expect(find.text('远程训练节点'), findsOneWidget);
      expect(find.textContaining('不代表远端 4070'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.textContaining('规则方案'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('360px dark workspace with large text scrolls without overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(360, 900),
      scale: 1.5,
      brightness: Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('查看模型与训练节点'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilterChip, '需处理'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(FilterChip, '需处理'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('查看设备 4档案'));
    await tester.tap(find.byTooltip('查看设备 4档案'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      '360px ${brightness.name} Mifu panel keeps candidates and results reachable with large text',
      (tester) async {
        await _pump(
          tester,
          size: const Size(360, 900),
          scale: 1.5,
          brightness: brightness,
        );
        final taskList = find.byKey(const PageStorageKey('cluster-task-array'));
        await tester.ensureVisible(taskList);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('P01  外壳'),
          100,
          scrollable: find
              .descendant(of: taskList, matching: find.byType(Scrollable))
              .first,
        );
        await tester.pumpAndSettle();
        // Build the lazy row first, then center it in both nested viewports.
        await Scrollable.ensureVisible(
          tester.element(find.text('P01  外壳')),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        expect(find.text('P01  外壳').hitTestable(), findsOneWidget);
        await tester.tap(find.text('P01  外壳'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final panel = find.byKey(const ValueKey('mifu-decision-panel'));
        final scrollable = find
            .descendant(
              of: find.byKey(const ValueKey('mifu-decision-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        final candidate = find.descendant(
          of: panel,
          matching: find.text('设备 2'),
        );
        await tester.ensureVisible(panel);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(candidate, 100, scrollable: scrollable);
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(
          tester.element(candidate),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        expect(candidate.hitTestable(), findsOneWidget);
        await tester.tap(candidate);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final results = find.descendant(of: panel, matching: find.text('打印结果'));
        await tester.scrollUntilVisible(results, 100, scrollable: scrollable);
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(tester.element(results), alignment: .5);
        await tester.pumpAndSettle();
        expect(results.hitTestable(), findsOneWidget);
        await tester.tap(results);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('打印结果 · P1 · 外壳'), findsOneWidget);
        expect(find.text('fixture only'), findsOneWidget);
        expect(find.byType(BottomSheet), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('关闭'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }

  if (_captureEnabled) {
    for (final mode in Brightness.values) {
      testWidgets('capture ${mode.name} fixture preview', (tester) async {
        await _fonts(tester);
        await _pump(
          tester,
          capture: true,
          brightness: mode,
          size: const Size(1800, 1120),
        );
        await tester.tap(find.text('P01  外壳'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, '重新决策'));
        await tester.pumpAndSettle();
        expect(find.text('68.0%'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_captureKey),
        );
        await tester.runAsync(() async {
          final rendered = await boundary.toImage(pixelRatio: 1.5);
          try {
            final png = await rendered.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final folder = Directory('../output/mifu-ui');
            await folder.create(recursive: true);
            await File(
              '${folder.path}/cluster-mifu-wordmark-${mode.name}-fixture-preview.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          } finally {
            rendered.dispose();
          }
        });
      });
    }
  }
}
