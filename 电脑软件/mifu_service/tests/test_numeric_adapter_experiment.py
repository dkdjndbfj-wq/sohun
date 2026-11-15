"""Synthetic CPU fixtures only; the fake Laya never proves CUDA/model accuracy."""
from __future__ import annotations

from collections import Counter
import copy
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SERVICE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE))
import train_numeric_adapter as experiment
from decision_contract import MAX_TIME_SECONDS, normalize_request

try:
    import torch
except ImportError:
    torch = None


def tiny_plan():
    plan = copy.deepcopy(experiment.PLAN)
    plan.update(experimentId='unit-test-double-numeric', trainEpisodes=32,
                validationEpisodes=32, holdoutEpisodes=32, optimizerUpdates=2,
                pairsPerUpdate=16, validateEvery=1, physicalPermutationProbeEpisodes=32,
                unitTestFixture=True)
    return plan


class FakeFrozenLaya:
    """Explicit CPU test double; no Laya, CUDA, tokenizer or genuine H forward."""
    def __init__(self, checkpoint, plan):
        self.count = 0
        self.inventory = {'model.safetensors': plan['baseWeightsSha256']}

    def predict(self, requests):
        self.count += len(requests)
        return [{c['id']: -float(c['features']['available_after_seconds'])
                 for c in req['candidates']} for req in requests]

    def evidence(self):
        return {'checkpointArtifactsSha256': self.inventory, 'testDouble': True,
                'device': 'cpu-test-double', 'actualLayaForwards': 0, 'inputCount': self.count}


class ExperimentDataTests(unittest.TestCase):
    def setUp(self):
        self.plan = tiny_plan()

    def test_dry_run_writes_nothing_and_imports_no_torch(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / 'must-not-exist'
            code = ('import sys; sys.path.insert(0, ' + repr(str(SERVICE)) + '); '
                    'import train_numeric_adapter as e; '
                    'sys.argv=["runner", "dry-run", "--out", ' + repr(str(out)) + ']; '
                    'e.main(); assert "torch" not in sys.modules')
            result = subprocess.run([sys.executable, '-B', '-c', code], capture_output=True, text=True)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertFalse(out.exists())
            self.assertFalse(json.loads(result.stdout)['usesGPU'])

    def test_dry_run_refuses_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(sys, 'argv', ['runner', 'dry-run', '--out', directory]):
                with self.assertRaises(FileExistsError):
                    experiment.main()

    def test_generation_balanced_and_every_request_valid(self):
        values = experiment.generate('train', 320, self.plan)
        counts = Counter((e['candidateCount'], e['scenario']) for e in values)
        self.assertEqual({10}, set(counts.values()))
        self.assertEqual(32, len(counts))
        for episode in values:
            for req in episode['variants']:
                prepared = normalize_request(req, now_epoch_s=0)
                self.assertEqual(episode['candidateCount'], len(prepared['mapping']))
                self.assertEqual('synthetic_pipeline_only', prepared['diagnostics']['source'])
                for c in req['candidates']:
                    self.assertTrue(0 <= c['features']['available_after_seconds'] <= MAX_TIME_SECONDS)
                    self.assertTrue(0 <= c['features']['setup_seconds'] <= MAX_TIME_SECONDS)
                    self.assertTrue(1 <= c['features']['run_seconds'] <= MAX_TIME_SECONDS)

    def test_variants_share_costs_and_episode_but_change_decomposition(self):
        for e in experiment.generate('train', 32, self.plan):
            a, b = e['variants']
            self.assertEqual(experiment.costs(a), experiment.costs(b))
            self.assertNotEqual(experiment.semantic(a), experiment.semantic(b))
            self.assertEqual(experiment.numeric_geometry(a), experiment.numeric_geometry(b))
            self.assertEqual(a['decision_context']['snapshot_id'], b['decision_context']['snapshot_id'])

    def test_exact_gaps_and_preparation_tie_labels(self):
        for e in experiment.generate('train', 32, self.plan):
            objective = sorted(experiment.costs(e['variants'][0]).values())
            gap = {'gap1': 1, 'gap2': 2, 'gap30': 30, 'boundary': 1}.get(e['scenario'])
            if gap is not None:
                self.assertEqual(gap, objective[1][0] - objective[0][0])
            if e['scenario'] == 'primarytie':
                self.assertEqual(objective[0][0], objective[1][0])
                self.assertLess(objective[0][1], objective[1][1])
                self.assertEqual(1., experiment.pair_target(objective[0], objective[1]))
            if e['scenario'] == 'allties':
                self.assertEqual(1, len(set(objective)))
                self.assertEqual(.5, experiment.pair_target(objective[0], objective[1]))

    def test_invalid_split_sizes_rejected(self):
        for split, count in [('dev', 32), ('train', 16), ('train', 33)]:
            with self.assertRaises(ValueError):
                experiment.generate(split, count, self.plan)

    def test_deterministic_generation_and_split_disjointness(self):
        occupied = set()
        train = experiment.generate('train', 32, self.plan, occupied)
        valid = experiment.generate('validation', 32, self.plan, occupied)
        self.assertEqual(train, experiment.generate('train', 32, self.plan))
        signatures = lambda es: set().union(*(experiment.episode_signatures(req) for e in es for req in e['variants']))
        self.assertFalse(signatures(train) & signatures(valid))
        self.assertFalse({e['episodeId'] for e in train} & {e['episodeId'] for e in valid})

    def test_prepare_creates_no_holdout_and_reports_equivalent_numeric_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / 'experiment'
            real_generate = experiment.generate
            with patch.object(experiment, 'generate', wraps=real_generate) as generated:
                report = experiment.prepare(out, self.plan)
            self.assertEqual(['train', 'validation'], [call.args[0] for call in generated.call_args_list])
            self.assertFalse(report['holdoutGenerated'])
            self.assertFalse(any('holdout' in p.name for p in out.iterdir()))
            self.assertEqual({'train': 64, 'validation': 64}, report['modelInputs'])
            self.assertIn('numericGeometryOverlap', report)
            with self.assertRaises(FileExistsError):
                experiment.prepare(out, self.plan)

    def test_numeric_geometry_detects_shift_permutation_and_decomposition_equivalence(self):
        e = next(e for e in experiment.generate('train', 32, self.plan) if e['scenario'] == 'gap1')
        a, b = e['variants'][0], copy.deepcopy(e['variants'][1])
        b['candidates'].reverse()
        for c in b['candidates']:
            c['features']['setup_seconds'] += 100
            c['features']['available_after_seconds'] += 400
        self.assertEqual(experiment.numeric_geometry(a), experiment.numeric_geometry(b))
        self.assertNotEqual(experiment.episode_signatures(a), experiment.episode_signatures(b))

    def test_non_degenerate_accuracy_does_not_count_all_ties(self):
        vals = [{'scenario': 'allties', 'candidateCount': 2, 'correct': True,
                 'regretSeconds': 0, 'preparationTieMistake': False}] * 10
        vals += [{'scenario': 'gap1', 'candidateCount': 2, 'correct': False,
                  'regretSeconds': 1, 'preparationTieMistake': False}]
        result = experiment.grouped(vals)
        self.assertEqual(10 / 11, result['overall']['accuracy'])
        self.assertEqual(0, result['nondegenerate']['accuracy'])
        self.assertEqual(1, result['nondegenerate']['n'])
        self.assertFalse(result['nondegenerate']['accuracyAtLeast95'])
        self.assertIsNone(result['candidateBuckets']['4']['wilson95'])
        self.assertAlmostEqual(.6755924351161198, experiment.wilson(8, 8)[0])

    def test_pipeline_and_cache_hash_reject_mismatch(self):
        with self.assertRaisesRegex(ValueError, 'Pipeline source'):
            experiment.verify_pipeline({'pipelineSha256': {}})
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            experiment.write(out / 'data.json', {'untouched': True})
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                experiment.verify_files(out, {'data.json': '0' * 64})

    def test_pair_comparison_separates_two_wrong_choices_from_both_optimal(self):
        e = next(e for e in experiment.generate('train', 32, self.plan) if e['scenario'] == 'gap1')
        req = e['variants'][0]
        objective = experiment.costs(req)
        wrong = max(objective, key=objective.get)
        result = experiment.comparison_evidence([e], [req], [{'selected': wrong}], [wrong])
        self.assertEqual(1, result['overall']['sameObjectiveCost'])
        self.assertEqual(0, result['overall']['bothOptimal'])
        self.assertEqual(0, result['overall']['changedInputCorrect'])


@unittest.skipIf(torch is None, 'CPU torch is required for adapter unit tests')
class ExperimentCPUIntegrationTests(unittest.TestCase):
    def test_training_pair_features_equal_shared_numeric_module(self):
        from mifu_numeric_ranker import pair_features, prepare_numeric_request
        for e in experiment.generate('train', 32, tiny_plan()):
            req = e['variants'][0]
            c = experiment.costs(req)
            a, b = [v['id'] for v in req['candidates'][:2]]
            expected = [math.copysign(math.log1p(abs(v)), v) if v else 0.
                        for v in (c[a][0] - c[b][0], c[a][1] - c[b][1])]
            actual = pair_features(prepare_numeric_request(req, now_epoch_s=0))
            self.assertTrue(torch.equal(actual[0, 1], torch.tensor(expected, dtype=torch.float64)))

    def test_exact_label_mapping_independent_of_candidate_position(self):
        for e in experiment.generate('train', 32, tiny_plan()):
            req = e['variants'][0]
            values = experiment.costs(req)
            choice = experiment.select('exact', req, {})
            self.assertEqual(min(values.values()), values[choice])
            req = copy.deepcopy(req)
            req['candidates'].reverse()
            changed = experiment.select('exact', req, {})
            self.assertEqual(values[choice], values[changed])

    def test_complete_cpu_test_double_pipeline_and_hash_guards(self):
        plan = tiny_plan()
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / 'experiment'
            checkpoint = Path(directory) / 'nonexistent-test-double-checkpoint'
            experiment.prepare(out, plan)
            with patch.object(experiment, 'FrozenLaya', FakeFrozenLaya), \
                 patch.object(experiment, 'runtime_fingerprint', return_value={'testDouble': True}), \
                 patch('evaluate_compact_model.checkpoint_artifact_hashes', return_value={'model.safetensors': plan['baseWeightsSha256']}), \
                 patch.object(torch.cuda, 'is_available', return_value=False), \
                 patch.object(torch.cuda, '_lazy_init', side_effect=AssertionError('GPU initialization forbidden in CPU unit test')):
                first = experiment.cache(out, checkpoint)
                self.assertEqual(128, first['inputs'])
                self.assertEqual(first, experiment.cache(out, checkpoint))
                with patch.object(experiment, 'runtime_fingerprint', return_value={'testDouble': 'changed'}):
                    with self.assertRaisesRegex(ValueError, 'runtime/SDK'):
                        experiment.cache(out, checkpoint)
                report = experiment.train(out)
                self.assertFalse(report['holdoutRead'])
                self.assertFalse((out / 'holdout_evaluation').exists())
                for r in report['models'].values():
                    self.assertEqual(2, r['optimizerUpdates'])
                    self.assertTrue(r['changedSelectedTensors'])
                initial_a = report['models']['numeric_only']['initialTensorSha256']
                initial_b = report['models']['hybrid']['initialTensorSha256']
                self.assertEqual(initial_a, {n: h for n, h in initial_b.items() if n != 'alpha'})
                with patch('evaluate_compact_model.checkpoint_artifact_hashes',
                           return_value={'model.safetensors': plan['baseWeightsSha256'], 'tokenizer/config': 'changed'}):
                    with self.assertRaisesRegex(ValueError, 'inference inputs differ'):
                        experiment.evaluate(out, checkpoint)
                    self.assertFalse((out / 'holdout_evaluation').exists())
                evaluation = experiment.evaluate(out, checkpoint)
                self.assertFalse(evaluation['deployable'])
                self.assertEqual(0, evaluation['runtime']['actualLayaForwards'])
                self.assertEqual(32, evaluation['baseEpisodes'])
                self.assertEqual(1., evaluation['modelMetrics']['deterministic_exact_baseline_not_model']['nondegenerate']['accuracy'])
                self.assertEqual(28, evaluation['modelMetrics']['numeric_only']['nondegenerate']['n'])
                self.assertEqual(32, evaluation['physicalPermutation']['hybrid']['overall']['n'])
                self.assertEqual(32, evaluation['decompositionStability']['hybrid']['overall']['n'])
                self.assertEqual(32, evaluation['decompositionStability']['numeric_only']['overall']['samePhysicalChoice'])
                self.assertFalse(evaluation['variantsCountedAsIndependent'])
                experiment.verify_files(out / 'holdout_evaluation', evaluation['files'])
                probes = experiment.read(out / 'holdout_evaluation' / 'paired_probe_evidence.json')
                holdout = experiment.rows(out / 'holdout_evaluation' / 'holdout.jsonl')
                self.assertEqual(32, len(probes['permutation']))
                for episode, probe in zip(holdout, probes['permutation']):
                    self.assertNotEqual([c['id'] for c in episode['variants'][0]['candidates']], probe['candidateOrder'])
                novel = evaluation['novelNumericProjection']['versusTraining']['modelMetrics']['numeric_only']
                self.assertEqual(0, novel['scenarioBuckets']['allties']['n'])
                self.assertEqual(0., novel['scenarioBuckets']['allties']['coverage'])
                self.assertFalse(novel['scenarioBuckets']['allties']['accuracyAtLeast95'])
                with self.assertRaisesRegex(ValueError, 'Holdout already exposed'):
                    experiment.train(out)
                lock = experiment.read(out / 'selection_lock.json')
                lock['adapters']['numeric_only']['numeric_only.pt'] = '0' * 64
                with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                    experiment.load_selected(out, lock)


if __name__ == '__main__':
    unittest.main()
