import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_observation import ObservationError, validate_observation


def fixture():
    request = {'requestId': 'r', 'plate': {'id': 'p', 'plate_index': 1},
               'candidates': [{'id': 'a'}, {'id': 'b'}]}
    observation = {'schema': 'mifu-observation-v1', 'source': 'desktop_observation', 'requestId': 'r',
        'plate_id': 'p', 'candidate_ids': ['a', 'b'], 'snapshot_at': '2026-11-12T04:00:00Z',
        'artifact_sha256': None, 'plate_index': 1, 'geometry': {'status': 'not_measured'},
        'devices': [{'candidate_id': key, 'ams_observed': key == 'a', 'telemetry_at': None,
                     'ams_telemetry_at': None, 'setup_seconds': None} for key in ('a', 'b')],
        'ams_units': [{'candidate_id': 'a', 'unit_index': 0, 'type': 'ams', 'present': True,
                       'extruder_index': None, 'uses_track_switch': None, 'telemetry_at': None}],
        'feed_slots': [{'candidate_id': 'a', 'unit_index': 0, 'slot_index': 0, 'present': None, 'telemetry_at': None}],
        'training_eligible': False}
    return request, observation


class ObservationValidationTests(unittest.TestCase):
    def test_unknowns_and_original_timestamps_are_preserved_without_labels(self):
        request, observation = fixture()
        original = copy.deepcopy(observation)
        self.assertEqual(observation, validate_observation(observation, request))
        self.assertEqual(original, observation)
        self.assertIsNone(observation['feed_slots'][0]['present'])
        self.assertFalse(observation['training_eligible'])

    def test_capacity_is_explicit_and_does_not_slice(self):
        request, observation = fixture()
        observation['feed_slots'] *= 1025
        with self.assertRaises(ObservationError) as caught:
            validate_observation(observation, request)
        self.assertEqual('observation_capacity_exceeded', caught.exception.code)
        self.assertEqual(1025, len(observation['feed_slots']))

    def test_sixteen_printers_with_thirty_two_slots_are_preserved(self):
        request, observation = fixture()
        keys = [str(index) for index in range(16)]
        request['candidates'] = [{'id': key} for key in keys]
        observation['candidate_ids'] = keys
        observation['devices'] = [{**observation['devices'][0], 'candidate_id': key} for key in keys]
        observation['ams_units'] = [{**observation['ams_units'][0], 'candidate_id': key,
                                    'unit_index': unit} for key in keys for unit in range(8)]
        observation['feed_slots'] = [{**observation['feed_slots'][0], 'candidate_id': key,
                                     'unit_index': unit, 'slot_index': slot}
                                    for key in keys for unit in range(8) for slot in range(4)]
        self.assertEqual(512, len(validate_observation(observation, request)['feed_slots']))
        self.assertEqual(128, len(observation['ams_units']))

    def test_duplicate_missing_and_foreign_device_evidence_is_rejected(self):
        for change in ('duplicate_ids', 'missing', 'duplicate', 'foreign'):
            request, observation = fixture()
            if change == 'duplicate_ids': observation['candidate_ids'].append('a')
            if change == 'missing': observation['devices'].pop()
            if change == 'duplicate': observation['devices'][1] = observation['devices'][0]
            if change == 'foreign': observation['devices'][0]['candidate_id'] = 'other'
            with self.assertRaises(ObservationError):
                validate_observation(observation, request)

    def test_unknown_topology_and_orphan_or_repeated_slots_are_rejected(self):
        for change in ('unknown_ams', 'foreign_unit', 'orphan_slot', 'repeat_slot', 'repeat_unit'):
            request, observation = fixture()
            if change == 'unknown_ams': observation['devices'][0]['ams_observed'] = False
            if change == 'foreign_unit': observation['ams_units'][0]['candidate_id'] = 'other'
            if change == 'orphan_slot': observation['feed_slots'][0]['unit_index'] = 1
            if change == 'repeat_slot': observation['feed_slots'].append(observation['feed_slots'][0])
            if change == 'repeat_unit': observation['ams_units'].append(observation['ams_units'][0])
            with self.assertRaises(ObservationError):
                validate_observation(observation, request)

    def test_wrong_source_fake_eligibility_and_invalid_timestamps_fail(self):
        for key, value in (('source', 'expert_review'), ('training_eligible', True),
                           ('snapshot_at', '2026-11-12T04:00:00'), ('snapshot_at', 'not-a-time')):
            request, observation = fixture()
            observation[key] = value
            with self.assertRaises(ObservationError):
                validate_observation(observation, request)


if __name__ == '__main__':
    unittest.main()
