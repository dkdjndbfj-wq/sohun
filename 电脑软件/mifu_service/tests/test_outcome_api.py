"""Actual loopback HTTP tests for unconfigured-model outcome collection."""
from __future__ import annotations

import copy
from datetime import datetime, timedelta, timezone
import http.client
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mifu_server import LocalServer, MifuService


class NoGpuSampler:
    def sample(self):
        return {'gpuName': None, 'utilizationPercent': None, 'memoryUsedMb': None,
                'memoryTotalMb': None, 'temperatureC': None}


class OutcomeHttpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.service = MifuService(data_dir=Path(self.temp.name), sampler=NoGpuSampler())
        self.server = LocalServer(0, self.service)
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={'poll_interval': .01}, daemon=True)
        self.thread.start()
        self.now = datetime.now(timezone.utc)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def send(self, path, body=None, method='POST'):
        connection = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=4)
        try:
            data = None if body is None else json.dumps(body)
            headers = {} if data is None else {'Content-Type': 'application/json'}
            connection.request(method, path, data, headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def decision_request(self, plate='plate-01'):
        return {'requestId': str(uuid.uuid4()), 'plate': {'id': plate, 'plate_index': 1},
                'candidates': [{'id': 'printer-01', 'features': {'queueMinutes': 1}},
                               {'id': 'printer-02', 'features': {'queueMinutes': 2}}]}

    def record(self, plate='plate-01', candidate='printer-01', observation=False):
        request = self.decision_request(plate)
        body = {'request': request, 'feedback': 'accepted', 'selectedCandidateId': candidate}
        if observation:
            body['observation'] = {'schema': 'mifu-observation-v1', 'source': 'desktop_observation',
                                   'requestId': request['requestId'], 'plate_id': plate, 'plate_index': 1,
                                   'training_eligible': False, 'artifact_sha256': None, 'geometry': {},
                                   'snapshot_at': self.now.isoformat(),
                                   'candidate_ids': ['printer-01', 'printer-02'], 'ams_units': [], 'feed_slots': [],
                                   'devices': [{'candidate_id': identifier, 'ams_observed': False,
                                                'telemetry_at': None, 'ams_telemetry_at': None}
                                               for identifier in ('printer-01', 'printer-02')]}
        status, response = self.send('/v1/records', body)
        self.assertEqual(201, status, response)
        self.assertFalse(response['trainingEligible'])
        return response['recordId']

    def execution(self, record, plate='plate-01', candidate='printer-01'):
        return {'schemaVersion': 1, 'eventId': str(uuid.uuid4()), 'attemptId': str(uuid.uuid4()),
                'recordId': record, 'plateId': plate, 'candidateId': candidate,
                'eventType': 'execution', 'occurredAt': self.now.isoformat(),
                'source': {'kind': 'manual_entry', 'sourceId': 'desktop-result-form', 'actorId': 'test-operator'},
                'payload': {'status': 'completed', 'startedAt': (self.now - timedelta(hours=1)).isoformat(),
                            'endedAt': (self.now - timedelta(minutes=5)).isoformat(),
                            'actualDurationSeconds': None, 'materialUsedGrams': None,
                            'completionPercent': None, 'failureCategory': None, 'failureEvidence': None}}

    def query(self, plate='plate-01', candidates=None):
        status, body = self.send('/v1/records/query', {'plateId': plate,
                                                    'candidateIds': candidates or ['printer-01']})
        self.assertEqual(200, status, body)
        return body

    def test_repeated_snapshot_delivery_reuses_feedback_record(self):
        body = {'request': self.decision_request(), 'feedback': 'observed',
                'selectedCandidateId': 'printer-01'}
        first_status, first = self.send('/v1/records', body)
        retry_status, retry = self.send('/v1/records', body)
        self.assertEqual((201, 201), (first_status, retry_status))
        self.assertEqual(first['recordId'], retry['recordId'])
        self.assertTrue(retry['duplicate'])
        self.assertEqual(1, len(self.query()['records']))

    def test_unconfigured_model_still_collects_and_queries_without_inference(self):
        status, health = self.send('/health', method='GET')
        self.assertEqual(200, status)
        self.assertEqual('unconfigured', health['trainingState'])
        self.assertEqual(503, self.send('/v1/decisions', self.decision_request())[0])
        record = self.record()
        event = self.execution(record)
        status, body = self.send('/v1/outcomes', event)
        self.assertEqual(201, status, body)
        self.assertFalse(body['trainingEligible'])
        self.assertIsNone(self.service.agent)
        self.assertEqual('unconfigured', self.service.state)
        query = self.query()
        self.assertEqual([record], [row['recordId'] for row in query['records']])
        self.assertEqual('completed', query['attempts'][0]['execution']['status'])
        self.assertFalse(query['trainingEligible'])

    def test_queries_filter_current_plate_and_visible_selected_candidates(self):
        ids = []
        for plate, candidate in (('plate-01', 'printer-01'), ('plate-01', 'printer-02'), ('plate-02', 'printer-01')):
            record = self.record(plate, candidate)
            ids.append(record)
            status, body = self.send('/v1/outcomes', self.execution(record, plate, candidate))
            self.assertEqual(201, status, body)
        visible = self.query()
        self.assertEqual([ids[0]], [row['recordId'] for row in visible['records']])
        self.assertEqual([ids[0]], [row['recordId'] for row in visible['attempts']])
        both = self.query(candidates=['printer-01', 'printer-02'])
        self.assertEqual(set(ids[:2]), {row['recordId'] for row in both['records']})
        self.assertEqual(set(ids[:2]), {row['recordId'] for row in both['attempts']})
        self.assertEqual([], self.query('unknown-plate')['records'])

    def test_unknown_record_and_identity_mismatch_return_client_errors(self):
        record = self.record()
        for field, value, expected, code in (
            ('recordId', 'unknown-record', 404, 'feedback_not_found'),
            ('plateId', 'wrong-plate', 409, 'identity_conflict'),
            ('candidateId', 'printer-02', 409, 'identity_conflict'),
        ):
            event = self.execution(record)
            event[field] = value
            status, body = self.send('/v1/outcomes', event)
            self.assertEqual(expected, status, body)
            self.assertEqual(code, body['error']['code'])
        self.assertFalse((Path(self.temp.name) / 'outcomes.jsonl').exists())

    def test_idempotent_retry_does_not_append_another_outcome(self):
        record = self.record()
        event = self.execution(record)
        first_status, first = self.send('/v1/outcomes', event)
        second_status, second = self.send('/v1/outcomes', event)
        self.assertEqual((201, 201), (first_status, second_status))
        self.assertFalse(first['duplicate'])
        self.assertTrue(second['duplicate'])
        self.assertEqual(1, len((Path(self.temp.name) / 'outcomes.jsonl').read_text(encoding='utf-8').splitlines()))
        event['payload']['materialUsedGrams'] = 20
        status, body = self.send('/v1/outcomes', event)
        self.assertEqual(409, status)
        self.assertEqual('event_conflict', body['error']['code'])

    def test_finish_never_generates_quality_and_manual_quality_remains_separate(self):
        record = self.record()
        event = self.execution(record)
        self.assertEqual(201, self.send('/v1/outcomes', event)[0])
        before = self.query()['attempts'][0]
        self.assertIsNone(before['quality'])
        self.assertIsNone(before['qualityEventId'])
        quality = copy.deepcopy(event)
        quality.update(eventId=str(uuid.uuid4()), eventType='quality')
        quality['payload'] = {'status': 'pass', 'inspectedAt': (self.now - timedelta(minutes=1)).isoformat(),
                              'inspectorId': 'test-operator', 'qualityScore': None, 'defectCodes': [], 'notes': None}
        automatic = copy.deepcopy(quality)
        automatic['source'] = {'kind': 'device_telemetry', 'sourceId': 'device'}
        self.assertEqual(422, self.send('/v1/outcomes', automatic)[0])
        self.assertEqual(201, self.send('/v1/outcomes', quality)[0])
        after = self.query()['attempts'][0]
        self.assertEqual('pass', after['quality']['status'])
        self.assertEqual(event['eventId'], after['executionEventId'])
        self.assertEqual(quality['eventId'], after['qualityEventId'])
        self.assertFalse(after['trainingEligible'])

    def test_invalid_payload_states_measurements_and_query_scope_are_rejected(self):
        record = self.record()
        for field, value in (('status', 'success'), ('materialUsedGrams', True),
                             ('completionPercent', 101), ('actualDurationSeconds', -1),
                             ('startedAt', '2026-11-01T12:00:00')):
            event = self.execution(record)
            event['payload'][field] = value
            status, body = self.send('/v1/outcomes', event)
            self.assertEqual(422, status, body)
        event = self.execution(record)
        event['trainingEligible'] = True
        self.assertEqual(422, self.send('/v1/outcomes', event)[0])
        for body in ({'plateId': 'plate-01', 'candidateIds': []},
                     {'plateId': 'plate-01', 'candidateIds': ['printer-01', 'printer-01']},
                     {'plateId': 'plate-01', 'candidateIds': ['printer-01'], 'path': 'outside'}):
            self.assertEqual(422, self.send('/v1/records/query', body)[0])
        self.assertFalse((Path(self.temp.name) / 'outcomes.jsonl').exists())

    def test_historical_outcome_flags_late_snapshot_in_response_and_query(self):
        record = self.record(observation=True)
        status, body = self.send('/v1/outcomes', self.execution(record))
        self.assertEqual(201, status, body)
        self.assertTrue(body['snapshotCapturedAfterStart'])
        self.assertEqual('captured_after_start', body['decision_snapshot_timing']['status'])
        self.assertEqual({'feedbackCreatedAt', 'observationSnapshotAt'}, set(body['decision_snapshot_timing']['lateSources']))
        self.assertFalse(body['decision_snapshot_timing']['prospectiveTrainingUseAllowed'])
        summary = self.query()['attempts'][0]
        self.assertTrue(summary['snapshotCapturedAfterStart'])
        self.assertFalse(summary['trainingEligible'])
        self.assertIn('decision_snapshot_captured_after_print_start_exclude_from_prospective_labels', summary['reviewReasons'])


if __name__ == '__main__':
    unittest.main()
