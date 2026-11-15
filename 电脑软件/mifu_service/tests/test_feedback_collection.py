from concurrent.futures import ThreadPoolExecutor
import copy
import json
from pathlib import Path
import tempfile
import unittest

from outcome_collection import OutcomeError, append_feedback


def payload():
    return {'request': {'requestId': 'request-one', 'plate': {'id': 'plate-one'},
                        'candidates': [{'id': 'printer-one'}, {'id': 'printer-two'}]},
            'feedback': 'observed', 'selectedCandidateId': 'printer-one'}


class FeedbackCollectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'feedback.jsonl'

    def test_lost_acknowledgment_and_restart_reuse_one_record(self):
        first = append_feedback(self.path, payload())
        retry = append_feedback(Path(str(self.path)), copy.deepcopy(payload()))
        self.assertEqual(first['recordId'], retry['recordId'])
        self.assertFalse(first['duplicate'])
        self.assertTrue(retry['duplicate'])
        self.assertFalse(retry['trainingEligible'])
        self.assertEqual(1, len(self.path.read_text(encoding='utf-8').splitlines()))

    def test_concurrent_deliveries_do_not_fork_feedback(self):
        with ThreadPoolExecutor(max_workers=8) as executor:
            results = list(executor.map(lambda _: append_feedback(self.path, payload()), range(12)))
        self.assertEqual(1, len({value['recordId'] for value in results}))
        self.assertEqual(1, sum(not value['duplicate'] for value in results))

    def test_new_snapshot_or_selection_stays_a_distinct_observation(self):
        first = append_feedback(self.path, payload())
        selection = payload()
        selection['selectedCandidateId'] = 'printer-two'
        second = append_feedback(self.path, selection)
        snapshot = payload()
        snapshot['request']['requestId'] = 'request-two'
        third = append_feedback(self.path, snapshot)
        self.assertEqual(3, len({value['recordId'] for value in (first, second, third)}))

    def test_old_records_without_digest_are_not_duplicated(self):
        old = {**payload(), 'recordId': 'legacy-id', 'createdAt': '2026-11-01T01:00:00Z',
               'source': 'client_feedback_unverified', 'trainingEligible': False}
        self.path.write_text(json.dumps(old) + '\n', encoding='utf-8')
        self.assertEqual('legacy-id', append_feedback(self.path, payload())['recordId'])

    def test_partial_or_changed_ledger_stops_without_appending(self):
        append_feedback(self.path, payload())
        original = self.path.read_bytes()
        row = json.loads(original)
        row['selectedCandidateId'] = 'printer-two'
        self.path.write_text(json.dumps(row) + '\n', encoding='utf-8')
        changed = self.path.read_bytes()
        with self.assertRaises(OutcomeError) as error:
            append_feedback(self.path, payload())
        self.assertEqual('corrupt_log', error.exception.code)
        self.assertEqual(changed, self.path.read_bytes())
        self.path.write_bytes(original[:-1])
        with self.assertRaises(OutcomeError):
            append_feedback(self.path, payload())
        self.assertEqual(original[:-1], self.path.read_bytes())


if __name__ == '__main__':
    unittest.main()
