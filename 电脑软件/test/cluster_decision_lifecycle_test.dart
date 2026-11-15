import 'dart:async';
import 'dart:convert';

import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_screen.dart';
import 'package:consumable_tracker_desktop/providers/cluster_provider.dart';
import 'package:consumable_tracker_desktop/providers/mifu_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'cluster_screen_test.dart' as fixtures;
import 'cluster_mifu_request_test.dart' as v4_fixtures;

const _ready = MifuHealth(trainingState: 'ready', version: 'mifu-test');
const _v4Ready = MifuHealth(
  trainingState: 'ready',
  version: 'mifu-test',
  inputContract: 'mifu-decision-v4',
  supportedObjectives: ['earliest_known_finish'],
  supportedInputContracts: ['mifu-decision-v4'],
);

http.Response _decision(http.Request sent) => http.Response(
  jsonEncode({
    'requestId': (jsonDecode(sent.body) as Map)['requestId'],
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

http.Response _v4Reply(http.Request sent) => http.Response(
  jsonEncode(
    sent.url.path.endsWith('/check')
        ? {
            'requestId': (jsonDecode(sent.body) as Map)['requestId'],
            'inputContract': 'mifu-decision-v4',
            'evidenceStatus': 'passed',
            'tokenAudit': {'status': 'passed'},
            'modelReady': true,
            'canInfer': true,
            'issues': [],
            'advisoryOnly': true,
            'automaticExecutionAuthorized': false,
          }
        : {
            ...jsonDecode(_decision(sent).body) as Map<String, dynamic>,
            'inputContract': 'mifu-decision-v4',
            'model': {
              'name': 'Mifu',
              'version': 'mifu-test',
              'checkpointConfigured': true,
              'inputContract': 'mifu-decision-v4',
            },
          },
  ),
  200,
);

Future<void> _submitPreparation(
  WidgetTester tester, {
  bool check = false,
}) async {
  await tester.enterText(find.byKey(const ValueKey('preparation-1')), '0');
  await tester.enterText(find.byKey(const ValueKey('preparation-2')), '40');
  await tester.tap(find.widgetWithText(FilledButton, check ? '检查条件' : '开始比较'));
  await tester.pumpAndSettle();
}

class _Harness {
  _Harness({ClusterPlanningSnapshot? initial, MifuHealth model = _ready})
    : snapshot = StateProvider((_) => initial ?? fixtures.fixture()),
      health = StateProvider((_) => model);

  final StateProvider<ClusterPlanningSnapshot> snapshot;
  final StateProvider<MifuHealth> health;
  late ProviderContainer container;
  Completer<ClusterPlanningSnapshot>? pendingSnapshot;

  Future<void> pump(
    WidgetTester tester,
    Future<http.Response> Function(http.Request) handler,
  ) async {
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = MifuClient(client: MockClient(handler));
    addTearDown(client.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clusterPlanningSnapshotProvider.overrideWith((ref) async {
            final value = ref.watch(snapshot);
            return pendingSnapshot?.future ?? value;
          }),
          mifuHealthProvider.overrideWith(
            (ref) => Stream.value(ref.watch(health)),
          ),
          mifuClientProvider.overrideWith((_) => client),
        ],
        child: const MaterialApp(home: Scaffold(body: ClusterScreen())),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
      tester.element(find.byType(ClusterScreen)),
    );
    await tester.tap(find.text('P01  外壳'));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets(
    'model change during a snapshot refresh clears cached preparation after a failed check',
    (tester) async {
      final initial = v4_fixtures.liveFixture(DateTime.now());
      final harness = _Harness(initial: initial, model: _v4Ready);
      var calls = 0;
      await harness.pump(tester, (request) async {
        calls++;
        return http.Response('{"error":"busy"}', 503);
      });
      await tester.tap(find.text('检查条件'));
      await tester.pumpAndSettle();
      await _submitPreparation(tester, check: true);
      final refresh = Completer<ClusterPlanningSnapshot>();
      harness.pendingSnapshot = refresh;
      harness.container.invalidate(clusterPlanningSnapshotProvider);
      await tester.pump();
      harness.container.read(harness.health.notifier).state = _ready;
      await tester.pump();
      harness.container.read(harness.health.notifier).state = _v4Ready;
      await tester.pump();
      refresh.complete(initial);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mifu-primary-action')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('preparation-1')))
            .controller!
            .text,
        isEmpty,
      );
      expect(calls, 1);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'failed check preparation cannot revive after facts change and return',
    (tester) async {
      final initial = v4_fixtures.liveFixture(DateTime.now());
      final harness = _Harness(initial: initial, model: _v4Ready);
      var calls = 0;
      await harness.pump(tester, (request) async {
        calls++;
        return http.Response('{"error":"busy"}', 503);
      });
      await tester.tap(find.text('检查条件'));
      await tester.pumpAndSettle();
      await _submitPreparation(tester, check: true);
      expect(calls, 1);
      harness.container.read(harness.snapshot.notifier).state = fixtures
          .fixture(candidateCount: 3);
      await tester.pumpAndSettle();
      harness.container.read(harness.snapshot.notifier).state = initial;
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mifu-primary-action')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('preparation-1')))
            .controller!
            .text,
        isEmpty,
      );
      expect(calls, 1);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'ready shortcut checks and compares once without writing or dispatching',
    (tester) async {
      final harness = _Harness(
        initial: v4_fixtures.liveFixture(DateTime.now()),
        model: _v4Ready,
      );
      final sent = <http.Request>[];
      await harness.pump(tester, (request) async {
        sent.add(request);
        return _v4Reply(request);
      });
      expect(sent, isEmpty);
      await tester.tap(find.byKey(const ValueKey('mifu-ready-compare')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(sent.map((r) => r.url.path), [
        '/v1/decisions/check',
        '/v1/decisions',
      ]);
      for (final request in sent) {
        final input = jsonDecode(request.body) as Map;
        expect(
          (input['candidates'] as List).every(
            (c) => c['features']['setup_seconds'] == 0,
          ),
          isTrue,
        );
      }
      expect(find.text('Mifu 建议'), findsOneWidget);
      expect(find.text('当前选择 · 设备 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'checked preparation is reused by the primary action without renewing its timestamp',
    (tester) async {
      final harness = _Harness(
        initial: v4_fixtures.liveFixture(DateTime.now()),
        model: _v4Ready,
      );
      final inputs = <Map>[];
      await harness.pump(tester, (request) async {
        inputs.add(jsonDecode(request.body) as Map);
        return _v4Reply(request);
      });
      await tester.tap(find.text('检查条件'));
      await tester.pumpAndSettle();
      await _submitPreparation(tester, check: true);
      final firstSetup =
          ((inputs.first['candidates'] as List).first['features']
              as Map)['timing_evidence']['setup'];
      await tester.tap(find.byKey(const ValueKey('mifu-primary-action')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(inputs, hasLength(3));
      final lastSetup =
          ((inputs.last['candidates'] as List).first['features']
              as Map)['timing_evidence']['setup'];
      expect(lastSetup, firstSetup);
      expect(
        (inputs.last['candidates'] as List).last['features']['setup_seconds'],
        40,
      );
      expect(find.text('80.0%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('v4 hardware changes invalidate otherwise identical candidates', (
    tester,
  ) async {
    final initial = v4_fixtures.liveFixture(DateTime.now());
    final harness = _Harness(initial: initial, model: _v4Ready);
    await harness.pump(tester, (sent) async => _v4Reply(sent));
    await tester.tap(find.text('重新决策'));
    await tester.pumpAndSettle();
    await _submitPreparation(tester);
    expect(find.text('80.0%'), findsOneWidget);
    harness.container
        .read(harness.snapshot.notifier)
        .state = ClusterPlanningSnapshot(
      studio: initial.studio,
      tasks: initial.tasks,
      generatedAt: initial.generatedAt,
      printers: [
        for (final printer in initial.printers)
          ClusterPrinter(
            source: printer.source,
            activeQueueCount: printer.activeQueueCount,
            availableAfterSeconds: printer.availableAfterSeconds,
            blockers: printer.blockers,
            state: FleetPrinterState(
              serial: printer.state!.serial,
              displayLabel: printer.state!.displayLabel,
              connectionState: printer.state!.connectionState,
              lastStatus: printer.state!.lastStatus,
              statusUpdatedAt: printer.state!.statusUpdatedAt,
              isLanCapable: printer.state!.isLanCapable,
              mode: printer.state!.mode,
              reportedModel: printer.state!.reportedModel,
              installedNozzleDiameter: .6,
              isConnecting: false,
            ),
          ),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsNothing);
    harness.container.read(harness.snapshot.notifier).state = initial;
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsNothing);
  });

  testWidgets(
    'telemetry and capability ordering do not invalidate a valid model',
    (tester) async {
      const initialModel = MifuHealth(
        trainingState: 'ready',
        version: 'mifu-test',
        inputContract: 'mifu-decision-v4',
        supportedObjectives: ['earliest_known_finish', 'test-other'],
        supportedInputContracts: ['legacy_v1', 'mifu-decision-v4'],
      );
      final harness = _Harness(
        initial: v4_fixtures.liveFixture(DateTime.now()),
        model: initialModel,
      );
      await harness.pump(tester, (sent) async => _v4Reply(sent));
      await tester.tap(find.text('重新决策'));
      await tester.pumpAndSettle();
      await _submitPreparation(tester);
      harness.container.read(harness.health.notifier).state = const MifuHealth(
        trainingState: 'ready',
        version: 'mifu-test',
        inputContract: 'mifu-decision-v4',
        supportedObjectives: ['test-other', 'earliest_known_finish'],
        supportedInputContracts: ['mifu-decision-v4', 'legacy_v1'],
        utilizationPercent: 75,
        temperatureC: 50,
      );
      harness.container.read(harness.snapshot.notifier).state = v4_fixtures
          .liveFixture(DateTime.now());
      await tester.pumpAndSettle();
      expect(find.text('80.0%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final check in [false, true]) {
    for (final modelChange in [false, true]) {
      testWidgets(
        '${check ? 'check' : 'inference'} preparation retires on temporary '
        '${modelChange ? 'model' : 'snapshot'} change',
        (tester) async {
          final initial = v4_fixtures.liveFixture(DateTime.now());
          final harness = _Harness(initial: initial, model: _v4Ready);
          var calls = 0;
          await harness.pump(tester, (sent) async {
            calls++;
            return _v4Reply(sent);
          });
          await tester.tap(find.text(check ? '检查条件' : '重新决策'));
          await tester.pumpAndSettle();
          if (modelChange) {
            harness.container.read(harness.health.notifier).state = _ready;
          } else {
            harness.container.read(harness.snapshot.notifier).state = fixtures
                .fixture(candidateCount: 3);
          }
          await tester.pumpAndSettle();
          harness.container.read(harness.snapshot.notifier).state = initial;
          harness.container.read(harness.health.notifier).state = _v4Ready;
          await tester.pumpAndSettle();
          await _submitPreparation(tester, check: check);
          expect(calls, 0);
          expect(find.text('80.0%'), findsNothing);
          expect(find.text('比较条件已齐备'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('same version objective change retires a v4 suggestion', (
    tester,
  ) async {
    final harness = _Harness(
      initial: v4_fixtures.liveFixture(DateTime.now()),
      model: _v4Ready,
    );
    await harness.pump(tester, (sent) async => _v4Reply(sent));
    await tester.tap(find.text('重新决策'));
    await tester.pumpAndSettle();
    await _submitPreparation(tester);
    expect(find.text('80.0%'), findsOneWidget);
    harness.container.read(harness.health.notifier).state = const MifuHealth(
      trainingState: 'ready',
      version: 'mifu-test',
      inputContract: 'mifu-decision-v4',
      supportedInputContracts: ['mifu-decision-v4'],
    );
    await tester.pumpAndSettle();
    harness.container.read(harness.health.notifier).state = _v4Ready;
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsNothing);
  });

  testWidgets(
    'preflight waits for refreshed facts before requesting inference',
    (tester) async {
      final initial = v4_fixtures.liveFixture(DateTime.now());
      final harness = _Harness(initial: initial, model: _v4Ready);
      final pending = Completer<http.Response>();
      late http.Request checkRequest;
      final calls = <String>[];
      await harness.pump(tester, (sent) {
        calls.add(sent.url.path);
        checkRequest = sent;
        return pending.future;
      });
      await tester.tap(find.text('重新决策'));
      await tester.pumpAndSettle();
      await _submitPreparation(tester);
      harness.pendingSnapshot = Completer<ClusterPlanningSnapshot>();
      harness.container.invalidate(clusterPlanningSnapshotProvider);
      await tester.pump();
      pending.complete(_v4Reply(checkRequest));
      await tester.pump();
      expect(calls, ['/v1/decisions/check']);
      harness.pendingSnapshot!.complete(fixtures.fixture(candidateCount: 3));
      await tester.pumpAndSettle();
      expect(calls, ['/v1/decisions/check']);
      expect(find.text('80.0%'), findsNothing);
    },
  );

  for (final invalidation in ['snapshot', 'model', 'expiry']) {
    testWidgets('completed input check retires after $invalidation', (
      tester,
    ) async {
      final harness = _Harness(
        initial: v4_fixtures.liveFixture(DateTime.now()),
        model: _v4Ready,
      );
      await harness.pump(tester, (sent) async => _v4Reply(sent));
      await tester.tap(find.text('检查条件'));
      await tester.pumpAndSettle();
      await _submitPreparation(tester, check: true);
      expect(find.text('比较条件已齐备'), findsOneWidget);
      switch (invalidation) {
        case 'snapshot':
          harness.container.read(harness.snapshot.notifier).state = fixtures
              .fixture(candidateCount: 3);
        case 'model':
          harness.container.read(harness.health.notifier).state = _ready;
        case 'expiry':
          await tester.pump(const Duration(minutes: 2));
      }
      await tester.pumpAndSettle();
      expect(find.text('比较条件已齐备'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'late input check cannot affect a newer check or allow parallel writes',
    (tester) async {
      final initial = v4_fixtures.liveFixture(DateTime.now());
      final harness = _Harness(initial: initial, model: _v4Ready);
      final pending = <Completer<http.Response>>[];
      final sentRequests = <http.Request>[];
      await harness.pump(tester, (sent) {
        sentRequests.add(sent);
        final response = Completer<http.Response>();
        pending.add(response);
        return response.future;
      });
      await tester.tap(find.text('设备 1').first);
      await tester.tap(find.text('检查条件'));
      await tester.pumpAndSettle();
      await _submitPreparation(tester, check: true);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '记录选择'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '检查并排产'))
            .onPressed,
        isNull,
      );
      harness.container.read(harness.snapshot.notifier).state = fixtures
          .fixture(candidateCount: 3);
      await tester.pumpAndSettle();
      harness.container.read(harness.snapshot.notifier).state = initial;
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查条件'));
      await tester.pumpAndSettle();
      await _submitPreparation(tester, check: true);
      pending.first.complete(_v4Reply(sentRequests.first));
      await tester.pumpAndSettle();
      expect(find.text('比较条件已齐备'), findsNothing);
      expect(find.text('检查中'), findsOneWidget);
      pending.last.complete(_v4Reply(sentRequests.last));
      await tester.pumpAndSettle();
      expect(find.text('比较条件已齐备'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same version contract change retires the completed decision', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.pump(tester, (sent) async => _decision(sent));
    await tester.tap(find.text('重新决策'));
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsOneWidget);
    harness.container.read(harness.health.notifier).state = _v4Ready;
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsNothing);
    harness.container.read(harness.health.notifier).state = _ready;
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsNothing);
  });

  testWidgets('single candidate default selection records only once', (
    tester,
  ) async {
    var records = 0;
    final harness = _Harness(initial: fixtures.fixture(candidateCount: 1));
    await harness.pump(tester, (sent) async {
      expect(sent.url.path, '/v1/records');
      records++;
      return http.Response('{"recordId":"r1","trainingEligible":false}', 201);
    });
    await tester.tap(find.text('记录选择'));
    await tester.pumpAndSettle();
    expect(find.text('已记录'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '已记录'))
          .onPressed,
      isNull,
    );
    expect(records, 1);
  });

  testWidgets('removed manual device does not revive when it returns', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.pump(tester, (_) async => throw StateError('No request'));
    await tester.tap(find.text('设备 2').first);
    await tester.pumpAndSettle();
    harness.container.read(harness.snapshot.notifier).state = fixtures.fixture(
      candidateCount: 1,
    );
    await tester.pumpAndSettle();
    harness.container.read(harness.snapshot.notifier).state = fixtures
        .fixture();
    await tester.pumpAndSettle();
    expect(find.text('当前选择 · 设备 2'), findsNothing);
  });

  testWidgets('removed plate requires a new selection after it returns', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.pump(tester, (_) async => throw StateError('No request'));
    harness.container.read(harness.snapshot.notifier).state = fixtures.fixture(
      empty: true,
    );
    await tester.pumpAndSettle();
    harness.container.read(harness.snapshot.notifier).state = fixtures
        .fixture();
    await tester.pumpAndSettle();
    expect(find.text('P01 · 外壳'), findsNothing);
  });

  testWidgets(
    'slice artifact change invalidates otherwise identical decision evidence',
    (tester) async {
      final harness = _Harness();
      await harness.pump(tester, (sent) async => _decision(sent));
      await tester.tap(find.text('重新决策'));
      await tester.pumpAndSettle();
      expect(find.text('80.0%'), findsOneWidget);
      harness.container.read(harness.snapshot.notifier).state = fixtures
          .fixture(artifactSha256: List.filled(64, 'a').join());
      await tester.pumpAndSettle();
      expect(find.text('80.0%'), findsNothing);
      expect(find.text('状态已变化，请重新决策'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disconnected model cannot resurrect its previous suggestion', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.pump(tester, (sent) async => _decision(sent));
    await tester.tap(find.text('重新决策'));
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsOneWidget);

    harness.container.read(harness.health.notifier).state =
        const MifuHealth.disconnected();
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsNothing);
    expect(find.text('当前选择 · 设备 2'), findsNothing);

    harness.container.read(harness.health.notifier).state = _ready;
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsNothing);
    expect(find.text('状态已变化，请重新决策'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'changed candidates permanently invalidate a completed decision',
    (tester) async {
      final harness = _Harness();
      await harness.pump(tester, (sent) async => _decision(sent));
      await tester.tap(find.text('重新决策'));
      await tester.pumpAndSettle();
      harness.container.read(harness.snapshot.notifier).state = fixtures
          .fixture(candidateCount: 3);
      await tester.pumpAndSettle();
      expect(find.text('80.0%'), findsNothing);
      harness.container.read(harness.snapshot.notifier).state = fixtures
          .fixture();
      await tester.pumpAndSettle();
      expect(find.text('80.0%'), findsNothing);
      expect(find.text('当前选择 · 设备 2'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late inference cannot select a device after facts change', (
    tester,
  ) async {
    final harness = _Harness();
    final pending = Completer<http.Response>();
    late http.Request request;
    await harness.pump(tester, (sent) {
      request = sent;
      return pending.future;
    });
    await tester.tap(find.text('重新决策'));
    await tester.pump();
    harness.container.read(harness.snapshot.notifier).state = fixtures.fixture(
      candidateCount: 3,
    );
    await tester.pumpAndSettle();
    harness.container.read(harness.snapshot.notifier).state = fixtures
        .fixture();
    await tester.pumpAndSettle();
    pending.complete(_decision(request));
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsNothing);
    expect(find.text('当前选择 · 设备 2'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('older response cannot clear a newer inference busy state', (
    tester,
  ) async {
    final harness = _Harness();
    final pending = <Completer<http.Response>>[];
    final requests = <http.Request>[];
    await harness.pump(tester, (sent) {
      requests.add(sent);
      final response = Completer<http.Response>();
      pending.add(response);
      return response.future;
    });
    await tester.tap(find.text('重新决策'));
    await tester.pump();
    await tester.tap(find.text('P02  底板'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新决策'));
    await tester.pump();
    expect(pending, hasLength(2));
    pending.first.complete(_decision(requests.first));
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '推理中'))
          .onPressed,
      isNull,
    );
    pending.last.complete(_decision(requests.last));
    await tester.pumpAndSettle();
    expect(find.text('P02 · 底板'), findsOneWidget);
    expect(find.text('80.0%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale feedback response cannot mark a restored snapshot saved', (
    tester,
  ) async {
    final harness = _Harness();
    final pending = Completer<http.Response>();
    await harness.pump(tester, (sent) {
      expect(sent.url.path, '/v1/records');
      return pending.future;
    });
    await tester.tap(find.text('设备 1').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('记录选择'));
    await tester.pump();
    harness.container.read(harness.snapshot.notifier).state = fixtures.fixture(
      candidateCount: 3,
    );
    await tester.pumpAndSettle();
    harness.container.read(harness.snapshot.notifier).state = fixtures
        .fixture();
    await tester.pumpAndSettle();
    await tester.tap(find.text('设备 1').first);
    await tester.pumpAndSettle();
    pending.complete(
      http.Response('{"recordId":"r1","trainingEligible":false}', 201),
    );
    await tester.pumpAndSettle();
    expect(find.text('已记录'), findsNothing);
    expect(find.text('选择已记录，复核后才会进入训练集'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unchanged snapshot refresh retains a valid decision', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.pump(tester, (sent) async => _decision(sent));
    await tester.tap(find.text('重新决策'));
    await tester.pumpAndSettle();
    harness.container.read(harness.snapshot.notifier).state = fixtures
        .fixture();
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsOneWidget);
    expect(find.text('当前选择 · 设备 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('decision expires without needing another service update', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.pump(tester, (sent) async => _decision(sent));
    await tester.tap(find.text('重新决策'));
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsOneWidget);
    await tester.pump(const Duration(minutes: 2));
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsNothing);
    expect(find.text('当前选择 · 设备 2'), findsNothing);
    expect(find.text('状态已变化，请重新决策'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inference waits for an unchanged snapshot refresh to finish', (
    tester,
  ) async {
    final harness = _Harness();
    final pending = Completer<http.Response>();
    late http.Request request;
    await harness.pump(tester, (sent) {
      request = sent;
      return pending.future;
    });
    await tester.tap(find.text('重新决策'));
    await tester.pump();
    harness.pendingSnapshot = Completer<ClusterPlanningSnapshot>();
    harness.container.invalidate(clusterPlanningSnapshotProvider);
    await tester.pump();
    pending.complete(_decision(request));
    await tester.pump();
    expect(find.text('80.0%'), findsNothing);
    harness.pendingSnapshot!.complete(fixtures.fixture());
    await tester.pumpAndSettle();
    expect(find.text('80.0%'), findsOneWidget);
    expect(find.text('当前选择 · 设备 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final failed in [false, true]) {
    testWidgets(
      'device selection revision rejects old feedback ${failed ? 'error' : 'receipt'}',
      (tester) async {
        final harness = _Harness();
        final pending = Completer<http.Response>();
        await harness.pump(tester, (_) => pending.future);
        await tester.tap(find.text('设备 1').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('记录选择'));
        await tester.pump();
        await tester.tap(find.text('设备 2').first);
        await tester.pump();
        if (!failed) {
          await tester.tap(find.text('设备 1').first);
          await tester.pump();
        }
        pending.complete(
          http.Response(
            failed
                ? '{"error":{"message":"old-feedback-failure"}}'
                : '{"recordId":"r1","trainingEligible":false}',
            failed ? 503 : 201,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('已记录'), findsNothing);
        expect(find.text('old-feedback-failure'), findsNothing);
        expect(find.text('选择已记录，复核后才会进入训练集'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('feedback waits for an unchanged snapshot refresh to finish', (
    tester,
  ) async {
    final harness = _Harness();
    final pending = Completer<http.Response>();
    await harness.pump(tester, (_) => pending.future);
    await tester.tap(find.text('设备 1').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('记录选择'));
    await tester.pump();
    harness.pendingSnapshot = Completer<ClusterPlanningSnapshot>();
    harness.container.invalidate(clusterPlanningSnapshotProvider);
    await tester.pump();
    pending.complete(
      http.Response('{"recordId":"r1","trainingEligible":false}', 201),
    );
    await tester.pump();
    expect(find.text('已记录'), findsNothing);
    harness.pendingSnapshot!.complete(fixtures.fixture());
    await tester.pumpAndSettle();
    expect(find.text('已记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
