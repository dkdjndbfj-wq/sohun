from __future__ import annotations

import copy
import json
from pathlib import Path
import random
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from decision_contract import (ContractError, HEAD_MAX_LEN, MAX_LEN, SCHEMA,
                               from_simulation_row, label_for_candidate, normalize_request)
from large_dataset import episode_state, features


def live_request(count=2):
    return {'requestId': 'request',
            'decision_context': {'schema': SCHEMA, 'source': 'live_snapshot',
                                 'objective': 'earliest_known_finish', 'snapshot_id': 'snapshot',
                                 'gate_version': 'tested-gates-v1', 'observed_at_epoch_s': 1000, 'max_age_seconds': 120},
            'plate': {'id': 'plate', 'estimated_seconds': 3600, 'remaining_runs': 3, 'artifact_sha256': 'a' * 64},
            'candidates': [{'id': f'device-{i}',
                            'admission': {'status': 'passed', 'version': 'tested-gates-v1',
                                          'snapshot_id': 'snapshot', 'observed_at_epoch_s': 1000},
                            'features': {'available_after_seconds': 600 + i, 'setup_seconds': 31,
                                         'max_runs': 3, 'queued_runs': 2,
                                         'timing_evidence': {
                                             'setup': {'source': 'manual_estimate', 'observed_at_epoch_s': 1000},
                                             'wait': {'source': 'queue_and_device_lower_bound', 'observed_at_epoch_s': 1000},
                                             'run': {'source': 'selected_slice_estimate', 'artifact_sha256': 'a' * 64}},
                                         'hardware': {'nozzle_material': None, 'feed': {'kind': 'ams'}},
                                         'materials': [{'tool': 0, 'free_g': 500}]}}
                           for i in range(count)]}


class DecisionContractTests(unittest.TestCase):
    def assert_rejected(self, request, code):
        with self.assertRaises(ContractError) as caught:
            normalize_request(request, now_epoch_s=1010)
        self.assertEqual(code, caught.exception.code)
        return caught.exception

    def test_candidate_counts_share_fixed_budget_and_do_not_gain_execution_authority(self):
        for count in (2, 4, 8, 16):
            output = normalize_request(live_request(count), now_epoch_s=1010)
            self.assertEqual(count, len(output['mapping']))
            self.assertEqual({'max_len': 2048, 'head_max_len': 1024}, output['budget'])
            self.assertEqual(MAX_LEN, output['budget']['max_len'])
            self.assertEqual(HEAD_MAX_LEN, output['budget']['head_max_len'])
            self.assertEqual('pending', output['diagnostics']['token_audit']['status'])
            self.assertFalse(output['diagnostics']['dispatch_authorized'])
        for count in (1, 17):
            self.assert_rejected(live_request(count), 'candidate_count')

    def test_integer_second_boundary_and_derived_finish_are_exact(self):
        request = live_request()
        output = normalize_request(request, now_epoch_s=1010)
        first, second = output['diagnostics']['candidates']
        self.assertEqual(4231, first['finish_s'])
        self.assertEqual(4232, second['finish_s'])
        criteria = output['questions']['printer']['criteria']
        self.assertIn('finish 4231s', criteria['candidate_00'])
        self.assertIn('finish 4232s', criteria['candidate_01'])
        self.assertNotIn('rank', json.dumps(output['state']))

    def test_unknown_setup_is_not_zero_and_cannot_claim_known_finish(self):
        request = live_request()
        request['candidates'][0]['features']['setup_seconds'] = None
        error = self.assert_rejected(request, 'objective_evidence_missing')
        self.assertIsNone(error.diagnostics['setup_s'])
        self.assertIsNone(error.diagnostics['finish_s'])
        request['decision_context']['objective'] = 'earliest_known_availability'
        output = normalize_request(request, now_epoch_s=1010)
        self.assertIsNone(output['diagnostics']['candidates'][0]['setup_s'])
        self.assertIn('prep ?s; finish ?s', output['questions']['printer']['criteria']['candidate_00'])
        self.assertIsNone(output['diagnostics']['candidates'][0]['hardware']['nozzle_material'])

    def test_unknown_wait_rejected_for_both_objectives_and_missing_run_is_not_imputed(self):
        for objective in ('earliest_known_finish', 'earliest_known_availability'):
            request = live_request()
            request['decision_context']['objective'] = objective
            request['candidates'][0]['features']['available_after_seconds'] = None
            self.assert_rejected(request, 'objective_evidence_missing')
        request = live_request()
        request['candidates'][0]['features']['run_seconds'] = None
        self.assert_rejected(request, 'objective_evidence_missing')

    def test_explicit_source_and_admission_are_required(self):
        for status in (None, 'unknown', 'blocked', 'synthetic_declared_eligible'):
            request = live_request()
            request['candidates'][0]['admission']['status'] = status
            self.assert_rejected(request, 'admission_not_verified')
        request = live_request()
        del request['decision_context']['source']
        self.assert_rejected(request, 'unknown_source')
        for key in ('version', 'snapshot_id'):
            request = live_request()
            request['candidates'][0]['admission'][key] = 'different'
            self.assert_rejected(request, 'admission_not_verified')

    def test_stale_future_missing_timestamps_and_unbounded_ttl_are_rejected(self):
        for timestamp in (None, 800, 1011):
            request = live_request()
            request['candidates'][0]['admission']['observed_at_epoch_s'] = timestamp
            self.assert_rejected(request, 'invalid_number' if timestamp is None else 'stale_or_future_evidence')
        request = live_request()
        request['decision_context']['max_age_seconds'] = 121
        self.assert_rejected(request, 'invalid_integer')

    def test_targets_outcomes_invalid_numbers_and_duplicate_ids_are_rejected(self):
        for field in ('expected', 'oracle_rank', 'outcome', 'selectedCandidateId'):
            request = live_request()
            request['candidates'][0]['features']['hardware'][field] = 'candidate_00'
            self.assert_rejected(request, 'label_in_request')
        for value in (True, -1, 1.25, float('nan')):
            request = live_request()
            request['candidates'][0]['features']['setup_seconds'] = value
            self.assert_rejected(request, 'invalid_json_evidence' if isinstance(value, float) and value != value
                                 else 'invalid_number' if isinstance(value, bool) else 'invalid_integer')
        request = live_request()
        request['candidates'][1]['id'] = request['candidates'][0]['id']
        self.assert_rejected(request, 'duplicate_candidate')

    def test_permutation_mapping_follows_device_without_leaking_ids_or_labels(self):
        request = live_request(4)
        first = normalize_request(request, now_epoch_s=1010)
        request['candidates'].reverse()
        second = normalize_request(request, now_epoch_s=1010)
        self.assertEqual('candidate_00', label_for_candidate(first, 'device-0'))
        self.assertEqual('candidate_03', label_for_candidate(second, 'device-0'))
        model_text = json.dumps({'state': second['state'], 'questions': second['questions']})
        self.assertNotIn('device-0', model_text)
        self.assertNotIn('expected', model_text)
        self.assertNotIn('materials', model_text)
        with self.assertRaises(ContractError):
            label_for_candidate(second, 'absent')

    def test_simulation_adapter_ignores_labels_audit_costs_and_preserves_source(self):
        task, devices = episode_state(('P1S', .4, 'ams', 1, 4), random.Random(3), 2)
        row = {'state': {'featureSchemaVersion': 'mifu-hardware-sim-v3', 'plate': task,
                         'candidates': {f'candidate_{i:02d}': features(task, d) for i, d in enumerate(devices)}},
               'mifu_provenance': {'source': 'synthetic_pipeline_only', 'episode': 2, 'step': 0},
               'expected': {'printer': 'candidate_00'}, 'audit': {'costs_in_physical_order': [0, 999]}}
        adapted = from_simulation_row(row)
        output = normalize_request(adapted, now_epoch_s=0)
        self.assertEqual('synthetic_pipeline_only', output['diagnostics']['source'])
        self.assertEqual('synthetic_declared_eligible', adapted['candidates'][0]['admission']['status'])
        changed = copy.deepcopy(row)
        changed['expected']['printer'] = 'candidate_01'
        changed['audit'] = {'oracle_rank': 'different'}
        self.assertEqual(adapted, from_simulation_row(changed))
        self.assertNotIn('mifu_provenance', json.dumps(output['state']))
        adapted['decision_context']['source'] = 'live_snapshot'
        with self.assertRaises(ContractError) as caught:
            normalize_request(adapted, now_epoch_s=0)
        self.assertEqual('admission_not_verified', caught.exception.code)


if __name__ == '__main__':
    unittest.main()
