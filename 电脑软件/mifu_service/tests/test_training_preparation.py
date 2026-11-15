from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_curriculum import FAMILIES, SPLITS, digest, make_rows, prepare, read_catalog, validate_bundle
from run_curriculum_experiment import run
from training import train_model

CATALOG = Path(__file__).resolve().parents[1] / 'training_curriculum.json'


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def bundle(self):
        path = self.root / 'bundle'
        prepare(path, CATALOG)
        return path

    def base(self):
        path = self.root / 'base'
        path.mkdir()
        (path / 'model.safetensors').write_bytes(b'unit-test-only-no-real-weights')
        (path / 'rl_agent_config.json').write_text('{"encoder":"jhu-clsp/mmBERT-base"}', encoding='utf-8')
        return path

    def test_catalog_covers_all_original_scenarios_without_claiming_training(self):
        catalog = read_catalog(CATALOG)
        self.assertEqual(46, len(catalog['scenarios']))
        self.assertTrue(any(item['capability'] == 'future_input' for item in catalog['scenarios']))
        self.assertTrue(any('hard_gate' in item['routes'] for item in catalog['scenarios']))

    def test_related_permutations_stay_together_and_labels_follow_candidate_mapping(self):
        datasets = make_rows(4070, 40)
        seen = {}
        for split, rows in datasets.items():
            self.assertTrue(rows)
            for row in rows:
                origin = row['mifu_provenance']
                self.assertEqual('synthetic_pipeline_only', origin['source'])
                self.assertEqual(split, seen.setdefault(origin['groupId'], split))
                criteria = row['questions']['printer']['criteria']
                costs = {key: json.loads(value)['available_after_seconds'] for key, value in criteria.items()}
                self.assertEqual(min(costs, key=costs.get), row['expected']['printer'])
                self.assertNotIn('sim-device-', json.dumps(row['state']))
                self.assertNotIn('taskId', row['state']['plate'])
        self.assertEqual(120, len(seen))
        self.assertEqual(240, sum(len(rows) for rows in datasets.values()))
        self.assertEqual(datasets, make_rows(4070, 40))

    def test_queue_counts_cannot_substitute_for_wait_duration(self):
        rows = [row for values in make_rows(4070, 20).values() for row in values
                if row['mifu_provenance']['family'] == 'queue_count_decoy']
        self.assertTrue(rows)
        for row in rows:
            criteria = {key: json.loads(value) for key, value in row['questions']['printer']['criteria'].items()}
            selected = row['expected']['printer']
            self.assertGreater(criteria[selected]['queued_runs'], min(item['queued_runs'] for item in criteria.values()))

    def test_bundle_is_explicitly_not_deployable_and_real_coverage_is_zero(self):
        bundle = self.bundle()
        manifest = validate_bundle(bundle)
        self.assertFalse(manifest['deployable'])
        self.assertFalse(manifest['domainTrainingCompleted'])
        coverage = json.loads((bundle / 'coverage.json').read_text(encoding='utf-8'))
        self.assertTrue(all(item['realReviewedExamples'] == 0 and not item['evaluationPassed'] for item in coverage))
        self.assertFalse((bundle / 'mifu_manifest.json').exists())

    def test_existing_output_is_not_overwritten(self):
        bundle = self.bundle()
        before = digest(bundle / 'train.jsonl')
        with self.assertRaises(FileExistsError):
            prepare(bundle, CATALOG)
        self.assertEqual(before, digest(bundle / 'train.jsonl'))

    def test_tampered_dataset_is_rejected(self):
        bundle = self.bundle()
        with (bundle / 'holdout.jsonl').open('a', encoding='utf-8') as handle:
            handle.write('{}\n')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            validate_bundle(bundle)

    def test_group_leak_is_rejected_even_with_updated_file_hash(self):
        bundle = self.bundle()
        train_path = bundle / 'train.jsonl'
        rows = [json.loads(line) for line in train_path.read_text(encoding='utf-8').splitlines()]
        other = json.loads((bundle / 'holdout.jsonl').read_text(encoding='utf-8').splitlines()[0])
        rows[0]['mifu_provenance']['groupId'] = other['mifu_provenance']['groupId']
        train_path.write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')
        manifest_path = bundle / 'experiment_manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        manifest['files']['train']['sha256'] = digest(train_path)
        manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'group leaks'):
            validate_bundle(bundle)

    def test_formal_training_rejects_pipeline_synthetic_data(self):
        bundle = self.bundle()
        with self.assertRaisesRegex(ValueError, 'Synthetic pipeline data'):
            train_model(bundle / 'train.jsonl', bundle / 'validation.jsonl', self.base(), self.root / 'production', 'test', dry_run=True)
        self.assertFalse((self.root / 'production').exists())

    def test_experiment_dry_run_never_loads_gpu_or_creates_output(self):
        bundle = self.bundle()
        with patch.dict(sys.modules, {'torch': None, 'laya': None}):
            result = run(bundle, self.base(), self.root / 'experiment', dry_run=True)
        self.assertFalse(result['deployable'])
        self.assertEqual(['calibration', 'holdout'], result['reservedSplits'])
        self.assertFalse((self.root / 'experiment').exists())

    def test_experimental_training_does_not_create_production_manifest(self):
        bundle = self.bundle()
        output = self.root / 'experiment'
        calls = []
        torch_stub = types.ModuleType('torch')
        torch_stub.cuda = types.SimpleNamespace(is_available=lambda: True,
            synchronize=lambda: None, reset_peak_memory_stats=lambda: None,
            get_device_name=lambda index: 'stub_not_gpu_evidence',
            max_memory_allocated=lambda: 0, max_memory_reserved=lambda: 0)
        train_stub = types.ModuleType('laya.train')
        train_stub.TrainConfig = lambda **kwargs: kwargs

        def finetune(data, base, out, config, device):
            calls.append((data, config, device))
            return {'train_items': 132, 'train_report': {'is_held_out': True, 'eval_items': 36}}

        train_stub.finetune = finetune
        with patch.dict(sys.modules, {'torch': torch_stub, 'laya.train': train_stub}), patch('importlib.metadata.version', return_value='0.4.31'):
            result = run(bundle, self.base(), output)
        self.assertFalse(result['deployable'])
        self.assertFalse((output / 'mifu_manifest.json').exists())
        self.assertTrue((output / 'experiment_report.json').exists())
        self.assertEqual(str(bundle / 'train.jsonl'), calls[0][0])
        self.assertTrue(calls[0][1]['freeze_encoder'])
        self.assertEqual(0.0, calls[0][1]['calib_frac'])
        self.assertEqual(0, calls[0][1]['calib_max'])
        self.assertNotIn('holdout', calls[0][1]['eval_data'])

    def test_hardware_experiment_rejects_truncated_evidence_before_training(self):
        bundle = self.bundle()
        manifest_path = bundle / 'experiment_manifest.json'
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        manifest['featureSchemaVersion'] = 'hardware-test-fixture'
        for split in manifest['files']:
            path = bundle / f'{split}.jsonl'
            rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
            for row in rows:
                row['state']['featureSchemaVersion'] = 'hardware-test-fixture'
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')
            manifest['files'][split]['sha256'] = digest(path)
        manifest_path.write_text(json.dumps(manifest), encoding='utf-8')
        torch_stub = types.ModuleType('torch')
        torch_stub.cuda = types.SimpleNamespace(is_available=lambda: True)
        transformers_stub = types.ModuleType('transformers')
        transformers_stub.AutoTokenizer = types.SimpleNamespace(from_pretrained=lambda *a, **kw: object())
        output = self.root / 'must-not-train'
        with patch.dict(sys.modules, {'torch': torch_stub, 'transformers': transformers_stub, 'laya.train': None}), \
                patch('importlib.metadata.version', return_value='0.4.31'), \
                patch('audit_token_budget.inspect_question', return_value={'errors': ['option_description_truncated']}):
            with self.assertRaisesRegex(ValueError, 'would lose evidence'):
                run(bundle, self.base(), output)
        self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
