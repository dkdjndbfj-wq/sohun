"""CPU-only synthetic fixtures; no operational accuracy or deployment assertions."""
from __future__ import annotations

import copy
import json
import math
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import mifu_numeric_ranker as numeric
from decision_contract import ContractError, MAX_TIME_SECONDS

try:
    import torch
except ImportError:
    torch = None


def request(count=3):
    snapshot = 'explicit-numeric-unit-test-fixture'
    return {
        'requestId': snapshot,
        'decision_context': {'schema': 'mifu-decision-v4', 'source': 'synthetic_pipeline_only',
                             'objective': 'earliest_known_finish', 'snapshot_id': snapshot,
                             'gate_version': 'unit-test-declared-only', 'observed_at_epoch_s': 0,
                             'max_age_seconds': 120},
        'plate': {'id': snapshot, 'estimated_seconds': None, 'remaining_runs': 1},
        'candidates': [
            {'id': f'fixture-{i}',
             'admission': {'status': 'synthetic_declared_eligible', 'version': 'unit-test-declared-only',
                           'snapshot_id': snapshot, 'observed_at_epoch_s': 0},
             'features': {'available_after_seconds': 100 + i, 'setup_seconds': 20 + 2 * i,
                          'run_seconds': 300 - i, 'max_runs': 1, 'queued_runs': 0}}
            for i in range(count)]}


class NumericImportAndValidationTests(unittest.TestCase):
    def test_module_import_and_request_validation_do_not_import_torch(self):
        service = str(Path(__file__).resolve().parents[1])
        code = ('import sys, json; sys.path.insert(0, ' + repr(service) + '); '
                'import mifu_numeric_ranker as n; '
                'assert "torch" not in sys.modules; '
                'n.prepare_numeric_request(json.loads(' + repr(json.dumps(request())) + '), now_epoch_s=0); '
                'assert "torch" not in sys.modules')
        result = subprocess.run([sys.executable, '-B', '-c', code], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_request_validation_keeps_original_source_and_advisory_boundary(self):
        prepared = numeric.prepare_numeric_request(request(), now_epoch_s=0)
        self.assertEqual('synthetic_pipeline_only', prepared['diagnostics']['source'])
        self.assertFalse(prepared['diagnostics']['dispatch_authorized'])
        self.assertEqual('pending', prepared['diagnostics']['token_audit']['status'])

    def test_unknown_times_admission_and_label_in_request_are_rejected(self):
        for name in ('available_after_seconds', 'setup_seconds', 'run_seconds'):
            value = request()
            value['candidates'][0]['features'][name] = None
            with self.subTest(name=name), self.assertRaises(ContractError):
                numeric.prepare_numeric_request(value, now_epoch_s=0)
        value = request()
        value['candidates'][0]['admission']['status'] = 'unknown'
        with self.assertRaises(ContractError):
            numeric.prepare_numeric_request(value, now_epoch_s=0)
        value = request()
        value['expected'] = 'fixture-0'
        with self.assertRaises(ContractError):
            numeric.prepare_numeric_request(value, now_epoch_s=0)

    def test_only_supported_objective_and_candidate_count(self):
        value = request()
        value['decision_context']['objective'] = 'earliest_known_availability'
        with self.assertRaises(ValueError):
            numeric.prepare_numeric_request(value, now_epoch_s=0)
        for count in (0, 1, 17):
            with self.subTest(count=count), self.assertRaises(ContractError):
                numeric.prepare_numeric_request(request(count), now_epoch_s=0)


@unittest.skipIf(torch is None, 'CPU torch is required for the offline numeric experiment')
class NumericRankerTests(unittest.TestCase):
    def setUp(self):
        self.prepared = numeric.prepare_numeric_request(request(), now_epoch_s=0)
        self.features = numeric.pair_features(self.prepared)
        self.model = numeric.NumericPairwiseRanker()

    def test_one_second_at_eight_million_is_preserved_before_tensor_cast(self):
        value = request(2)
        for i, candidate in enumerate(value['candidates']):
            candidate['features'].update(available_after_seconds=MAX_TIME_SECONDS,
                                         setup_seconds=MAX_TIME_SECONDS,
                                         run_seconds=MAX_TIME_SECONDS - i)
        prepared = numeric.prepare_numeric_request(value, now_epoch_s=0)
        self.assertGreater(prepared['diagnostics']['candidates'][0]['finish_s'], 8_000_000)
        features = numeric.pair_features(prepared)
        self.assertEqual(torch.float64, features.dtype)
        self.assertEqual(math.log1p(1), features[0, 1, 0].item())
        self.assertEqual(-math.log1p(1), features[1, 0, 0].item())
        self.assertEqual(0.0, features[0, 1, 1].item())

    def test_candidate_order_equivariance_and_ids_are_not_features(self):
        value = request()
        order = torch.tensor([2, 0, 1])
        value['candidates'] = [value['candidates'][i] for i in order.tolist()]
        for i, candidate in enumerate(value['candidates']):
            candidate['id'] = f'unrelated-renamed-{100-i}'
        changed = numeric.pair_features(numeric.prepare_numeric_request(value, now_epoch_s=0))
        self.assertTrue(torch.equal(self.features[order][:, order], changed))
        original_logits = self.model(self.features)
        changed_logits = self.model(changed)
        torch.testing.assert_close(changed_logits, original_logits[order][:, order], rtol=0, atol=1e-14)
        torch.testing.assert_close(numeric.candidate_scores(changed_logits),
                                   numeric.candidate_scores(original_logits)[order], rtol=0, atol=1e-14)

    def test_same_finish_setup_different_wait_run_has_identical_features(self):
        value = request()
        for candidate in value['candidates']:
            candidate['features']['available_after_seconds'] += 17
            candidate['features']['run_seconds'] -= 17
        changed = numeric.pair_features(numeric.prepare_numeric_request(value, now_epoch_s=0))
        self.assertTrue(torch.equal(self.features, changed))

    def test_unknown_float_boolean_and_out_of_domain_numeric_candidates_rejected(self):
        candidates = self.prepared['diagnostics']['candidates']
        for field, bad in (('finish_s', None), ('finish_s', 420.0), ('finish_s', True),
                           ('finish_s', -1), ('finish_s', 3 * MAX_TIME_SECONDS + 1),
                           ('setup_s', None), ('setup_s', MAX_TIME_SECONDS + 1)):
            changed = copy.deepcopy(candidates)
            changed[0][field] = bad
            with self.subTest(field=field, bad=bad), self.assertRaises(ValueError):
                numeric.pair_features(changed)
        for count in (0, 1, 17):
            with self.subTest(count=count), self.assertRaises(ValueError):
                numeric.pair_features([candidates[0]] * count)

    def test_all_supported_counts_and_batch_shapes(self):
        for count in (2, 3, 4, 8, 16):
            with self.subTest(count=count):
                features = numeric.pair_features(numeric.prepare_numeric_request(request(count), now_epoch_s=0))
                batch = torch.stack([features, features])
                logits = self.model(batch)
                self.assertEqual((2, count, count), tuple(logits.shape))
                self.assertEqual((2, count), tuple(numeric.candidate_scores(logits).shape))
                self.assertTrue(torch.equal(logits, -logits.transpose(-2, -1)))

    def test_exact_ties_have_zero_numeric_pair_logit_and_half_win_probability(self):
        candidates = copy.deepcopy(self.prepared['diagnostics']['candidates'])
        candidates[1]['finish_s'] = candidates[0]['finish_s']
        candidates[1]['setup_s'] = candidates[0]['setup_s']
        features = numeric.pair_features(candidates[:2])
        logits = self.model(features)
        self.assertTrue(torch.equal(logits, torch.zeros_like(logits)))
        self.assertTrue(torch.equal(numeric.candidate_scores(logits), torch.full((2,), 0.5, dtype=torch.float64)))

    def test_finish_tie_does_not_remove_prep_difference(self):
        candidates = copy.deepcopy(self.prepared['diagnostics']['candidates'])
        candidates[1]['finish_s'] = candidates[0]['finish_s']
        features = numeric.pair_features(candidates)
        self.assertEqual(0.0, features[0, 1, 0].item())
        self.assertNotEqual(0.0, features[0, 1, 1].item())
        # No assertion that an untrained head knows which preparation is best.

    def test_zero_weights_do_not_secretly_invoke_an_oracle(self):
        with torch.no_grad():
            for parameter in self.model.parameters():
                parameter.zero_()
        logits = self.model(self.features)
        self.assertTrue(torch.equal(logits, torch.zeros_like(logits)))
        self.assertTrue(torch.equal(numeric.candidate_scores(logits), torch.ones(3, dtype=torch.float64)))

    def test_gradients_and_one_cpu_optimizer_step_are_real_not_quality_evidence(self):
        optimizer = torch.optim.SGD(self.model.parameters(), lr=0.01)
        before = {key: value.clone() for key, value in self.model.state_dict().items()}
        loss = torch.nn.functional.binary_cross_entropy_with_logits(
            self.model(self.features)[0, 1].reshape(1), torch.ones(1, dtype=torch.float64))
        loss.backward()
        self.assertTrue(any(parameter.grad is not None and bool(parameter.grad.abs().sum() > 0)
                            for parameter in self.model.parameters()))
        optimizer.step()
        self.assertTrue(any(not torch.equal(before[key], value) for key, value in self.model.state_dict().items()))
        self.assertTrue(all(parameter.dtype == torch.float64 for parameter in self.model.parameters()))

    def test_hybrid_alpha_is_trainable_unconstrained_and_laya_contribution_explicit(self):
        model = numeric.NumericPairwiseRanker(hybrid=True)
        laya = torch.tensor([0.5, -0.5, 0.0], dtype=torch.float32)
        base = model(self.features, laya)
        with torch.no_grad():
            model.alpha.fill_(-2.0)
        combined = model(self.features, laya)
        differences = laya.double().unsqueeze(-1) - laya.double().unsqueeze(-2)
        torch.testing.assert_close(combined, base - 2 * differences, rtol=0, atol=1e-14)
        combined[0, 1].backward()
        self.assertNotEqual(0.0, model.alpha.grad.item())
        self.assertEqual(torch.float64, combined.dtype)
        with self.assertRaises(ValueError):
            model(self.features)
        with self.assertRaises(ValueError):
            self.model(self.features, laya)

    def test_bf16_autocast_does_not_change_numeric_calculation(self):
        expected = self.model(self.features)
        with torch.autocast(device_type='cpu', dtype=torch.bfloat16):
            actual = self.model(self.features)
            scores = numeric.candidate_scores(actual)
        self.assertTrue(torch.equal(expected, actual))
        self.assertEqual(torch.float64, scores.dtype)
        with self.assertRaises(ValueError):
            self.model(self.features.bfloat16())
        self.model.float()
        with self.assertRaises(ValueError):
            self.model(self.features)

    def test_independent_pair_api_matches_matrix_and_reverses_preference(self):
        for hybrid in (False, True):
            model = numeric.NumericPairwiseRanker(hybrid=hybrid)
            laya = torch.tensor([1.5, -2.0, 0.0], dtype=torch.float64) if hybrid else None
            if hybrid:
                with torch.no_grad():
                    model.alpha.fill_(0.7)
            delta = (laya.unsqueeze(-1) - laya.unsqueeze(-2)).reshape(-1) if hybrid else None
            pairs = self.features.reshape(-1, 2)
            result = model.pair_logits(pairs, delta)
            reversed_result = model.pair_logits(-pairs, -delta if hybrid else None)
            torch.testing.assert_close(result.reshape(3, 3), model(self.features, laya), rtol=0, atol=1e-14)
            self.assertTrue(torch.equal(result, -reversed_result))
            result.square().sum().backward()
            self.assertTrue(any(p.grad is not None for p in model.parameters()))
        with self.assertRaises(ValueError):
            self.model.pair_logits(torch.zeros((5, 2), dtype=torch.float32))

    def test_invalid_shapes_nans_and_nonantisymmetric_features_rejected(self):
        cases = [torch.zeros((3, 2), dtype=torch.float64),
                 torch.zeros((2, 3, 2), dtype=torch.float64),
                 torch.zeros((2, 2, 3), dtype=torch.float64),
                 torch.full((2, 2, 2), float('nan'), dtype=torch.float64),
                 torch.ones((2, 2, 2), dtype=torch.float64)]
        for value in cases:
            with self.subTest(shape=value.shape), self.assertRaises(ValueError):
                self.model(value)

    def test_config_and_state_round_trip_before_and_after_step_remain_offline(self):
        for hybrid in (False, True):
            with self.subTest(hybrid=hybrid):
                model = numeric.NumericPairwiseRanker(hybrid=hybrid, activation='relu')
                laya = torch.tensor([1.0, 0.0, -1.0], dtype=torch.float64) if hybrid else None
                initial_config = model.artifact_config()
                for trained in (False, True):
                    if trained:
                        optimizer = torch.optim.SGD(model.parameters(), lr=0.01)
                        optimizer.zero_grad()
                        model(self.features, laya)[0, 1].square().backward()
                        optimizer.step()
                    config = json.loads(json.dumps(model.artifact_config()))
                    self.assertEqual(initial_config, config)
                    self.assertFalse(config['deployable'])
                    self.assertFalse(config['automaticExecutionAuthorized'])
                    self.assertNotIn('modelReady', config)
                    loaded = numeric.load_ranker(config, model.state_dict())
                    self.assertTrue(torch.equal(model(self.features, laya), loaded(self.features, laya)))

    def test_load_rejects_ready_claim_wrong_schema_missing_weights_dtype_and_nan(self):
        config, state = self.model.artifact_config(), self.model.state_dict()
        for key, bad in (('deployable', True), ('modelReady', True), ('dtype', 'bfloat16'),
                         ('featureSchema', 'invented'), ('hybrid', 1)):
            changed = copy.deepcopy(config)
            changed[key] = bad
            with self.subTest(key=key), self.assertRaises(ValueError):
                numeric.load_ranker(changed, state)
        for mutation in ('missing', 'dtype', 'nan', 'shape'):
            changed = {key: value.clone() for key, value in state.items()}
            first = next(iter(changed))
            if mutation == 'missing':
                del changed[first]
            elif mutation == 'dtype':
                changed[first] = changed[first].float()
            elif mutation == 'nan':
                changed[first].flatten()[0] = float('nan')
            else:
                changed[first] = changed[first].flatten()
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                numeric.load_ranker(config, changed)


if __name__ == '__main__':
    unittest.main()
