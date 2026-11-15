import 'dart:async';
import 'dart:convert';

import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A transport that remains pending until the request itself is aborted.
class _StalledClient extends http.BaseClient {
  _StalledClient({required this.beforeHeaders});

  final bool beforeHeaders;
  bool aborted = false;
  bool responseCancelled = false;
  late http.BaseRequest sentRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sentRequest = request;
    final response = Completer<http.StreamedResponse>();
    final body = StreamController<List<int>>(
      onCancel: () => responseCancelled = true,
    );
    if (!beforeHeaders) {
      response.complete(http.StreamedResponse(body.stream, 200));
    }
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.then((_) {
          aborted = true;
          if (beforeHeaders) {
            response.completeError(http.RequestAbortedException(request.url));
          } else {
            body.addError(http.RequestAbortedException(request.url));
          }
          unawaited(body.close());
        }),
      );
    }
    return response.future;
  }
}

void main() {
  const request = MifuDecisionRequest(
    requestId: 'test-1',
    plate: {'id': 'plate-1'},
    candidates: [
      {
        'id': '1',
        'features': {'waitSeconds': 0},
      },
      {
        'id': '2',
        'features': {'waitSeconds': 60},
      },
    ],
  );
  Map<String, dynamic> response() => {
    'requestId': 'test-1',
    'trainingState': 'ready',
    'choice': '1',
    'probabilities': {'1': .7, '2': .3},
    'elapsedMs': 12,
    'model': {
      'name': 'Mifu',
      'version': 'mifu-test',
      'checkpointConfigured': true,
    },
  };

  test(
    'only allows literal loopback and rejects endpoint credentials or redirects',
    () {
      for (final url in [
        'http://0.0.0.0:27961',
        'http://localhost:27961',
        'https://example.com',
        'http://name:secret@127.0.0.1',
        'http://127.0.0.1/path',
      ]) {
        expect(() => MifuClient(endpoint: Uri.parse(url)), throwsArgumentError);
      }
    },
  );

  test('sends contract without credentials embedded in payload', () async {
    final client = MifuClient(
      token: 'local-test',
      client: MockClient((sent) async {
        expect(sent.url.path, '/v1/decisions');
        expect(sent.followRedirects, isFalse);
        expect(sent.headers['Authorization'], 'Bearer local-test');
        expect(jsonDecode(sent.body), request.toJson());
        return http.Response(jsonEncode(response()), 200);
      }),
    );
    addTearDown(client.close);
    final decision = await client.decide(request);
    expect(decision.choice, '1');
    expect(decision.probabilities['1'], .7);
    expect(decision.version, 'mifu-test');
  });

  test(
    'never substitutes model scores while checkpoint is unconfigured',
    () async {
      final client = MifuClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {'code': 'model_unconfigured', 'message': 'Mifu 尚未训练'},
              'trainingState': 'unconfigured',
            }),
            503,
          ),
        ),
      );
      addTearDown(client.close);
      await expectLater(client.decide(request), throwsA(isA<MifuException>()));
    },
  );

  for (final fault in [
    'request',
    'choice',
    'missing',
    'extra',
    'negative',
    'sum',
    'infinite',
    'version',
    'base',
  ]) {
    test('rejects invalid model result: $fault', () {
      final data = response();
      switch (fault) {
        case 'request':
          data['requestId'] = 'old';
        case 'choice':
          data['choice'] = 'invented';
        case 'missing':
          data['probabilities'] = {'1': 1};
        case 'extra':
          data['probabilities'] = {'1': .7, '2': .2, '3': .1};
        case 'negative':
          data['probabilities'] = {'1': 1.1, '2': -.1};
        case 'sum':
          data['probabilities'] = {'1': .5, '2': .1};
        case 'infinite':
          data['probabilities'] = {'1': double.infinity, '2': 0};
        case 'version':
          (data['model'] as Map)['version'] = '';
        case 'base':
          (data['model'] as Map)['checkpointConfigured'] = false;
      }
      expect(
        () => MifuDecision.fromJson(data, request: request),
        throwsA(isA<MifuException>()),
      );
    });
  }

  test(
    'health needs loaded dedicated checkpoint; GPU presence is not inference device',
    () {
      final health = MifuHealth.fromJson({
        'service': 'mifu',
        'apiVersion': 1,
        'status': 'ok',
        'trainingState': 'unconfigured',
        'model': {
          'name': 'Mifu',
          'version': null,
          'checkpointConfigured': false,
          'device': null,
        },
        'host': {
          'gpuName': 'RTX 4070',
          'utilizationPercent': 12,
          'memoryUsedMb': null,
        },
      });
      expect(health.ready, isFalse);
      expect(health.label, '待训练');
      expect(health.device, isNull);
      expect(health.gpuName, 'RTX 4070');
      expect(health.memoryUsedMb, isNull);
      expect(
        () => MifuHealth.fromJson({
          'service': 'mifu',
          'apiVersion': 1,
          'status': 'ok',
          'trainingState': 'ready',
          'model': {
            'name': 'Mifu',
            'version': null,
            'checkpointConfigured': false,
          },
        }),
        throwsA(isA<MifuException>()),
      );
    },
  );

  test(
    'feedback is an observation and not an automatic training label',
    () async {
      final client = MifuClient(
        client: MockClient((sent) async {
          expect(sent.url.path, '/v1/records');
          final body = jsonDecode(sent.body) as Map;
          expect(body['feedback'], 'observed');
          expect(body['decision'], isNull);
          expect(body['selectedCandidateId'], '2');
          return http.Response(
            '{"recordId":"record-1","trainingEligible":false}',
            201,
          );
        }),
      );
      addTearDown(client.close);
      expect(
        await client.record(request: request, selectedCandidateId: '2'),
        'record-1',
      );
      await expectLater(
        client.record(request: request, selectedCandidateId: 'foreign'),
        throwsA(isA<MifuException>()),
      );
    },
  );

  test('single candidate bypass cannot be mislabeled as inference', () {
    const single = MifuDecisionRequest(
      requestId: 'one',
      plate: {'id': 'plate-1'},
      candidates: [
        {'id': '1', 'features': {}},
      ],
    );
    expect(single.validate, throwsA(isA<MifuException>()));
  });

  for (final beforeHeaders in [true, false]) {
    testWidgets(
      'health timeout aborts a stalled ${beforeHeaders ? 'request' : 'response body'}',
      (tester) async {
        final transport = _StalledClient(beforeHeaders: beforeHeaders);
        final client = MifuClient(client: transport);
        addTearDown(client.close);
        final result = expectLater(
          client.health(),
          throwsA(
            isA<MifuException>().having(
              (error) => error.message,
              'message',
              contains('响应超时'),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await result;
        expect(transport.aborted, isTrue);
        if (!beforeHeaders) expect(transport.responseCancelled, isTrue);
      },
    );
  }
}
