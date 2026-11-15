from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from outcome_collection import (OutcomeError, append_outcome, normalize_event,
                                read_active_attempts, read_attempt_history)

NOW = datetime(2026, 11, 12, 12, tzinfo=timezone.utc)


def feedback_record(record_id='record-01', selected='printer-01'):
    return {'recordId': record_id, 'createdAt': '2026-11-01T01:00:00Z',
            'selectedCandidateId': selected, 'trainingEligible': False, 'feedback': 'accepted' if selected else 'observed',
            'request': {'requestId': 'request-01', 'plate': {'id': 'plate-01', 'taskId': 'task-01'},
                        'candidates': [{'id': 'printer-01', 'features': {'queueMinutes': 1}},
                                       {'id': 'printer-02', 'features': {'queueMinutes': 5}}]}}


def execution(event_id='event-01', attempt='attempt-01', status='completed'):
    terminal = status in {'completed', 'failed', 'cancelled'}
    return {'schemaVersion': 1, 'eventId': event_id, 'attemptId': attempt, 'recordId': 'record-01',
            'plateId': 'plate-01', 'candidateId': 'printer-01', 'eventType': 'execution',
            'occurredAt': '2026-11-01T03:00:00Z',
            'source': {'kind': 'device_telemetry', 'sourceId': 'local-device-adapter'},
            'payload': {'status': status, 'startedAt': None if status in {'queued', 'unknown'} else '2026-11-01T02:00:00Z',
                        'endedAt': '2026-11-01T03:00:00Z' if terminal else None,
                        'actualDurationSeconds': None if status in {'queued', 'unknown'} else 3500,
                        'materialUsedGrams': None, 'completionPercent': 100 if status == 'completed' else None,
                        'failureCategory': None, 'failureEvidence': None}}


def quality(event_id='quality-01', status='pass'):
    event = execution(event_id)
    event.update(eventType='quality', occurredAt='2026-11-01T04:00:00Z',
                 source={'kind': 'manual_entry', 'sourceId': 'desktop-form', 'actorId': 'operator-01'})
    inspected = status in {'pass', 'rework', 'reject'}
    event['payload'] = {'status': status, 'inspectedAt': '2026-11-01T03:30:00Z' if inspected else None,
                        'inspectorId': 'operator-01' if inspected else None,
                        'qualityScore': 80 if inspected else None,
                        'defectCodes': [], 'notes': None}
    return event


class OutcomeCollectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.feedback = Path(self.temp.name) / 'feedback.jsonl'
        self.outcomes = Path(self.temp.name) / 'outcomes.jsonl'
        self.write_feedback(feedback_record())

    def write_feedback(self, *records):
        self.feedback.write_text(''.join(json.dumps(row) + '\n' for row in records), encoding='utf-8')

    def append(self, event):
        return append_outcome(self.feedback, self.outcomes, event, now=NOW)

    def assert_error(self, code, callback):
        with self.assertRaises(OutcomeError) as raised:
            callback()
        self.assertEqual(code, raised.exception.code, str(raised.exception))

    def test_completion_is_observation_not_quality_or_training_label(self):
        response = self.append(execution())
        self.assertFalse(response['duplicate'])
        self.assertFalse(response['trainingEligible'])
        rows = read_attempt_history(self.outcomes, 'attempt-01')
        self.assertEqual(1, len(rows))
        self.assertEqual('execution', rows[0]['eventType'])
        self.assertIsNone(rows[0]['payload']['materialUsedGrams'])
        self.assertFalse(rows[0]['automaticFaultAttribution'])
        self.assertEqual('unverified_client_claim', rows[0]['sourceVerification'])
        self.assertEqual(64, len(rows[0]['binding']['recordSha256']))
        self.assertNotIn('quality', rows[0])

    def test_identical_delivery_is_idempotent_with_normalized_optional_fields(self):
        event = execution()
        self.append(event)
        before = self.outcomes.read_bytes()
        event.update(supersedesEventId=None, correctionReason=None)
        event['occurredAt'] = '2026-11-01T11:00:00+08:00'
        result = self.append(event)
        self.assertTrue(result['duplicate'])
        self.assertEqual(before, self.outcomes.read_bytes())

    def test_same_event_id_different_payload_is_rejected(self):
        event = execution()
        self.append(event)
        event['payload']['materialUsedGrams'] = 17
        self.assert_error('event_conflict', lambda: self.append(event))
        self.assertEqual(1, len(read_attempt_history(self.outcomes, 'attempt-01')))

    def test_threaded_duplicate_submissions_append_once(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: self.append(execution()), range(24)))
        self.assertEqual(1, sum(not item['duplicate'] for item in results))
        self.assertEqual(1, len(read_attempt_history(self.outcomes, 'attempt-01')))

    def test_new_attempt_is_separate_and_does_not_reopen_original(self):
        self.append(execution(status='failed'))
        restarted = execution('event-02', status='running')
        restarted['occurredAt'] = '2026-11-01T04:00:00Z'
        self.assert_error('transition_conflict', lambda: self.append(restarted))
        restarted['attemptId'] = 'attempt-02'
        self.append(restarted)
        self.assertEqual(1, len(read_attempt_history(self.outcomes, 'attempt-01')))
        self.assertEqual(1, len(read_attempt_history(self.outcomes, 'attempt-02')))

    def test_correction_appends_and_preserves_original(self):
        self.append(execution())
        correction = execution('event-correction', status='failed')
        correction.update(occurredAt='2026-11-01T05:00:00Z', supersedesEventId='event-01',
                          correctionReason='Machine status was reported incorrectly',
                          source={'kind': 'manual_entry', 'sourceId': 'desktop-form', 'actorId': 'operator-01'})
        self.append(correction)
        rows = read_attempt_history(self.outcomes, 'attempt-01')
        self.assertEqual(['completed', 'failed'], [row['payload']['status'] for row in rows])
        self.assertEqual('event-01', rows[1]['supersedesEventId'])
        self.assertTrue(all(row['trainingEligible'] is False for row in rows))
        stale = copy.deepcopy(correction)
        stale['eventId'] = 'correction-again'
        self.assert_error('correction_conflict', lambda: self.append(stale))

    def test_correction_target_requires_matching_attempt_type_and_human_reason(self):
        self.append(execution())
        event = execution('event-02')
        event.update(supersedesEventId='event-01', correctionReason='Correction')
        self.assert_error('correction_conflict', lambda: self.append(event))
        event['source'] = {'kind': 'manual_entry', 'sourceId': 'form', 'actorId': 'operator'}
        event['attemptId'] = 'other-attempt'
        self.assert_error('correction_conflict', lambda: self.append(event))
        event['correctionReason'] = None
        self.assert_error('invalid_event', lambda: self.append(event))

    def test_original_plate_candidate_and_selection_are_frozen(self):
        for field, value in (('plateId', 'other-plate'), ('candidateId', 'unknown-printer'), ('candidateId', 'printer-02')):
            event = execution()
            event[field] = value
            self.assert_error('identity_conflict', lambda: self.append(event))
        self.append(execution())
        self.write_feedback(feedback_record(selected=None))
        event = execution('event-02')
        event['candidateId'] = 'printer-02'
        self.assert_error('attempt_conflict', lambda: self.append(event))

    def test_observed_feedback_without_selection_can_bind_only_original_candidate(self):
        self.write_feedback(feedback_record(selected=None))
        event = execution()
        event['candidateId'] = 'printer-02'
        self.append(event)
        self.assertEqual('printer-02', read_attempt_history(self.outcomes, 'attempt-01')[0]['binding']['candidateId'])

    def test_feedback_snapshot_mutation_is_detected_even_on_retry(self):
        self.append(execution())
        changed = feedback_record()
        changed['request']['plate']['taskId'] = 'different-task'
        self.write_feedback(changed)
        self.assert_error('feedback_changed', lambda: self.append(execution()))
        self.assert_error('feedback_changed', lambda: self.append(execution('event-02')))

    def test_missing_duplicate_feedback_and_same_file_paths_are_rejected(self):
        event = execution()
        event['recordId'] = 'missing'
        self.assert_error('feedback_not_found', lambda: self.append(event))
        self.write_feedback(feedback_record(), feedback_record())
        self.assert_error('corrupt_log', lambda: self.append(execution()))
        self.assert_error('invalid_path', lambda: append_outcome(self.feedback, self.feedback, execution(), now=NOW))

    def test_human_quality_does_not_follow_automatically_from_device(self):
        self.assert_error('attempt_conflict', lambda: self.append(quality()))
        self.append(execution())
        event = quality()
        event['source'] = {'kind': 'device_telemetry', 'sourceId': 'device'}
        self.assert_error('invalid_event', lambda: self.append(event))
        self.append(quality())
        rows = read_attempt_history(self.outcomes, 'attempt-01')
        self.assertEqual(['execution', 'quality'], [row['eventType'] for row in rows])
        self.assertFalse(rows[-1]['trainingEligible'])

    def test_uninspected_unknown_null_and_no_quality_are_preserved_distinctly(self):
        self.append(execution())
        for index, status in enumerate(('not_inspected', 'unknown', None)):
            event = quality('quality-' + str(index), status)
            self.append(event)
        rows = read_attempt_history(self.outcomes, 'attempt-01')
        self.assertEqual(['not_inspected', 'unknown', None], [row['payload']['status'] for row in rows[1:]])
        self.append(execution('another-event', 'attempt-without-quality'))
        self.assertEqual(['execution'], [row['eventType'] for row in read_attempt_history(self.outcomes, 'attempt-without-quality')])

    def test_cancelled_and_failure_do_not_default_to_device_fault(self):
        for state in ('failed', 'cancelled'):
            event = execution('event-' + state, 'attempt-' + state, state)
            event['payload']['startedAt'] = None
            event['payload']['actualDurationSeconds'] = None
            self.append(event)
            row = read_attempt_history(self.outcomes, 'attempt-' + state)[0]
            self.assertEqual(state, row['payload']['status'])
            self.assertIsNone(row['payload']['failureCategory'])
            self.assertFalse(row['automaticFaultAttribution'])
        event = execution('attribution', 'attribution', 'failed')
        event['payload']['failureCategory'] = 'device'
        self.assert_error('invalid_event', lambda: self.append(event))
        event['payload']['failureEvidence'] = 'Reported toolhead alarm; root cause still unreviewed'
        self.append(event)

    def test_status_times_and_terminal_state_are_strict(self):
        for key, value in (('status', 'success'), ('startedAt', '2026-11-01T02:00:00'),
                           ('endedAt', '2026-10-31T02:00:00Z'), ('completionPercent', 99), ('actualDurationSeconds', 5000)):
            event = execution()
            event['payload'][key] = value
            self.assert_error('invalid_event', lambda: self.append(event))
        event = execution()
        event['occurredAt'] = '2026-12-01T02:00:00Z'
        self.assert_error('invalid_event', lambda: self.append(event))
        self.append(execution(status='running'))
        unknown = execution('unknown-event', status='unknown')
        self.append(unknown)
        self.assert_error('transition_conflict', lambda: self.append(execution('back-to-queued', status='queued')))
        early = execution('early-event')
        early['occurredAt'] = '2026-11-01T02:30:00Z'
        early['payload']['endedAt'] = '2026-11-01T02:30:00Z'
        early['payload']['actualDurationSeconds'] = 1700
        self.assert_error('out_of_order', lambda: self.append(early))

    def test_invalid_numeric_values_are_not_coerced(self):
        for value in (True, -1, float('nan'), float('inf'), '2', 10 ** 1000):
            event = execution()
            event['payload']['materialUsedGrams'] = value
            self.assert_error('invalid_event', lambda: self.append(event))
        event = execution()
        event['payload']['materialUsedGrams'] = 0
        self.append(event)
        self.assertEqual(0, read_attempt_history(self.outcomes, 'attempt-01')[0]['payload']['materialUsedGrams'])

    def test_quality_requires_human_time_and_cannot_predate_execution(self):
        self.append(execution())
        for field, value in (('inspectorId', None), ('inspectedAt', None), ('qualityScore', True), ('defectCodes', ['made-up-code'])):
            event = quality()
            event['payload'][field] = value
            self.assert_error('invalid_event', lambda: self.append(event))
        event = quality()
        event['payload']['inspectedAt'] = '2026-11-01T01:30:00Z'
        self.assert_error('invalid_event', lambda: self.append(event))
        event = quality(status='not_inspected')
        event['payload']['qualityScore'] = 80
        self.assert_error('invalid_event', lambda: self.append(event))

    def test_unknown_source_fields_training_flags_and_duplicate_json_are_rejected(self):
        event = execution()
        event['trainingEligible'] = True
        self.assert_error('invalid_event', lambda: self.append(event))
        event = execution()
        event['source']['kind'] = 'model_inference'
        self.assert_error('invalid_event', lambda: self.append(event))
        event = execution()
        event['source'] = {'kind': 'manual_entry', 'sourceId': 'desktop'}
        self.assert_error('invalid_event', lambda: self.append(event))
        self.feedback.write_text('{"recordId":"record-01","recordId":"record-01"}\n', encoding='utf-8')
        self.assert_error('corrupt_log', lambda: self.append(execution()))

    def test_partial_or_modified_ledger_is_not_repaired_or_appended(self):
        self.append(execution())
        original = self.outcomes.read_bytes()
        self.outcomes.write_bytes(original + b'{"incomplete":')
        before = self.outcomes.read_bytes()
        self.assert_error('corrupt_log', lambda: self.append(execution('event-02')))
        self.assertEqual(before, self.outcomes.read_bytes())
        row = json.loads(original)
        row['payload']['status'] = 'failed'
        self.outcomes.write_text(json.dumps(row) + '\n', encoding='utf-8')
        self.assert_error('corrupt_log', lambda: read_attempt_history(self.outcomes, 'attempt-01'))

    def test_identity_cannot_drift_to_another_feedback_record(self):
        self.write_feedback(feedback_record(), feedback_record('record-02'))
        self.append(execution())
        event = execution('event-02')
        event['recordId'] = 'record-02'
        self.assert_error('attempt_conflict', lambda: self.append(event))

    def test_active_summary_follows_corrections_and_keeps_explicit_null_distinct(self):
        self.append(execution())
        self.append(quality())
        corrected = quality('quality-correction', None)
        corrected.update(supersedesEventId='quality-01', correctionReason='Inspection was recorded on the wrong form')
        self.append(corrected)
        self.append(execution('other-execution', 'other-attempt'))
        summaries = read_active_attempts(self.outcomes, {'record-01'})
        by_id = {value['attemptId']: value for value in summaries}
        self.assertEqual('quality-correction', by_id['attempt-01']['qualityEventId'])
        self.assertIsNone(by_id['attempt-01']['quality']['status'])
        self.assertEqual('event-01', by_id['attempt-01']['executionEventId'])
        self.assertIsNone(by_id['other-attempt']['quality'])
        self.assertIsNone(by_id['other-attempt']['qualityEventId'])
        self.assertTrue(all(value['trainingEligible'] is False for value in summaries))
        self.assertEqual(3, len(read_attempt_history(self.outcomes, 'attempt-01')))

    def test_active_summary_filters_records_and_missing_log(self):
        self.assertEqual([], read_active_attempts(self.outcomes, {'record-01'}))
        self.append(execution())
        self.assertEqual([], read_active_attempts(self.outcomes, {'other-record'}))
        self.assertEqual([], read_active_attempts(self.outcomes, set()))
        self.assert_error('invalid_event', lambda: read_active_attempts(self.outcomes, ['record-01']))

    def test_active_summary_sorts_fractional_seconds_as_times(self):
        self.append(execution())
        later = execution('later-event', 'later-attempt')
        later['occurredAt'] = '2026-11-01T03:00:00.5Z'
        self.append(later)
        self.assertEqual('later-attempt', read_active_attempts(self.outcomes, {'record-01'})[0]['attemptId'])

    def test_queued_measurements_cannot_claim_printing_activity(self):
        for field in ('actualDurationSeconds', 'materialUsedGrams', 'completionPercent'):
            event = execution(status='queued')
            event['payload'][field] = 1
            self.assert_error('invalid_event', lambda: self.append(event))

    def test_late_feedback_or_observation_is_retrospective_not_a_predecision_label(self):
        for name in ('feedbackCreatedAt', 'observationSnapshotAt'):
            with self.subTest(name=name):
                self.outcomes = Path(self.temp.name) / (name + '.jsonl')
                record = feedback_record()
                record['observation'] = {'snapshot_at': '2026-11-01T01:30:00Z'}
                if name == 'feedbackCreatedAt':
                    record['createdAt'] = '2026-11-01T02:30:00Z'
                else:
                    record['observation']['snapshot_at'] = '2026-11-01T02:30:00Z'
                self.write_feedback(record)
                response = self.append(execution())
                self.assertTrue(response['snapshotCapturedAfterStart'])
                self.assertFalse(response['trainingEligible'])
                self.assertEqual('captured_after_start', response['decision_snapshot_timing']['status'])
                self.assertEqual([name], response['decision_snapshot_timing']['lateSources'])
                self.assertFalse(response['decision_snapshot_timing']['prospectiveTrainingUseAllowed'])
                self.append(quality())
                correction = quality('quality-revision', 'rework')
                correction.update(supersedesEventId='quality-01', correctionReason='Updated human inspection')
                self.append(correction)
                summary = read_active_attempts(self.outcomes, {'record-01'})[0]
                self.assertTrue(summary['snapshotCapturedAfterStart'])
                self.assertIn('decision_snapshot_captured_after_print_start_exclude_from_prospective_labels', summary['reviewReasons'])

    def test_snapshot_timing_unknown_or_equal_is_not_declared_prospective(self):
        response = self.append(execution())
        self.assertIsNone(response['snapshotCapturedAfterStart'])
        self.assertEqual('unknown', response['decision_snapshot_timing']['status'])
        for suffix, captured, expected in (
            ('earlier', '2026-11-01T01:30:00Z', False),
            ('equal', '2026-11-01T02:00:00Z', None),
            ('invalid', 'not-a-date', None),
        ):
            self.outcomes = Path(self.temp.name) / (suffix + '.jsonl')
            record = feedback_record()
            record['observation'] = {'snapshot_at': captured}
            self.write_feedback(record)
            response = self.append(execution())
            self.assertIs(expected, response['snapshotCapturedAfterStart'])
            self.assertFalse(response['decision_snapshot_timing']['prospectiveTrainingUseAllowed'])

    def test_snapshot_timing_remains_unknown_when_actual_start_is_unknown(self):
        response = self.append(execution(status='cancelled') | {'payload': execution(status='cancelled')['payload'] | {'startedAt': None, 'actualDurationSeconds': None}})
        self.assertIsNone(response['snapshotCapturedAfterStart'])
        self.assertEqual('unknown', response['decision_snapshot_timing']['status'])


if __name__ == '__main__':
    unittest.main()
