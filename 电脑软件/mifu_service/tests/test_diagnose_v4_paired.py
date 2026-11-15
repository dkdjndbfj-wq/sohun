import ast
import copy
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diagnose_v4_paired as probe


class FakeSdk:
    def items_from_rows(self, tokenizer, rows, max_len, head_max_len):
        row = rows[0]
        labels = list(row['questions']['printer']['criteria'])
        return [{'k': len(labels), 'input': {k: row[k] for k in ('state', 'questions')},
                 'target': labels.index(row['expected']['printer'])}], {}

    def encode_item(self, tokenizer, item, max_len, head_max_len, order, parallel):
        return {'ids': list(probe.canonical(item['input'])), 'markers': order,
                'qtype': 0, 'layout': {'option_ids': order}, 'target': item['target']}


class PairedGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cases = probe.generate_cases()

    def test_fixed_seed_budget_balancing_and_reproducibility(self):
        self.assertEqual(probe.SEED, 2026111307)
        self.assertEqual(self.cases, probe.generate_cases())
        self.assertEqual(len({case['caseId'] for case in self.cases}), 32)
        self.assertEqual(probe.plan()['maxForwardCalls'], 32 * 8 * 2)
        self.assertEqual(probe.plan()['trainingUpdates'], 0)
        self.assertEqual(probe.plan()['precision'], 'bf16')
        for k in (2, 4, 8, 16):
            for band in ('small', 'large'):
                self.assertEqual(sum(c['candidateCount'] == k and c['gapBand'] == band
                                     for c in self.cases), 4)

    def test_all_pairs_preserve_exact_finish_prep_winner_and_valid_evidence(self):
        for case in self.cases:
            a, b = case['commonRequest'], case['variableRequest']
            self.assertEqual(probe.costs(a), probe.costs(b))
            self.assertEqual(min(probe.costs(a), key=probe.costs(a).get), case['expectedCandidateId'])
            self.assertIsNone(a['plate']['estimated_seconds'])
            self.assertIsNone(b['plate']['estimated_seconds'])
            self.assertEqual(len({c['features']['run_seconds'] for c in a['candidates']}), 1)
            self.assertGreater(len({c['features']['run_seconds'] for c in b['candidates']}), 1)
            for first, second in zip(a['candidates'], b['candidates']):
                expected = copy.deepcopy(first)
                for field in ('run_seconds', 'available_after_seconds'):
                    expected['features'][field] = second['features'][field]
                self.assertEqual(expected, second)
                self.assertGreaterEqual(second['features']['available_after_seconds'], 0)
                self.assertGreater(second['features']['run_seconds'], 0)
            for variant in probe.VARIANTS:
                prepared = probe.prepare_variant(case, variant)
                self.assertEqual(len(prepared['mapping']), case['candidateCount'])

    def test_every_variant_changes_only_its_declared_factor(self):
        for case in self.cases:
            variants = {v: probe.prepare_variant(case, v) for v in probe.VARIANTS}
            a, b, c, d = (variants[v] for v in 'ABCD')
            self.assertEqual(a['modelInput']['state'], b['modelInput']['state'])
            self.assertEqual(a['mapping'], b['mapping'])
            for label, first in a['modelInput']['questions']['printer']['criteria'].items():
                second = b['modelInput']['questions']['printer']['criteria'][label]
                self.assertEqual(first.split(';')[1:], second.split(';')[1:])
            expected = copy.deepcopy(a['modelInput'])
            expected['state']['plate']['run_s'] = case['commonRunSeconds']
            self.assertEqual(c['modelInput'], expected)
            self.assertEqual(b['modelInput']['state'], d['modelInput']['state'])
            self.assertEqual(b['mapping'], d['mapping'])
            self.assertEqual(d['projection'], probe.PROJECTION)
            for label, padded in d['modelInput']['questions']['printer']['criteria'].items():
                fields = padded.split('; ')
                self.assertTrue(all(len(field.split()[1][:-1]) == 7 for field in fields))
                normalized = '; '.join(f'{field.split()[0]} {int(field.split()[1][:-1])}s' for field in fields)
                self.assertEqual(normalized, b['modelInput']['questions']['printer']['criteria'][label])
            for original, slot, physical in (('A', 'E', 'G'), ('B', 'F', 'H')):
                baseline, shuffled, rebuilt = variants[original], variants[slot], variants[physical]
                self.assertEqual(baseline['modelInput'], shuffled['modelInput'])
                self.assertEqual(baseline['mapping'], shuffled['mapping'])
                self.assertEqual(baseline['inputSha256'], shuffled['inputSha256'])
                self.assertEqual(baseline['slotPhysicalIds'][::-1], shuffled['slotPhysicalIds'])
                self.assertEqual(baseline['slotPhysicalIds'][::-1], rebuilt['slotPhysicalIds'])
                by_id = {baseline['mapping'][label]: text for label, text in
                         baseline['modelInput']['questions']['printer']['criteria'].items()}
                other = {rebuilt['mapping'][label]: text for label, text in
                         rebuilt['modelInput']['questions']['printer']['criteria'].items()}
                self.assertEqual(by_id, other)

    def test_sidecar_oracle_changes_no_projection_or_encoding(self):
        original = self.cases[0]
        changed = copy.deepcopy(original)
        changed['expectedCandidateId'] = 'deliberately-wrong-sidecar'
        for variant in probe.VARIANTS:
            first = probe.prepare_variant(original, variant)
            second = probe.prepare_variant(changed, variant)
            self.assertEqual(first, second)
            encoded = probe.encode_label_independent(first, None, FakeSdk())
            self.assertNotIn('target', encoded)
            self.assertNotIn('label', encoded)
            self.assertEqual(encoded, probe.encode_label_independent(second, None, FakeSdk()))

    def test_target_sensitive_encoder_is_rejected(self):
        class LeakingSdk(FakeSdk):
            def encode_item(self, *args):
                encoded = super().encode_item(*args)
                encoded['ids'].append(encoded['target'])
                return encoded
        with self.assertRaisesRegex(ValueError, 'sidecar target'):
            probe.encode_label_independent(probe.prepare_variant(self.cases[0], 'A'), None, LeakingSdk())

    def test_label_in_model_input_is_rejected_recursively(self):
        for key in ('expected', 'gold', 'winner', 'oracle_rank', 'selectedCandidateId'):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'Label leaked'):
                probe._reject_model_labels({'state': [{'nested': {key: 'bad'}}]})

    def test_physical_mapping_unpermutes_slots_and_regret_exactly(self):
        case = self.cases[0]
        for variant in probe.VARIANTS:
            prepared = probe.prepare_variant(case, variant)
            winner = prepared['slotPhysicalIds'].index(case['expectedCandidateId'])
            logits = [-2.0] * case['candidateCount']
            logits[winner] = 3.5
            result = probe.outcome(case, prepared, logits)
            self.assertTrue(result['correct'])
            self.assertEqual(result['regretSeconds'], 0)
            self.assertEqual(result['topTwoMargin'], 5.5)
            self.assertEqual(result['rawLogitsByPhysicalId'][case['expectedCandidateId']], 3.5)
        for logits in ([float('nan')] * case['candidateCount'], [0], [True] * case['candidateCount']):
            with self.assertRaises(ValueError):
                probe.outcome(case, probe.prepare_variant(case, 'A'), logits)

    def test_generate_only_cli_works_without_site_packages_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder) / 'fresh'
            command = [sys.executable, '-S', str(Path(probe.__file__).resolve()),
                       'generate-only', '--out', str(destination)]
            completed = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            before = {p.name: p.read_bytes() for p in destination.iterdir()}
            _, cases, manifest = probe.read_bundle(destination)
            self.assertEqual(cases, self.cases)
            self.assertFalse(manifest['deployable'])
            repeated = subprocess.run(command, capture_output=True, text=True, timeout=30)
            self.assertNotEqual(repeated.returncode, 0)
            self.assertEqual(before, {p.name: p.read_bytes() for p in destination.iterdir()})

    def test_bundle_detects_bytes_plan_and_rehashed_case_tampering(self):
        for kind in ('bytes', 'plan', 'cases', 'runner'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as folder:
                destination = Path(folder) / 'fresh'
                probe.generate_bundle(destination)
                manifest = json.loads((destination / 'manifest.json').read_text())
                if kind == 'bytes':
                    with (destination / 'cases.jsonl').open('ab') as handle:
                        handle.write(b' ')
                elif kind == 'plan':
                    altered = probe.plan()
                    altered['maxForwardCalls'] = 1024
                    (destination / 'plan.json').write_bytes(probe.canonical(altered))
                    manifest['planSha256'] = probe._file_digest(destination / 'plan.json')
                elif kind == 'cases':
                    altered = copy.deepcopy(self.cases)
                    altered[0]['expectedCandidateId'] = 'unit-wrong'
                    (destination / 'cases.jsonl').write_bytes(b''.join(probe.canonical(c) + b'\n' for c in altered))
                    manifest['casesSha256'] = probe._file_digest(destination / 'cases.jsonl')
                else:
                    manifest['runnerSha256'] = '0' * 64
                (destination / 'manifest.json').write_bytes(probe.canonical(manifest))
                with self.assertRaises(ValueError):
                    probe.read_bundle(destination)

    def test_no_training_or_checkpoint_write_calls_in_runner(self):
        tree = ast.parse(Path(probe.__file__).read_text(encoding='utf-8'))
        called = {node.func.attr for node in ast.walk(tree)
                  if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)}
        self.assertFalse(called & {'backward', 'save_checkpoint', 'AdamW', 'Adam', 'SGD'})


class PairedExecutionControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / 'frozen-bundle'
        probe.generate_bundle(self.bundle)
        self.specs = {name: {'path': self.root / 'models' / name, 'sha256': weight}
                      for name, weight in probe.MODELS.items()}
        self.events = []

    def inventory(self, path):
        name = Path(path).name
        return {'model.safetensors': probe.MODELS[name], 'rl_agent_config.json': 'a' * 64,
                'encoder/config.json': 'b' * 64, 'tokenizer/tokenizer.json': 'c' * 64,
                'tokenizer/tokenizer_config.json': 'd' * 64}

    def engine(self, path, deadline):
        parent = self
        name = Path(path).name
        parent.events.append(('load', name))
        class Engine:
            runtime = {'testOnlyFakeEngine': True}
            forward_calls = 0
            def predict(self, prepared, deadline):
                self.forward_calls += 1
                return {'logits': list(range(len(prepared['slotOrder']))),
                        'encodingSha256': probe.digest(prepared),
                        'tokenAudit': {'status': 'fake-test-only'},
                        'sidecarLabelEncodingInvariant': True}
            def close(self):
                parent.events.append(('close', name))
        return Engine()

    def test_exact_512_single_sample_calls_sequential_models_and_grouped_pairs(self):
        with patch.object(probe, '_inventory', side_effect=self.inventory), patch('sys.stdout', new=io.StringIO()):
            report = probe.evaluate_bundle(self.bundle, self.root / 'result', self.specs, engine_factory=self.engine)
        self.assertEqual(report['status'], 'completed_diagnostic_only')
        self.assertEqual(report['modelForwardCalls'], 512)
        self.assertEqual(report['sampleForwardCalls'], 512)
        self.assertEqual(report['completedPredictions'], 512)
        self.assertEqual(report['independentBaseCases'], 32)
        self.assertEqual(report['trainingUpdates'], 0)
        self.assertTrue(report['checkpointArtifactsUnchanged'])
        self.assertTrue(report['pairedModelEncodingsIdentical'])
        journal = [json.loads(line) for line in (self.root / 'result' / 'results.jsonl').read_text().splitlines()]
        self.assertEqual(journal, report['results'])
        self.assertEqual(self.events, [('load', 'H'), ('close', 'H'), ('load', 'final512'), ('close', 'final512')])
        for model in probe.MODELS:
            measured = report['metrics']['byModel'][model]
            for variant in probe.VARIANTS:
                self.assertEqual(measured['variants'][variant]['overall']['n'], 32)
                self.assertEqual(measured['variants'][variant]['countGap']['16/small']['n'], 4)
            self.assertEqual(measured['paired']['A:E']['overall']['n'], 32)
        self.assertEqual(report['metrics']['betweenModels']['A']['overall']['consistency'], 1)
        with self.assertRaises(FileExistsError):
            probe.evaluate_bundle(self.bundle, self.root / 'result', self.specs, engine_factory=self.engine)

    def test_both_checkpoint_hashes_checked_before_first_model_load(self):
        def broken(path):
            result = self.inventory(path)
            if Path(path).name == 'final512':
                result['model.safetensors'] = '0' * 64
            return result
        with patch.object(probe, '_inventory', side_effect=broken), patch('sys.stdout', new=io.StringIO()):
            report = probe.evaluate_bundle(self.bundle, self.root / 'bad-hash', self.specs, engine_factory=self.engine)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['forwardCalls'], 0)
        self.assertEqual(self.events, [])

    def test_optional_complete_hash_lock_and_incomplete_inventory_fail(self):
        lock = self.root / 'external-lock.json'
        expected = self.inventory(self.specs['H']['path'])
        lock.write_bytes(probe.canonical({'artifactsSha256': expected}))
        self.specs['H']['artifacts'] = lock
        with patch.object(probe, '_inventory', side_effect=self.inventory):
            self.assertEqual(probe.lock_checkpoints(self.specs)['H'], expected)
        expected['tokenizer/tokenizer_config.json'] = 'e' * 64
        lock.write_bytes(probe.canonical(expected))
        with patch.object(probe, '_inventory', side_effect=self.inventory), self.assertRaisesRegex(ValueError, 'complete artifact'):
            probe.lock_checkpoints(self.specs)

    def test_tokenizer_or_architecture_difference_stops_before_loading(self):
        for field in ('tokenizer/tokenizer.json', 'encoder/config.json'):
            def different(path):
                result = self.inventory(path)
                if Path(path).name == 'final512':
                    result[field] = 'e' * 64
                return result
            with self.subTest(field=field), patch.object(probe, '_inventory', side_effect=different):
                with self.assertRaisesRegex(ValueError, 'architecture/tokenizer'):
                    probe.lock_checkpoints(self.specs)
        with patch.object(probe, '_inventory', return_value={'model.safetensors': probe.MODELS['H']}), self.assertRaisesRegex(ValueError, 'incomplete'):
            probe.lock_checkpoints(self.specs)

    def test_output_never_overlaps_models_or_frozen_bundle(self):
        h = self.specs['H']['path']
        for output in (h, h / 'new', h.parent, self.bundle, self.bundle / 'new', self.root):
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, 'separate'):
                probe.evaluate_bundle(self.bundle, output, self.specs, engine_factory=self.engine)
        self.assertFalse((h / 'new').exists())
        self.assertEqual(self.events, [])

    def test_failure_keeps_attempted_forward_count_and_releases_model_without_retry(self):
        def failing(path, deadline):
            engine = self.engine(path, deadline)
            def predict(prepared, deadline):
                engine.forward_calls += 1
                raise ValueError('simulated failure after one forward')
            engine.predict = predict
            return engine
        with patch.object(probe, '_inventory', side_effect=self.inventory), patch('sys.stdout', new=io.StringIO()):
            report = probe.evaluate_bundle(self.bundle, self.root / 'failed-forward', self.specs, engine_factory=failing)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['forwardCalls'], 1)
        self.assertEqual(report['completedPredictions'], 0)
        self.assertEqual(self.events, [('load', 'H'), ('close', 'H')])
        self.assertTrue((self.root / 'failed-forward' / 'report.json').exists())

    def test_model_encoding_difference_is_preserved_and_fails_without_continuing(self):
        def different(path, deadline):
            engine = self.engine(path, deadline)
            original = engine.predict
            def predict(prepared, deadline):
                result = original(prepared, deadline)
                if Path(path).name == 'final512':
                    result['encodingSha256'] = '0' * 64
                return result
            engine.predict = predict
            return engine
        with patch.object(probe, '_inventory', side_effect=self.inventory), patch('sys.stdout', new=io.StringIO()):
            report = probe.evaluate_bundle(self.bundle, self.root / 'encoding-drift', self.specs, engine_factory=different)
        self.assertEqual(report['status'], 'failed')
        self.assertIn('encoded input', report['error']['message'])
        self.assertEqual(report['forwardCalls'], 257)
        self.assertEqual(report['completedPredictions'], 257)
        self.assertEqual(len((self.root / 'encoding-drift' / 'results.jsonl').read_text().splitlines()), 257)
        self.assertEqual(self.events[-1], ('close', 'final512'))

    def test_deadline_stops_before_loading_and_does_not_extend_budget(self):
        with patch.object(probe, '_inventory', side_effect=self.inventory), patch.object(probe.time, 'monotonic', side_effect=[0, 1200, 1201]):
            report = probe.evaluate_bundle(self.bundle, self.root / 'timeout', self.specs, engine_factory=self.engine)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['error']['type'], 'TimeoutError')
        self.assertEqual(report['forwardCalls'], 0)
        self.assertEqual(self.events, [])

    def test_loader_mutation_is_detected_before_inference_and_in_final_inventory(self):
        mutated = False
        def inventory(path):
            result = self.inventory(path)
            if mutated and Path(path).name == 'H':
                result['tokenizer/tokenizer_config.json'] = '0' * 64
            return result
        def mutating(path, deadline):
            nonlocal mutated
            mutated = True
            return self.engine(path, deadline)
        with patch.object(probe, '_inventory', side_effect=inventory), patch('sys.stdout', new=io.StringIO()):
            report = probe.evaluate_bundle(self.bundle, self.root / 'mutation', self.specs, engine_factory=mutating)
        self.assertEqual(report['status'], 'failed')
        self.assertFalse(report['checkpointArtifactsUnchanged'])
        self.assertEqual(report['forwardCalls'], 0)
        self.assertEqual(self.events, [('load', 'H'), ('close', 'H')])


if __name__ == '__main__':
    unittest.main()
