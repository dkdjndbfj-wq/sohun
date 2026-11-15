import copy
import json
import importlib.util
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from diagnose_learning import renamed_row
from evaluate_compact_model import (checkpoint_artifact_hashes, read_split, require_disjoint_groups,
                                    require_unchanged_checkpoint, selection_metrics, selective_metrics, wilson,
                                    load_checkpoint_readonly)


def example():
    return {'state': {'plate': {'target_model': 'test_only'}, 'candidates': {
                'candidate_00': {'wait_s': 90, 'setup_s': 10, 'run_s': 100},
                'candidate_01': {'wait_s': 20, 'setup_s': 10, 'run_s': 100}}},
            'questions': {'printer': {'criteria': {'candidate_00': 'candidate_00', 'candidate_01': 'candidate_01'}}},
            'expected': {'printer': 'candidate_01'}}


class DiagnosticMetricTests(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec('torch') and importlib.util.find_spec('safetensors') and
                         importlib.util.find_spec('transformers'), 'Local SDK dependencies unavailable')
    def test_readonly_loader_keeps_artifacts_and_rejects_nonfinite_weights(self):
        import torch
        from safetensors.torch import save_file
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory)
            for name in ('rl_agent_config.json', 'encoder/config.json', 'tokenizer/tokenizer_config.json'):
                path = checkpoint / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('{}', encoding='utf-8')
            original = torch.nn.Linear(2, 1)
            save_file(original.state_dict(), str(checkpoint / 'model.safetensors'))
            locked = checkpoint_artifact_hashes(checkpoint)
            sdk = SimpleNamespace(build_model=lambda *args, **kwargs: torch.nn.Linear(2, 1))
            with patch('transformers.AutoTokenizer.from_pretrained', return_value='tokenizer') as tokenizer:
                loaded, tok = load_checkpoint_readonly(checkpoint, {}, sdk)
                self.assertEqual('tokenizer', tok)
                self.assertTrue(torch.equal(loaded.weight, original.weight))
                tokenizer.assert_called_once_with(str(checkpoint / 'tokenizer'), local_files_only=True)
                require_unchanged_checkpoint(checkpoint, locked)
                bad = original.state_dict()
                bad['weight'][0, 0] = float('nan')
                save_file(bad, str(checkpoint / 'model.safetensors'))
                with self.assertRaisesRegex(ValueError, 'Nonfinite saved weight'):
                    load_checkpoint_readonly(checkpoint, {}, sdk)

    def test_physical_rename_preserves_answer_and_original(self):
        row = example()
        original = copy.deepcopy(row)
        renamed = renamed_row(row)
        self.assertEqual(row, original)
        self.assertEqual(renamed['expected']['printer'], 'candidate_00')
        self.assertEqual(renamed['state']['candidates']['candidate_00']['wait_s'], 20)

    def test_regret_and_permutations_are_physical_not_slot_only(self):
        result = selection_metrics([example(), example()], [1, 0], [1, 1], [0, 0])
        self.assertEqual(result['overall']['accuracy'], 0.5)
        self.assertEqual(result['overall']['meanRegretSeconds'], 35)
        self.assertEqual(result['overall']['physicalRenameConsistency'], 0.5)
        self.assertEqual(result['candidateBuckets']['2']['independentEpisodes'], 2)

    def test_bad_evaluation_label_is_rejected(self):
        row = example()
        row['expected']['printer'] = 'candidate_00'
        with self.assertRaises(ValueError):
            selection_metrics([row], [0], [0], [1])

    def test_confidence_interval_not_claimed_as_perfect_certainty(self):
        low, high = wilson(100, 100)
        self.assertGreater(low, 0.96)
        self.assertLess(low, 1)
        self.assertAlmostEqual(high, 1)
        with self.assertRaises(ValueError):
            wilson(1, 0)

    def test_compact_mapping_uses_physical_state_order_not_legacy_criteria_order(self):
        row = example()
        row['questions']['printer']['criteria'] = dict(reversed(list(row['questions']['printer']['criteria'].items())))
        result = selection_metrics([row], [1], [1], [0])
        self.assertEqual(1, result['overall']['accuracy'])
        self.assertEqual(0, result['overall']['meanRegretSeconds'])
        self.assertEqual(1, result['overall']['physicalRenameConsistency'])

    def test_invalid_indices_and_nonfinite_costs_are_rejected(self):
        for index in (-1, 2, True, 1.0):
            with self.subTest(index=index), self.assertRaises(ValueError):
                selection_metrics([example()], [index], [1], [0])
        for value in (float('nan'), float('inf'), True, -1, .5):
            row = example()
            row['state']['candidates']['candidate_00']['wait_s'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                selection_metrics([row], [1], [1], [0])
        with self.assertRaises(ValueError):
            selection_metrics([], [], [], [])

    def test_equal_finish_preparation_error_is_visible_separately(self):
        row = example()
        row['state']['candidates']['candidate_00'].update(wait_s=10, setup_s=20)
        result = selection_metrics([row], [0], [0], [1])['overall']
        self.assertEqual(0, result['accuracy'])
        self.assertEqual(0, result['meanRegretSeconds'])
        self.assertEqual(10, result['meanTieBreakPreparationRegretSeconds'])
        self.assertEqual(1, result['tieBreakMistakes'])

    def test_exact_cost_ties_do_not_make_equally_optimal_choice_incorrect(self):
        row = example()
        row['state']['candidates']['candidate_00'] = copy.deepcopy(row['state']['candidates']['candidate_01'])
        self.assertEqual(1, selection_metrics([row], [0], [0], [1])['overall']['accuracy'])

    def test_calibration_and_holdout_episodes_must_be_distinct_and_labeled(self):
        with self.assertRaises(ValueError):
            require_disjoint_groups({'a'}, {'b'}, {'c'}, {'a'})
        require_disjoint_groups({'a'}, {'b'}, {'c'}, {'d'})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sample.jsonl'
            row = {'mifu_provenance': {'source': 'synthetic_pipeline_only', 'split': 'calibration', 'groupId': 'one'}}
            path.write_text(json.dumps(row) + '\n' + json.dumps(row) + '\n', encoding='utf-8')
            with self.assertRaises(ValueError):
                read_split(path, 'calibration')
            with self.assertRaises(ValueError):
                read_split(path, 'train', unique_episodes=False)
            self.assertEqual({'one'}, read_split(path, 'calibration', unique_episodes=False)[1])

    def test_checkpoint_lock_detects_config_and_tokenizer_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = Path(directory)
            for name in ('model.safetensors', 'rl_agent_config.json', 'encoder/config.json', 'tokenizer/tokenizer.json'):
                path = checkpoint / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('original', encoding='utf-8')
            locked = checkpoint_artifact_hashes(checkpoint)
            require_unchanged_checkpoint(checkpoint, locked)
            for name in ('model.safetensors', 'rl_agent_config.json', 'tokenizer/tokenizer.json'):
                path = checkpoint / name
                path.write_text('changed', encoding='utf-8')
                with self.assertRaises(ValueError):
                    require_unchanged_checkpoint(checkpoint, locked)
                path.write_text('original', encoding='utf-8')

    def test_selective_metrics_separate_coverage_from_accuracy(self):
        records = [(0, [math.log(9), 0], [1, 0], 2),
                   (0, [0, 0], [1, 0], 2),
                   (0, [math.log(99), 0], [0, 1], 2)]
        fitted = {'temperature': [1, 1, 1], 'temperature_by_options': {}}
        result = selective_metrics(records, fitted, {'choice:2': .9}, bucket_for=lambda qt, k: 'choice:' + str(k))
        self.assertEqual(2, result['overall']['accepted'])
        self.assertAlmostEqual(2 / 3, result['overall']['coverage'])
        self.assertEqual(.5, result['overall']['acceptedAccuracy'])
        self.assertEqual(3, result['candidateBuckets']['2']['episodes'])
        self.assertFalse(result['actHeadUsed'])

    def test_unfitted_confidence_bucket_rejects_even_confident_choices(self):
        result = selective_metrics([(0, [100, 0], [1, 0], 2)],
                                    {'temperature': [1, 1, 1], 'temperature_by_options': {}}, {},
                                    bucket_for=lambda qt, k: 'choice:2')
        self.assertEqual(0, result['overall']['coverage'])
        self.assertIsNone(result['overall']['acceptedAccuracy'])
        self.assertEqual(1, result['overall']['unfittedBucketRejected'])


if __name__ == '__main__':
    unittest.main()
