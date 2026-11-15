import 'dart:convert';

import 'package:consumable_tracker_desktop/core/services/mifu_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _history() => {
  'trainingEligible': false,
  'attemptsTruncated': false,
  'records': [
    {
      'recordId': 'record-1',
      'plateId': 'plate-1',
      'candidateId': '1',
      'createdAt': '2026-11-09T00:00:00Z',
    },
  ],
  'attempts': [
    {
      'attemptId': 'attempt-1',
      'recordId': 'record-1',
      'plateId': 'plate-1',
      'candidateId': '1',
      'lastOccurredAt': '2026-11-09T03:00:00Z',
      'executionEventId': 'execution-1',
      'execution': {
        'status': 'completed',
        'startedAt': '2026-11-09T01:00:00Z',
        'endedAt': '2026-11-09T02:00:00Z',
        'actualDurationSeconds': 0,
        'materialUsedGrams': null,
        'completionPercent': null,
        'failureCategory': null,
        'failureEvidence': null,
      },
      'qualityEventId': 'quality-1',
      'quality': {
        'status': 'pass',
        'inspectedAt': '2026-11-09T03:00:00Z',
        'inspectorId': 'human-1',
        'qualityScore': 0,
        'defectCodes': ['surface'],
        'notes': null,
      },
      'snapshotCapturedAfterStart': false,
      'trainingEligible': false,
    },
  ],
};

void main() {
  test('history preserves unknown measurements separately from real zero', () {
    final history = MifuRecordHistory.fromJson(_history(), 'plate-1', {'1'});
    final attempt = history.attempts.single;
    expect(attempt['execution']['actualDurationSeconds'], 0);
    expect(attempt['execution']['materialUsedGrams'], isNull);
    expect(attempt['quality']['qualityScore'], 0);
    expect(attempt['quality']['notes'], isNull);
  });

  test(
    'history accepts normalized timestamps with offsets and microseconds',
    () {
      final data = _history();
      data['records'][0]['createdAt'] = '2026-11-09T08:00:00.123456+08:00';
      data['attempts'][0]['lastOccurredAt'] = '2026-11-09T03:00:00.000001Z';
      expect(
        MifuRecordHistory.fromJson(data, 'plate-1', {'1'}).attempts,
        hasLength(1),
      );
    },
  );

  for (final field in ['createdAt', 'lastOccurredAt']) {
    test(
      'single-row history validates $field without relying on sorting',
      () async {
        final data = _history();
        (field == 'createdAt'
                ? data['records'][0]
                : data['attempts'][0])[field] =
            'not-a-time';
        final client = MifuClient(
          client: MockClient((_) async => http.Response(jsonEncode(data), 200)),
        );
        addTearDown(client.close);
        await expectLater(
          client.queryRecords(plateId: 'plate-1', candidateIds: {'1'}),
          throwsA(isA<MifuException>()),
        );
      },
    );
  }

  final invalidPayloads = <String, Map<String, dynamic>>{
    'execution': {
      'status': 'unsupported',
      'startedAt': 123,
      'endedAt': '2026-11-09T02:00:00',
      'actualDurationSeconds': '120',
      'materialUsedGrams': -1,
      'completionPercent': 101,
      'failureCategory': 'unsupported',
      'failureEvidence': ['unexpected'],
    },
    'quality': {
      'status': 'automatic-pass',
      'inspectedAt': '2026-02-30T03:00:00Z',
      'inspectorId': 123,
      'qualityScore': double.infinity,
      'defectCodes': ['unsupported'],
      'notes': {'unexpected': true},
    },
  };
  for (final kind in invalidPayloads.entries) {
    for (final field in kind.value.entries) {
      test('history rejects unsafe ${kind.key}.${field.key}', () {
        final data = _history();
        data['attempts'][0][kind.key][field.key] = field.value;
        expect(
          () => MifuRecordHistory.fromJson(data, 'plate-1', {'1'}),
          throwsA(isA<MifuException>()),
        );
      });
      test('history rejects missing ${kind.key}.${field.key}', () {
        final data = _history();
        (data['attempts'][0][kind.key] as Map).remove(field.key);
        expect(
          () => MifuRecordHistory.fromJson(data, 'plate-1', {'1'}),
          throwsA(isA<MifuException>()),
        );
      });
    }
  }
  for (final invalid in [
    null,
    'surface',
    [123],
    ['surface', 'surface'],
  ]) {
    test('history rejects malformed defect list $invalid', () {
      final data = _history();
      data['attempts'][0]['quality']['defectCodes'] = invalid;
      expect(
        () => MifuRecordHistory.fromJson(data, 'plate-1', {'1'}),
        throwsA(isA<MifuException>()),
      );
    });
  }
  for (final field in ['attemptId', 'executionEventId', 'qualityEventId']) {
    test('history rejects empty $field', () {
      final data = _history();
      data['attempts'][0][field] = ' ';
      expect(
        () => MifuRecordHistory.fromJson(data, 'plate-1', {'1'}),
        throwsA(isA<MifuException>()),
      );
    });
  }
  test('history rejects an empty record identifier', () {
    final data = _history();
    data['records'][0]['recordId'] = '';
    data['attempts'][0]['recordId'] = '';
    expect(
      () => MifuRecordHistory.fromJson(data, 'plate-1', {'1'}),
      throwsA(isA<MifuException>()),
    );
  });
}
