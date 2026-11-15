import 'dart:async';
import 'dart:convert';

import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/data/database/daos/printer_dao.dart';
import 'package:consumable_tracker_desktop/data/database/database.dart';
import 'package:consumable_tracker_desktop/data/database/models/studio_models.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_screen.dart';
import 'package:consumable_tracker_desktop/widgets/mifu_wordmark.dart';
import 'package:consumable_tracker_desktop/providers/cluster_provider.dart';
import 'package:consumable_tracker_desktop/providers/mifu_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

ClusterPlanningSnapshot fixture({
  bool empty = false,
  int candidateCount = 2,
  String? artifactSha256,
}) {
  final time = DateTime(2026, 11, 11);
  final order = StudioOrder(
    id: 'order-1',
    workspaceId: 'test',
    orderNo: 'TASK-01',
    title: '多盘任务',
    status: StudioOrderStatus.production,
    totalPrice: 0,
    createdAt: time,
    updatedAt: time,
  );
  final package = StudioProductionPackage(
    id: 'package-1',
    workspaceId: 'test',
    orderId: order.id,
    sourceName: 'fixture.3mf',
    artifactKind: 'bambu3mf',
    createdAt: time,
  );
  final plans = List.generate(
    2,
    (index) => ClusterPlatePlan(
      plate: StudioProductionPlate(
        id: 'plate-$index',
        workspaceId: 'test',
        orderId: order.id,
        packageId: package.id,
        plateIndex: index + 1,
        name: index == 0 ? '外壳' : '底板',
        requiredRuns: 3,
        estimatedSeconds: 3600,
        estimatedGrams: 50,
        sliceArtifactSha256: artifactSha256,
        createdAt: time,
      ),
      remainingRuns: 3,
      assignedRuns: 0,
      completedRuns: 0,
      blockers: const [],
      rejections: const {},
      candidates: List.generate(
        candidateCount,
        (i) => ClusterPrinterCandidate(
          printerId: i + 1,
          printerSerial: 'private-serial-$i',
          printerName: '设备 ${i + 1}',
          maxRuns: 3,
          materialMatches: const [],
          queuedRuns: 0,
          availableAfterSeconds: 0,
        ),
      ),
    ),
  );
  return ClusterPlanningSnapshot(
    studio: StudioSnapshot(
      workspace: StudioWorkspace(
        id: 'test',
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
      productionPackages: empty ? [] : [package],
      productionPlates: empty ? [] : plans.map((p) => p.plate).toList(),
    ),
    tasks: empty
        ? []
        : [
            ClusterTaskGroup(
              order: order,
              packages: [ClusterPackageGroup(package: package, plates: plans)],
            ),
          ],
    printers: empty
        ? []
        : List.generate(
            candidateCount,
            (i) => ClusterPrinter(
              source: PrinterWithChannels(
                Printer(
                  id: i + 1,
                  uid: 'p$i',
                  name: '设备 ${i + 1}',
                  brand: 'Bambu',
                  model: 'P1S',
                  channelCount: 4,
                  isCustomImage: false,
                  createdAt: time,
                  updatedAt: time,
                ),
                [],
                serial: 'private-serial-$i',
              ),
              state: null,
              activeQueueCount: 0,
              availableAfterSeconds: 0,
              blockers: const [],
            ),
          ),
    generatedAt: time,
  );
}

Future<void> pumpCluster(
  WidgetTester tester, {
  required ClusterPlanningSnapshot snapshot,
  Size size = const Size(1500, 1000),
  MifuHealth health = const MifuHealth(trainingState: 'unconfigured'),
  MifuClient? client,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clusterPlanningSnapshotProvider.overrideWith((_) async => snapshot),
        mifuHealthProvider.overrideWith((_) => Stream.value(health)),
        if (client != null) mifuClientProvider.overrideWith((_) => client),
      ],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: const Scaffold(body: ClusterScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('uses real empty state; never shows demo numbers or scores', (
    tester,
  ) async {
    await pumpCluster(tester, snapshot: fixture(empty: true));
    expect(find.text('暂无任务'), findsOneWidget);
    expect(find.text('没有设备'), findsOneWidget);
    expect(find.byType(MifuWordmark), findsOneWidget);
    expect(find.text('待训练'), findsNWidgets(2));
    expect(find.textContaining('规则方案'), findsNothing);
    expect(find.textContaining('24'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one task expands multiple plates and centered explanation', (
    tester,
  ) async {
    await pumpCluster(tester, snapshot: fixture());
    expect(find.text('多盘任务'), findsOneWidget);
    expect(find.text('P01  外壳'), findsOneWidget);
    expect(find.text('P02  底板'), findsOneWidget);
    await tester.tap(find.text('P02  底板'));
    await tester.pumpAndSettle();
    expect(find.text('P02 · 底板'), findsOneWidget);
    expect(find.text('候选设备'), findsOneWidget);
    final infer = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '重新决策'),
    );
    expect(infer.onPressed, isNull);
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'renders only validated model probabilities and records feedback without printing',
    (tester) async {
      var decisions = 0;
      var records = 0;
      final client = MifuClient(
        client: MockClient((sent) async {
          final body = jsonDecode(sent.body) as Map;
          if (sent.url.path == '/v1/decisions') {
            decisions++;
            expect(body['plate']['id'], 'plate-0');
            expect(body['plate']['taskId'], 'order-1');
            expect(sent.body.contains('private-serial'), isFalse);
            return http.Response(
              jsonEncode({
                'requestId': body['requestId'],
                'trainingState': 'ready',
                'choice': '2',
                'probabilities': {'1': .2, '2': .8},
                'elapsedMs': 7,
                'model': {
                  'name': 'Mifu',
                  'version': 'mifu-test',
                  'checkpointConfigured': true,
                },
              }),
              200,
            );
          }
          expect(sent.url.path, '/v1/records');
          records++;
          expect(body['feedback'], 'accepted');
          expect(body['selectedCandidateId'], '2');
          return http.Response(
            '{"recordId":"r1","trainingEligible":false}',
            201,
          );
        }),
      );
      addTearDown(client.close);
      await pumpCluster(
        tester,
        snapshot: fixture(),
        client: client,
        health: const MifuHealth(
          trainingState: 'ready',
          version: 'mifu-test',
          device: 'cpu',
        ),
      );
      await tester.tap(find.text('P01  外壳'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新决策'));
      await tester.pumpAndSettle();
      expect(decisions, 1);
      expect(find.text('80.0%'), findsOneWidget);
      expect(find.text('模型偏好概率'), findsOneWidget);
      await tester.tap(find.text('记录选择'));
      await tester.pumpAndSettle();
      expect(records, 1);
      expect(find.text('已记录'), findsOneWidget);
      await tester.tap(find.text('P02  底板'));
      await tester.pumpAndSettle();
      expect(find.text('80.0%'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'feedback for A never marks B as recorded after switching device',
    (tester) async {
      final pending = Completer<http.Response>();
      final client = MifuClient(
        client: MockClient((sent) async {
          expect(sent.url.path, '/v1/records');
          expect((jsonDecode(sent.body) as Map)['selectedCandidateId'], '1');
          return pending.future;
        }),
      );
      addTearDown(client.close);
      await pumpCluster(tester, snapshot: fixture(), client: client);
      await tester.tap(find.text('P01  外壳'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设备 1').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('记录选择'));
      await tester.pump();
      await tester.tap(find.text('设备 2').first);
      await tester.pump();
      pending.complete(
        http.Response('{"recordId":"r1","trainingEligible":false}', 201),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前选择 · 设备 2'), findsOneWidget);
      expect(find.text('已记录'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '记录选择'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late inference result cannot replace a different selected plate',
    (tester) async {
      final pending = Completer<http.Response>();
      String? requestId;
      final client = MifuClient(
        client: MockClient((sent) async {
          requestId = (jsonDecode(sent.body) as Map)['requestId'] as String;
          return pending.future;
        }),
      );
      addTearDown(client.close);
      await pumpCluster(
        tester,
        snapshot: fixture(),
        client: client,
        health: const MifuHealth(trainingState: 'ready', version: 'mifu-test'),
      );
      await tester.tap(find.text('P01  外壳'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新决策'));
      await tester.pump();
      await tester.tap(find.text('P02  底板'));
      await tester.pump();
      pending.complete(
        http.Response(
          jsonEncode({
            'requestId': requestId,
            'trainingState': 'ready',
            'choice': '2',
            'probabilities': {'1': .2, '2': .8},
            'elapsedMs': 7,
            'model': {
              'name': 'Mifu',
              'version': 'mifu-test',
              'checkpointConfigured': true,
            },
          }),
          200,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('P02 · 底板'), findsOneWidget);
      expect(find.text('80.0%'), findsNothing);
      expect(find.text('模型偏好概率'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inference result preserves a manual device choice made while pending',
    (tester) async {
      final pending = Completer<http.Response>();
      String? requestId;
      final client = MifuClient(
        client: MockClient((sent) async {
          expect(sent.url.path, '/v1/decisions');
          requestId = (jsonDecode(sent.body) as Map)['requestId'] as String;
          return pending.future;
        }),
      );
      addTearDown(client.close);
      await pumpCluster(
        tester,
        snapshot: fixture(),
        client: client,
        health: const MifuHealth(trainingState: 'ready', version: 'mifu-test'),
      );
      await tester.tap(find.text('P01  外壳'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新决策'));
      await tester.pump();
      expect(requestId, isNotNull);
      await tester.tap(find.text('设备 1').first);
      await tester.pump();
      expect(find.text('当前选择 · 设备 1'), findsOneWidget);
      pending.complete(
        http.Response(
          jsonEncode({
            'requestId': requestId,
            'trainingState': 'ready',
            'choice': '2',
            'probabilities': {'1': .2, '2': .8},
            'elapsedMs': 7,
            'model': {
              'name': 'Mifu',
              'version': 'mifu-test',
              'checkpointConfigured': true,
            },
          }),
          200,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('模型偏好概率'), findsOneWidget);
      expect(find.text('80.0%'), findsOneWidget);
      expect(find.text('当前选择 · 设备 1'), findsOneWidget);
      expect(find.text('当前选择 · 设备 2'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown telemetry hides zero waiting estimate in card and device dossier',
    (tester) async {
      final snapshot = fixture();
      expect(snapshot.printers.first.state, isNull);
      expect(snapshot.printers.first.availableAfterSeconds, 0);
      await pumpCluster(tester, snapshot: snapshot);
      expect(find.text('机器等待未知'), findsNWidgets(2));
      expect(find.text('机器等待 0 分'), findsNothing);
      await tester.tap(find.byTooltip('查看设备 1档案'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('待核对'),
        ),
        findsOneWidget,
      );
      expect(find.text('无已知机器等待'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('responsive ${brightness.name} layout has no overflow', (
      tester,
    ) async {
      await pumpCluster(
        tester,
        snapshot: fixture(),
        size: const Size(800, 700),
        brightness: brightness,
      );
      await tester.tap(find.text('P01  外壳'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('more than 16 candidates never silently truncates inference', (
    tester,
  ) async {
    await pumpCluster(
      tester,
      snapshot: fixture(candidateCount: 17),
      health: const MifuHealth(trainingState: 'ready', version: 'mifu-test'),
    );
    await tester.tap(find.text('P01  外壳'));
    await tester.pumpAndSettle();
    final infer = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '重新决策'),
    );
    expect(infer.onPressed, isNull);
    expect(find.textContaining('候选超过 16 台'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
