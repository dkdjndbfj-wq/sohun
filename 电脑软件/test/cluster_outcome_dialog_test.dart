import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:consumable_tracker_desktop/core/services/cluster_training_observation.dart';
import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:consumable_tracker_desktop/core/services/cluster_planning_service.dart';
import 'package:consumable_tracker_desktop/core/services/printer_fleet_connection_manager.dart';
import 'package:consumable_tracker_desktop/data/external/printer/bambu_printer_models.dart';
import 'package:consumable_tracker_desktop/data/external/printer/printer_connector.dart';
import 'package:consumable_tracker_desktop/features/cluster/cluster_outcome_dialog.dart';
import 'package:consumable_tracker_desktop/core/theme/app_theme.dart';
import 'package:consumable_tracker_desktop/core/theme/app_typography.dart';
import 'package:consumable_tracker_desktop/core/theme/personal_desktop_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'cluster_screen_test.dart' as fixtures;

Map<String, dynamic> history(
  String plate, {
  List<Map<String, dynamic>> attempts = const [],
}) => {
  'records': [
    {
      'recordId': 'record-$plate',
      'plateId': plate,
      'candidateId': '1',
      'createdAt': '2026-11-10T01:00:00Z',
      'plateIndex': 1,
    },
  ],
  'attempts': attempts,
  'trainingEligible': false,
  'attemptsTruncated': false,
};

http.Response acknowledgment(Map<String, dynamic> event) => http.Response(
  jsonEncode({
    'eventId': event['eventId'],
    'attemptId': event['attemptId'],
    'recordId': event['recordId'],
    'duplicate': false,
    'trainingEligible': false,
  }),
  200,
);

Future<void> pumpDialog(
  WidgetTester tester,
  MifuClient client, {
  Size size = const Size(1000, 900),
  ThemeData? theme,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showClusterOutcomeDialog(
              context,
              client: client,
              plateId: 'plate-a',
              plateName: '测试盘',
              visiblePrinters: const {'1': '设备 A'},
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unavailable history can still be closed without a save', (
    tester,
  ) async {
    final client = MifuClient(
      client: MockClient((_) async => throw http.ClientException('offline')),
    );
    addTearDown(client.close);
    await pumpDialog(tester, client);
    expect(find.text('重新加载'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(ClusterOutcomeDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('old imported dates open safely and cancel preserves history', (
    tester,
  ) async {
    final client = MifuClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(
            history(
              'plate-a',
              attempts: [
                {
                  'attemptId': 'old-attempt',
                  'recordId': 'record-plate-a',
                  'plateId': 'plate-a',
                  'candidateId': '1',
                  'lastOccurredAt': '2026-11-09T00:00:00Z',
                  'executionEventId': 'old-event',
                  'execution': {
                    'status': 'unknown',
                    'startedAt': '1999-01-01T00:00:00Z',
                    'endedAt': null,
                    'actualDurationSeconds': null,
                    'materialUsedGrams': null,
                    'completionPercent': null,
                    'failureCategory': null,
                    'failureEvidence': null,
                  },
                },
              ],
            ),
          ),
          200,
        ),
      ),
    );
    addTearDown(client.close);
    await pumpDialog(tester, client);
    await tester.tap(find.text('新增一次打印 / 重打'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1 次 · 状态未知 · 未填写').last);
    await tester.pumpAndSettle();
    final date = find.textContaining('开始时间：1999');
    await tester.ensureVisible(date);
    await tester.tap(date);
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(date, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saved outcome waits for fresh history before another event can be saved',
    (tester) async {
      final events = <Map<String, dynamic>>[];
      var queries = 0;
      final client = MifuClient(
        client: MockClient((request) async {
          if (request.url.path == '/v1/records/query') {
            queries++;
            if (queries == 2) {
              throw http.ClientException('history unavailable after save');
            }
            final saved = events.firstOrNull;
            return http.Response(
              jsonEncode(
                history(
                  'plate-a',
                  attempts: [
                    if (saved != null)
                      {
                        'attemptId': saved['attemptId'],
                        'recordId': saved['recordId'],
                        'plateId': saved['plateId'],
                        'candidateId': saved['candidateId'],
                        'executionEventId': saved['eventId'],
                        'execution': saved['payload'],
                        'qualityEventId': null,
                        'quality': null,
                        'lastOccurredAt': saved['occurredAt'],
                        'trainingEligible': false,
                      },
                  ],
                ),
              ),
              200,
            );
          }
          final event = jsonDecode(request.body) as Map<String, dynamic>;
          events.add(event);
          return acknowledgment(event);
        }),
      );
      addTearDown(client.close);
      await pumpDialog(tester, client);
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      expect(events, hasLength(1));
      expect(find.textContaining('已保存。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存记录'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '执行结果'))
            .onSelected,
        isNull,
      );
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(queries, 3);
      expect(events, hasLength(1));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存记录'))
            .onPressed,
        isNotNull,
      );
      expect(find.text('第 1 次 · 状态未知 · 未填写'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '人工质检'))
            .onSelected,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'malformed history is recoverable without building unsafe fields',
    (tester) async {
      var queries = 0;
      final client = MifuClient(
        client: MockClient((_) async {
          queries++;
          return http.Response(
            jsonEncode(
              history(
                'plate-a',
                attempts: [
                  if (queries == 1)
                    {
                      'attemptId': 'broken-attempt',
                      'recordId': 'record-plate-a',
                      'plateId': 'plate-a',
                      'candidateId': '1',
                      'lastOccurredAt': '2026-11-09T03:00:00Z',
                      'executionEventId': 'broken-event',
                      'execution': {
                        'status': 'unexpected-state',
                        'startedAt': 123,
                      },
                    },
                ],
              ),
            ),
            200,
          );
        }),
      );
      addTearDown(client.close);
      await pumpDialog(tester, client);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(queries, 2);
      expect(find.text('新增一次打印 / 重打'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'history queries all visible printers in frozen chunks and marks global limits',
    () async {
      final scope = {for (var i = 1; i <= 129; i++) '$i'};
      final chunks = <List<String>>[];
      final client = MifuClient(
        client: MockClient((request) async {
          final query = jsonDecode(request.body) as Map;
          final ids = List<String>.from(query['candidateIds'] as List);
          chunks.add(ids);
          // A caller changing its live scope during an await must not change this query.
          scope.clear();
          final records = [
            for (final id in ids.take(10))
              {
                'recordId': 'record-$id',
                'plateId': 'plate-a',
                'candidateId': id,
                'createdAt': DateTime.utc(
                  2026,
                  1,
                  1,
                ).add(Duration(seconds: int.parse(id))).toIso8601String(),
                'plateIndex': 1,
              },
          ];
          return http.Response(
            jsonEncode({
              'records': records,
              'attempts': [],
              'trainingEligible': false,
              'attemptsTruncated': false,
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final result = await client.queryRecords(
        plateId: 'plate-a',
        candidateIds: scope,
      );
      expect(chunks.map((c) => c.length), [64, 64, 1]);
      expect(chunks.expand((c) => c).toSet().length, 129);
      expect(result.records.length, 20);
      expect(result.records.first['candidateId'], '129');
      expect(result.recordsTruncated, isTrue);
    },
  );

  testWidgets('quality explanation stays clear of the populated score label', (
    tester,
  ) async {
    final client = MifuClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(
            history(
              'plate-a',
              attempts: [
                {
                  'attemptId': 'attempt-layout',
                  'recordId': 'record-plate-a',
                  'plateId': 'plate-a',
                  'candidateId': '1',
                  'executionEventId': 'execution-layout',
                  'execution': {
                    'status': 'completed',
                    'startedAt': '2026-11-09T01:00:00Z',
                    'endedAt': '2026-11-09T02:00:00Z',
                    'actualDurationSeconds': null,
                    'materialUsedGrams': null,
                    'completionPercent': null,
                    'failureCategory': null,
                    'failureEvidence': null,
                  },
                  'qualityEventId': 'quality-layout',
                  'quality': {
                    'status': 'pass',
                    'inspectedAt': '2026-11-09T03:00:00Z',
                    'inspectorId': 'original-human',
                    'qualityScore': 96,
                    'defectCodes': [],
                    'notes': 'Surface checked',
                  },
                  'lastOccurredAt': '2026-11-09T03:00:00Z',
                  'trainingEligible': false,
                },
              ],
            ),
          ),
          200,
        ),
      ),
    );
    addTearDown(client.close);
    await pumpDialog(
      tester,
      client,
      size: const Size(1600, 1000),
      theme: buildPersonalDesktopTheme(
        AppTheme.light(),
        personalProduct: true,
        studioMode: false,
      ),
    );
    await tester.tap(find.text('新增一次打印 / 重打'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第 1 次 · 已完成 · 合格').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '人工质检'));
    await tester.pumpAndSettle();

    final explanation = find.text('此结果由本次操作人手工确认，属于检查观察；完成复核前不作为最终合格标签。');
    final score = find.widgetWithText(TextFormField, '质量评分（0–100，可不填）');
    await tester.ensureVisible(score);
    await tester.pumpAndSettle();
    final explanationBottom = tester.getBottomLeft(explanation).dy;
    expect(
      tester.getTopLeft(score).dy - explanationBottom,
      greaterThanOrEqualTo(16),
    );
    // A nonempty field floats its label above the input's content area.
    expect(
      tester.getTopLeft(find.text('质量评分（0–100，可不填）')).dy,
      greaterThanOrEqualTo(explanationBottom + 4),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'quality correction preserves original inspector while a new inspection is explicit',
    (tester) async {
      final events = <Map<String, dynamic>>[];
      final attempt = {
        'attemptId': 'attempt-old',
        'recordId': 'record-plate-a',
        'plateId': 'plate-a',
        'candidateId': '1',
        'executionEventId': 'execution-old',
        'execution': {
          'status': 'completed',
          'startedAt': '2026-11-09T01:00:00Z',
          'endedAt': '2026-11-09T02:00:00Z',
          'actualDurationSeconds': null,
          'materialUsedGrams': null,
          'completionPercent': null,
          'failureCategory': null,
          'failureEvidence': null,
        },
        'qualityEventId': 'quality-old',
        'quality': {
          'status': 'pass',
          'inspectedAt': '2026-11-09T03:00:00Z',
          'inspectorId': 'original-human',
          'qualityScore': 88,
          'defectCodes': [],
          'notes': 'original',
        },
        'lastOccurredAt': '2026-11-09T03:00:00Z',
        'trainingEligible': false,
      };
      final client = MifuClient(
        client: MockClient((request) async {
          if (request.url.path == '/v1/records/query') {
            return http.Response(
              jsonEncode(history('plate-a', attempts: [attempt])),
              200,
            );
          }
          final event = jsonDecode(request.body) as Map<String, dynamic>;
          events.add(event);
          return acknowledgment(event);
        }),
      );
      addTearDown(client.close);
      await pumpDialog(tester, client);
      await tester.tap(find.text('新增一次打印 / 重打'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 次 · 已完成 · 合格').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, '人工质检'));
      await tester.pumpAndSettle();
      final formScroll = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byType(SwitchListTile),
        200,
        scrollable: formScroll,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(TextFormField, '更正原因（必填）'),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '更正原因（必填）'),
        '补充备注',
      );
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      expect(events.single['payload']['inspectorId'], 'original-human');
      expect(events.single['source']['actorId'], isNot('original-human'));
      expect(
        events.single['payload']['inspectedAt'],
        '2026-11-09T03:00:00.000Z',
      );
      expect(events.single['supersedesEventId'], 'quality-old');
      await tester.scrollUntilVisible(
        find.text('重新质检'),
        -200,
        scrollable: formScroll,
      );
      await tester.tap(find.text('重新质检'));
      await tester.pumpAndSettle();
      expect(find.text('正在记录一次新的人工检查，请重新填写结果与时间。'), findsOneWidget);
      expect(find.text('未填写'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNothing);
      await tester.scrollUntilVisible(
        find.widgetWithText(ChoiceChip, '执行结果'),
        -200,
        scrollable: formScroll,
      );
      await tester.tap(find.widgetWithText(ChoiceChip, '执行结果'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(SwitchListTile),
        200,
        scrollable: formScroll,
      );
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'one candidate can record human observation but cannot infer or attach model ranking',
    () async {
      var calls = 0;
      final client = MifuClient(
        client: MockClient((sent) async {
          calls++;
          expect(sent.url.path, '/v1/records');
          expect((jsonDecode(sent.body) as Map)['decision'], isNull);
          return http.Response(
            '{"recordId":"single-record","trainingEligible":false}',
            201,
          );
        }),
      );
      addTearDown(client.close);
      const request = MifuDecisionRequest(
        requestId: 'one',
        plate: {'id': 'plate'},
        candidates: [
          {'id': '1', 'features': <String, dynamic>{}},
        ],
      );
      expect(
        await client.record(request: request, selectedCandidateId: '1'),
        'single-record',
      );
      await expectLater(client.decide(request), throwsA(isA<MifuException>()));
      await expectLater(
        client.record(
          request: request,
          selectedCandidateId: '1',
          decision: const MifuDecision(
            choice: '1',
            probabilities: {'1': 1},
            elapsedMs: 0,
            version: 'fake',
            raw: {},
          ),
        ),
        throwsA(isA<MifuException>()),
      );
      expect(calls, 1);
    },
  );

  test(
    'snapshot captures 16 printers and 512 slots without truncation, rejects 1025 slots',
    () {
      ClusterPlanningSnapshot withSlots(int total) {
        final base = fixtures.fixture(candidateCount: 16);
        final extra = total - 512;
        return ClusterPlanningSnapshot(
          studio: base.studio,
          tasks: base.tasks,
          generatedAt: base.generatedAt,
          printers: [
            for (var i = 0; i < 16; i++)
              ClusterPrinter(
                source: base.printers[i].source,
                activeQueueCount: 0,
                availableAfterSeconds: 0,
                blockers: const [],
                state: FleetPrinterState(
                  serial: 'test-$i',
                  displayLabel: '设备 $i',
                  connectionState: PrinterConnectionState.connected,
                  statusUpdatedAt: base.generatedAt,
                  isLanCapable: true,
                  mode: BambuConnectionMode.lan,
                  reportedModel: 'test',
                  installedNozzleDiameter: .4,
                  isConnecting: false,
                  lastStatus: BambuPrinterStatus(
                    serial: 'test-$i',
                    amsUnits: [
                      for (var unit = 0; unit < 8; unit++)
                        AmsUnit(
                          id: unit,
                          type: AmsUnitType.ams,
                          isPresent: true,
                          trays: [
                            for (
                              var slot = 0;
                              slot < 4 + (i == 0 && unit == 0 ? extra : 0);
                              slot++
                            )
                              AmsTray(
                                amsId: unit,
                                slot: slot,
                                hasFilamentObservation: false,
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      }

      final full = withSlots(512);
      final result = clusterTrainingObservation(
        full,
        full.plates.first,
        full.plates.first.candidates,
        'r',
      );
      expect((result['feed_slots'] as List).length, 512);
      expect((result['ams_units'] as List).length, 128);
      expect(
        (result['feed_slots'] as List).every(
          (slot) => slot['present'] == null && slot['telemetry_at'] == null,
        ),
        isTrue,
      );
      final tooLarge = withSlots(1025);
      expect(
        () => clusterTrainingObservation(
          tooLarge,
          tooLarge.plates.first,
          tooLarge.plates.first.candidates,
          'r',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('1024'),
          ),
        ),
      );
    },
  );

  if (const bool.fromEnvironment('MIFU_CAPTURE')) {
    for (final brightness in Brightness.values) {
      testWidgets('capture ${brightness.name} result form fixture', (
        tester,
      ) async {
        await tester.runAsync(() async {
          final bytes = await File(
            r'C:\Windows\Fonts\HarmonyOS_Sans_SC_Regular.ttf',
          ).readAsBytes();
          for (final family in [
            AppTypography.chineseFontFamily,
            'HarmonyOS Sans',
            'Roboto',
            'Ahem',
            AppTypography.monoFontFamily,
          ]) {
            await (FontLoader(
              family,
            )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
          }
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
        tester.view.physicalSize = const Size(1180, 1040);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final client = MifuClient(
          client: MockClient(
            (_) async => http.Response(jsonEncode(history('plate-a')), 200),
          ),
        );
        addTearDown(client.close);
        const key = ValueKey('result-form-capture');
        final theme = buildPersonalDesktopTheme(
          brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
          personalProduct: true,
          studioMode: false,
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              home: Scaffold(
                body: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      color: theme.colorScheme.primaryContainer,
                      padding: const EdgeInsets.all(14),
                      child: const Text('Mifu 打印结果 · 界面测试数据，不代表真实打印或模型效果'),
                    ),
                    Expanded(
                      child: ClusterOutcomeDialog(
                        client: client,
                        plateId: 'plate-a',
                        plateName: 'P1 · 外壳（测试数据）',
                        visiblePrinters: const {'1': '设备 A · P1S'},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
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
              '${folder.path}/outcome-${brightness.name}-fixture-preview.png',
            ).writeAsBytes(png!.buffer.asUint8List());
          } finally {
            rendered.dispose();
          }
        });
      });
    }
  }

  testWidgets(
    'centered form keeps unknown measurements and requires execution before quality',
    (tester) async {
      Map<String, dynamic>? submitted;
      final client = MifuClient(
        client: MockClient((request) async {
          if (request.url.path == '/v1/records/query') {
            return http.Response(jsonEncode(history('plate-a')), 200);
          }
          submitted = jsonDecode(request.body) as Map<String, dynamic>;
          return acknowledgment(submitted!);
        }),
      );
      addTearDown(client.close);
      await pumpDialog(tester, client, size: const Size(580, 720));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      final quality = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '人工质检'),
      );
      expect(quality.onSelected, isNull);
      expect(find.text('合格'), findsNothing);
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      expect(submitted!['eventType'], 'execution');
      expect(submitted!['payload'], {
        'status': 'unknown',
        'startedAt': null,
        'endedAt': null,
        'actualDurationSeconds': null,
        'materialUsedGrams': null,
        'completionPercent': null,
        'failureCategory': null,
        'failureEvidence': null,
      });
      expect(tester.takeException(), isNull);
    },
  );

  for (final failure in ['transport', 'internal_error']) {
    testWidgets('$failure retry retains exact event identity and payload', (
      tester,
    ) async {
      final events = <String>[];
      final client = MifuClient(
        client: MockClient((request) async {
          if (request.url.path == '/v1/records/query') {
            return http.Response(jsonEncode(history('plate-a')), 200);
          }
          events.add(request.body);
          if (events.length == 1) {
            if (failure == 'internal_error') {
              return http.Response(
                '{"error":{"code":"internal_error","message":"ack failed"}}',
                500,
              );
            }
            throw http.ClientException('connection lost after send');
          }
          return acknowledgment(
            jsonDecode(request.body) as Map<String, dynamic>,
          );
        }),
      );
      addTearDown(client.close);
      await pumpDialog(tester, client);
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      expect(find.text('重试保存'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '执行结果'))
            .onSelected,
        isNull,
      );
      await tester.tap(find.text('重试保存'));
      await tester.pumpAndSettle();
      expect(events.length, 2);
      expect(events[1], events[0]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'completed execution never preselects quality pass or measurements',
    (tester) async {
      final events = <Map<String, dynamic>>[];
      final attempt = {
        'attemptId': 'attempt-old',
        'recordId': 'record-plate-a',
        'plateId': 'plate-a',
        'candidateId': '1',
        'executionEventId': 'execution-old',
        'execution': {
          'status': 'completed',
          'startedAt': '2026-11-09T01:00:00Z',
          'endedAt': '2026-11-09T02:00:00Z',
          'actualDurationSeconds': null,
          'materialUsedGrams': null,
          'completionPercent': null,
          'failureCategory': null,
          'failureEvidence': null,
        },
        'qualityEventId': null,
        'quality': null,
        'snapshotCapturedAfterStart': true,
        'lastOccurredAt': '2026-11-09T02:00:00Z',
        'trainingEligible': false,
      };
      final client = MifuClient(
        client: MockClient((request) async {
          if (request.url.path == '/v1/records/query') {
            return http.Response(
              jsonEncode(history('plate-a', attempts: [attempt])),
              200,
            );
          }
          final event = jsonDecode(request.body) as Map<String, dynamic>;
          events.add(event);
          return acknowledgment(event);
        }),
      );
      addTearDown(client.close);
      await pumpDialog(tester, client);
      await tester.tap(find.text('新增一次打印 / 重打'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第 1 次 · 已完成 · 未填写').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('事后采集：'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '人工质检'));
      await tester.pumpAndSettle();
      expect(find.text('未填写'), findsOneWidget);
      await tester.tap(find.text('保存记录'));
      await tester.pumpAndSettle();
      expect(events.single['eventType'], 'quality');
      expect(events.single['payload'], {
        'status': null,
        'inspectedAt': null,
        'inspectorId': null,
        'qualityScore': null,
        'defectCodes': [],
        'notes': null,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cluster result history follows current plate without carrying prior selection',
    (tester) async {
      final queried = <String>[];
      final client = MifuClient(
        client: MockClient((request) async {
          expect(request.url.path, '/v1/records/query');
          final query = jsonDecode(request.body) as Map;
          queried.add(query['plateId'] as String);
          expect(query['candidateIds'], ['1', '2']);
          return http.Response(
            jsonEncode(history(query['plateId'] as String)),
            200,
          );
        }),
      );
      addTearDown(client.close);
      await fixtures.pumpCluster(
        tester,
        snapshot: fixtures.fixture(),
        client: client,
      );
      await tester.tap(find.text('P01  外壳'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打印结果'));
      await tester.pumpAndSettle();
      expect(find.text('打印结果 · P1 · 外壳'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('P02  底板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打印结果'));
      await tester.pumpAndSettle();
      expect(find.text('打印结果 · P2 · 底板'), findsOneWidget);
      expect(queried, ['plate-0', 'plate-1']);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'history refuses foreign plate/device evidence including chunked queries',
    () async {
      final client = MifuClient(
        client: MockClient(
          (_) async => http.Response(jsonEncode(history('other-plate')), 200),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.queryRecords(plateId: 'plate-a', candidateIds: {'1'}),
        throwsA(isA<MifuException>()),
      );
      await expectLater(
        client.queryRecords(
          plateId: 'plate-a',
          candidateIds: {for (var i = 0; i < 65; i++) '$i'},
        ),
        throwsA(isA<MifuException>()),
      );
    },
  );

  test(
    'observation binds plan and candidates to one snapshot and preserves unknown evidence',
    () {
      final first = fixtures.fixture();
      final second = fixtures.fixture();
      final plan = first.plates.first;
      expect(
        () => clusterTrainingObservation(
          second,
          plan,
          plan.candidates,
          'request',
        ),
        throwsStateError,
      );
      final captured = clusterTrainingObservation(
        first,
        plan,
        plan.candidates,
        'request',
      );
      expect(
        captured['snapshot_at'],
        first.generatedAt.toUtc().toIso8601String(),
      );
      for (final device in captured['devices'] as List) {
        expect(device['ams_observed'], false);
        expect(device['ams_telemetry_at'], isNull);
        expect(device['setup_seconds'], isNull);
      }
      expect(captured['training_eligible'], false);
    },
  );
}
