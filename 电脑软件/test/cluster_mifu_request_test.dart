import 'dart:convert';

import 'package:consumable_tracker_desktop/core/services/cluster_mifu_request.dart';
import 'package:consumable_tracker_desktop/core/services/cluster_planning_service.dart';
import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_preparation_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'cluster_screen_test.dart' as fixtures;

ClusterPlanningSnapshot liveFixture(DateTime now, {DateTime? statusAt}) {
  final source = fixtures.fixture(artifactSha256: List.filled(64, 'a').join());
  return ClusterPlanningSnapshot(
    studio: source.studio,
    tasks: source.tasks,
    generatedAt: now,
    printers: [
      for (final p in source.printers)
        ClusterPrinter(
          source: p.source,
          activeQueueCount: p.activeQueueCount,
          availableAfterSeconds: p.availableAfterSeconds,
          blockers: p.blockers,
          state: FleetPrinterState(
            serial: p.serial!,
            displayLabel: p.name,
            connectionState: PrinterConnectionState.connected,
            lastStatus: BambuPrinterStatus(
              serial: p.serial!,
              gcodeState: BambuGcodeState.idle,
            ),
            statusUpdatedAt: statusAt ?? now,
            isLanCapable: true,
            mode: BambuConnectionMode.lan,
            reportedModel: 'P1S',
            installedNozzleDiameter: .4,
            isConnecting: false,
          ),
        ),
    ],
  );
}

void main() {
  final now = DateTime.utc(2026, 11, 12, 12);
  MifuDecisionRequest build(
    ClusterPlanningSnapshot snapshot, {
    Map<int, int?> setup = const {1: 0, 2: 30},
  }) => clusterMifuRequest(
    snapshot: snapshot,
    plan: snapshot.plates.first,
    candidates: snapshot.plates.first.candidates,
    requestId: 'test-v4',
    preparationSeconds: setup,
    preparationObservedAt: now,
    now: now,
  );

  test('v4 keeps seconds, human timing provenance and exact slice binding', () {
    final request = build(liveFixture(now));
    final json = request.toJson();
    expect(json['decision_context']['source'], 'live_snapshot');
    expect(json['decision_context']['objective'], 'earliest_known_finish');
    expect(request.candidates[0]['features']['setup_seconds'], 0);
    expect(request.candidates[1]['features']['setup_seconds'], 30);
    expect(
      request.candidates[1]['features']['timing_evidence']['setup']['source'],
      'manual_estimate',
    );
    expect(request.candidates[0]['admission']['full_geometry_verified'], false);
    expect(request.plate['artifact_sha256'], List.filled(64, 'a').join());
    expect(jsonEncode(json), isNot(contains('private-serial')));
    expect(json.containsKey('observation'), false);
    expect(request.observation?['requestId'], request.requestId);
  });

  test(
    'missing preparation stays null and stale or foreign observations reject',
    () {
      expect(
        build(
          liveFixture(now),
          setup: const {},
        ).candidates.first['features']['setup_seconds'],
        isNull,
      );
      expect(
        () => build(
          liveFixture(
            now,
            statusAt: now.subtract(const Duration(seconds: 121)),
          ),
        ),
        throwsA(isA<MifuException>()),
      );
      expect(
        () => build(liveFixture(now), setup: const {3: 0}),
        throwsA(isA<MifuException>()),
      );
      expect(
        () => build(liveFixture(now), setup: const {1: -1}),
        throwsA(isA<MifuException>()),
      );
    },
  );

  test(
    'v4 preflight works without a ready model and rejects contradictory receipts',
    () async {
      final request = build(liveFixture(now));
      var contradict = false;
      final client = MifuClient(
        client: MockClient((sent) async {
          expect(sent.url.path, '/v1/decisions/check');
          expect(jsonDecode(sent.body), request.toJson());
          return http.Response(
            jsonEncode({
              'requestId': request.requestId,
              'inputContract': 'mifu-decision-v4',
              'evidenceStatus': 'passed',
              'tokenAudit': {'status': 'pending'},
              'modelReady': false,
              'canInfer': contradict,
              'issues': [],
              'advisoryOnly': true,
              'automaticExecutionAuthorized': false,
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final result = await client.checkDecision(request);
      expect(result.evidencePassed, true);
      expect(result.canInfer, false);
      contradict = true;
      await expectLater(
        client.checkDecision(request),
        throwsA(isA<MifuException>()),
      );
    },
  );

  testWidgets('centered preparation dialog distinguishes zero and unknown', (
    tester,
  ) async {
    Map<int, int?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showClusterPreparationDialog(
                  context,
                  candidates: liveFixture(now).plates.first.candidates,
                  checkingOnly: true,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('preparation-1')), '0');
    await tester.tap(find.text('检查条件'));
    await tester.pumpAndSettle();
    expect(result, {1: 0, 2: null});
  });

  testWidgets(
    'inference preparation rejects missing time and fits narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showClusterPreparationDialog(
                  context,
                  candidates: liveFixture(now).plates.first.candidates,
                  checkingOnly: false,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始比较'));
      await tester.pumpAndSettle();
      expect(find.text('请逐台填写预计准备秒数，确认无需准备时填0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unconfigured v4 screen prechecks without requesting a decision',
    (tester) async {
      final requests = <String>[];
      final client = MifuClient(
        client: MockClient((sent) async {
          requests.add(sent.url.path);
          final body = jsonDecode(sent.body) as Map;
          expect(body['decision_context']['schema'], 'mifu-decision-v4');
          expect(body['candidates'][0]['features']['setup_seconds'], isNull);
          return http.Response(
            jsonEncode({
              'requestId': body['requestId'],
              'inputContract': 'mifu-decision-v4',
              'evidenceStatus': 'blocked',
              'tokenAudit': {'status': 'pending'},
              'modelReady': false,
              'canInfer': false,
              'issues': [
                {'code': 'objective_evidence_missing', 'message': '请补充预计准备耗时'},
              ],
              'advisoryOnly': true,
              'automaticExecutionAuthorized': false,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      addTearDown(client.close);
      await fixtures.pumpCluster(
        tester,
        snapshot: liveFixture(DateTime.now()),
        client: client,
        health: const MifuHealth(
          trainingState: 'unconfigured',
          supportedInputContracts: ['mifu-decision-v4'],
        ),
      );
      await tester.tap(find.text('P01  外壳'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查条件'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '检查条件'));
      await tester.pumpAndSettle();
      expect(requests, ['/v1/decisions/check']);
      expect(find.text('请补充预计准备耗时'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ready v4 uses the same prepared snapshot for check and inference',
    (tester) async {
      Map? checked;
      final requests = <String>[];
      final client = MifuClient(
        client: MockClient((sent) async {
          requests.add(sent.url.path);
          final body = jsonDecode(sent.body) as Map;
          if (sent.url.path.endsWith('/check')) {
            checked = body;
            return http.Response(
              jsonEncode({
                'requestId': body['requestId'],
                'inputContract': 'mifu-decision-v4',
                'evidenceStatus': 'passed',
                'tokenAudit': {'status': 'passed'},
                'modelReady': true,
                'canInfer': true,
                'issues': [],
                'advisoryOnly': true,
                'automaticExecutionAuthorized': false,
              }),
              200,
            );
          }
          expect(body, checked);
          expect(body['candidates'][0]['features']['setup_seconds'], 0);
          expect(body['candidates'][1]['features']['setup_seconds'], 40);
          return http.Response(
            jsonEncode({
              'requestId': body['requestId'],
              'inputContract': 'mifu-decision-v4',
              'trainingState': 'ready',
              'choice': '1',
              'probabilities': {'1': .8, '2': .2},
              'elapsedMs': 12,
              'model': {
                'name': 'Mifu',
                'version': 'test-only',
                'checkpointConfigured': true,
                'inputContract': 'mifu-decision-v4',
              },
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      await fixtures.pumpCluster(
        tester,
        snapshot: liveFixture(DateTime.now()),
        client: client,
        health: const MifuHealth(
          trainingState: 'ready',
          version: 'test-only',
          inputContract: 'mifu-decision-v4',
          supportedObjectives: ['earliest_known_finish'],
          supportedInputContracts: ['mifu-decision-v4'],
        ),
      );
      await tester.tap(find.text('P01  外壳'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重新决策'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('preparation-1')), '0');
      await tester.enterText(find.byKey(const ValueKey('preparation-2')), '40');
      await tester.tap(find.text('开始比较'));
      await tester.pumpAndSettle();
      expect(requests, ['/v1/decisions/check', '/v1/decisions']);
      expect(find.text('80.0%'), findsOneWidget);
      // Cancelling a new preparation dialog must not disable the existing
      // suggestion's expiry timer or send another request.
      await tester.tap(find.text('重新决策'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(requests, ['/v1/decisions/check', '/v1/decisions']);
      expect(find.text('80.0%'), findsOneWidget);
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(find.text('80.0%'), findsNothing);
      expect(find.text('状态已变化，请重新决策'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
