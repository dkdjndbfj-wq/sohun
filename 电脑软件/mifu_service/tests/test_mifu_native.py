"""CPU-only native package fixtures; no production model or benchmark is exported."""
from __future__ import annotations

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SERVICE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVICE))
import mifu_native as native

try:
    import torch
except ImportError:
    torch = None


def request(count=3):
    identity = 'native-unit-test-synthetic-evidence'
    return {'requestId': identity,
            'decision_context': {'schema': 'mifu-decision-v4', 'source': 'synthetic_pipeline_only',
                'objective': 'earliest_known_finish', 'snapshot_id': identity,
                'gate_version': 'unit-only', 'observed_at_epoch_s': 0, 'max_age_seconds': 120},
            'plate': {'id': identity, 'remaining_runs': 1, 'estimated_seconds': None},
            'candidates': [{'id': f'device-{i}',
                           'features': {'available_after_seconds': 100 + i, 'setup_seconds': 20 + i,
                                        'run_seconds': 300 + i, 'max_runs': 1, 'queued_runs': None},
                           'admission': {'status': 'synthetic_declared_eligible', 'version': 'unit-only',
                                         'snapshot_id': identity, 'observed_at_epoch_s': 0}}
                          for i in range(count)]}


def fixture(parent):
    """One genuine tiny CPU SGD step, with explicitly unit-fixture provenance."""
    import mifu_numeric_ranker as numeric
    source = Path(parent) / 'source-experiment'
    source.mkdir()
    (source / 'adapters').mkdir()
    torch.manual_seed(12345)
    model = numeric.NumericPairwiseRanker(hidden_sizes=(32, 16), hybrid=False)
    initial = native._tensor_hashes(model.state_dict())
    loss = torch.nn.functional.binary_cross_entropy_with_logits(
        model.pair_logits(torch.tensor([[-1., 2.]], dtype=torch.float64)), torch.ones(1, dtype=torch.float64))
    loss.backward()
    with torch.no_grad():
        for parameter in model.parameters():
            parameter.add_(parameter.grad, alpha=-.01)
    selected = native._tensor_hashes(model.state_dict())
    torch.save(model.state_dict(), source / 'adapters' / 'numeric_only.pt')
    native._write(source / 'adapters' / 'numeric_only.json', model.artifact_config())
    specs = {name: native._sha(source / 'adapters' / name) for name in ('numeric_only.pt', 'numeric_only.json')}
    pipeline = {name: native._sha(SERVICE / name) for name in native.UPSTREAM_PIPELINE}
    flags = {'source': 'synthetic_pipeline_only', 'deployable': False, 'unitTestFixture': True}
    native._write(source / 'plan.json', {**flags, 'schema': 'mifu-numeric-adapter-experiment-v1',
                  'experimentId': 'native-unit-test-one-cpu-step', 'baseWeightsSha256': '0' * 64})
    native._write(source / 'prepared.json', {**flags, 'operationalRecords': 0, 'pipelineSha256': pipeline})
    native._write(source / 'cache_report.json', {**flags, 'pipelineSha256': pipeline,
                  'preparedSha256': native._sha(source / 'prepared.json'),
                  'upstreamBenchmark': 'metadata-only unit test double, no base-model forward'})
    native._write(source / 'training_report.json', {**flags, 'precision': 'float64', 'holdoutRead': False,
                  'pipelineSha256': pipeline, 'planSha256': native._sha(source / 'plan.json'),
                  'cacheReportSha256': native._sha(source / 'cache_report.json'),
                  'models': {'numeric_only': {'files': specs, 'selectedAlpha': None, 'optimizerUpdates': 1,
                      'bestValidationUpdate': 1, 'pairDraws': 1, 'initialTensorSha256': initial,
                      'selectedTensorSha256': selected,
                      'changedSelectedTensors': [n for n in initial if initial[n] != selected[n]]}}})
    native._write(source / 'selection_lock.json', {**flags, 'heldoutNotGenerated': True,
                  'pipelineSha256': pipeline, 'files': {name: native._sha(source / name) for name in native.SOURCE_FILES},
                  'adapters': {'numeric_only': specs}})
    return source


class NativeImportAndFormatTests(unittest.TestCase):
    def test_import_does_not_import_torch_or_base_model_libraries(self):
        code = ('import sys; sys.path.insert(0, ' + repr(str(SERVICE)) + '); '
                'import mifu_native; '
                'assert not any(n in sys.modules for n in ("torch", "laya", "transformers", "tokenizers"))')
        result = subprocess.run([sys.executable, '-B', '-c', code], capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(0, result.returncode, result.stderr)

    def test_duplicate_nonfinite_json_and_escape_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'invalid.json'
            for value in ('{"schema":1,"schema":2}', '{"value":NaN}', '{"value":Infinity}'):
                path.write_text(value, encoding='utf-8')
                with self.assertRaises(ValueError):
                    native._read(path)
            for value in ('../foreign', 'C:/foreign/file', '..\\foreign'):
                with self.assertRaises(ValueError):
                    native._path(folder, value)

    def test_native_requirements_do_not_pull_a_model_sdk(self):
        lines = [line for line in (SERVICE / 'requirements-native.txt').read_text().splitlines()
                 if line.strip() and not line.startswith('#')]
        self.assertEqual(['torch==2.11.0'], lines)


@unittest.skipIf(torch is None, 'CPU PyTorch required')
class NativePackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = fixture(self.root)
        self.package = self.root / 'native-package'

    def tearDown(self):
        self.temp.cleanup()

    def export(self):
        return native.export_package(self.source, self.package)

    def reseal(self, relative):
        manifest = native._read(self.package / 'manifest.json')
        manifest['files'][relative] = native._sha(self.package / relative)
        (self.package / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')

    def test_export_keeps_weight_bytes_and_provenance_without_base_runtime(self):
        before = {name: native._sha(self.source / name) for name in native.SOURCE_FILES + ('selection_lock.json',)}
        manifest = self.export()
        self.assertEqual(before, {name: native._sha(self.source / name) for name in before})
        self.assertEqual(native._sha(self.source / 'adapters' / 'numeric_only.pt'), native._sha(self.package / 'model.pt'))
        self.assertEqual('Mifu Core', manifest['brand'])
        self.assertFalse(manifest['baseCheckpointUsed'])
        self.assertFalse(manifest['acceptedForProduction'])
        self.assertEqual({'manifest.json', *native.PACKAGE_FILES},
                         {p.relative_to(self.package).as_posix() for p in self.package.rglob('*') if p.is_file()})
        provenance = native._read(self.package / 'provenance.json')
        self.assertEqual('Laya', provenance['upstreamBenchmark']['name'])
        self.assertIn('not Mifu Core', provenance['upstreamBenchmark']['role'])

    def test_numpy_free_tensor_audit_matches_original_selection_audit(self):
        from train_numeric_adapter import tensor_fingerprint
        state = torch.load(self.source / 'adapters' / 'numeric_only.pt', map_location='cpu', weights_only=True)
        self.assertEqual(tensor_fingerprint(state), native._tensor_hashes(state))

    def test_loading_and_prediction_work_with_base_libraries_unavailable(self):
        blocked = {name: None for name in ('laya', 'transformers', 'tokenizers', 'safetensors')}
        with patch.dict(sys.modules, blocked), patch.object(torch.cuda, '_lazy_init', side_effect=AssertionError('GPU forbidden')):
            self.export()
            core = native.load_package(self.package)
            result = core.predict(request(), now_epoch_s=0)
        self.assertEqual('Mifu Core', result['brand'])
        self.assertEqual({'device-0', 'device-1', 'device-2'}, set(result['scores']))
        self.assertEqual(max(result['scores'], key=result['scores'].get), result['choice'])
        self.assertFalse(result['acceptedForProduction'])
        self.assertTrue(result['advisoryOnly'])
        self.assertNotIn('successProbability', result)
        self.assertEqual('float64', result['dtype'])

    def test_unknown_evidence_objective_stale_and_labels_are_rejected(self):
        self.export()
        core = native.load_package(self.package)
        variants = []
        for name in ('available_after_seconds', 'setup_seconds', 'run_seconds'):
            value = request(); value['candidates'][0]['features'][name] = None; variants.append(value)
        value = request(); value['decision_context']['objective'] = 'earliest_known_availability'; variants.append(value)
        value = request(); value['expected'] = 'device-0'; variants.append(value)
        value = request(); value['candidates'][0]['features']['run_seconds'] = float('nan'); variants.append(value)
        for value in variants:
            with self.assertRaises(ValueError):
                core.predict(value, now_epoch_s=0)
        with self.assertRaises(ValueError):
            core.predict(request(), now_epoch_s=121)
        with self.assertRaises(ValueError):
            core.predict(request(1), now_epoch_s=0)
        with self.assertRaises(ValueError):
            core.predict(request(), now_epoch_s=True)

    def test_export_refuses_existing_or_nested_output(self):
        self.package.mkdir()
        sentinel = self.package / 'keep.txt'; sentinel.write_text('keep')
        with self.assertRaises(FileExistsError):
            self.export()
        self.assertEqual('keep', sentinel.read_text())
        with self.assertRaises(ValueError):
            native.export_package(self.source, self.source / 'native-child')

    def test_source_hash_and_claim_mutations_refuse_before_export(self):
        path = self.source / 'plan.json'
        path.write_text(path.read_text() + ' ')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.export()
        self.assertFalse(self.package.exists())

    def test_package_weight_tampering_and_memory_changes_are_rejected(self):
        self.export()
        core = native.load_package(self.package)
        with torch.no_grad():
            next(core._model.parameters()).add_(1.)
        with self.assertRaisesRegex(ValueError, 'changed in memory'):
            core.predict(request(), now_epoch_s=0)
        path = self.package / 'model.pt'
        path.write_bytes(path.read_bytes() + b'changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            native.load_package(self.package)

    def test_rehashed_identity_or_source_claim_cannot_become_ready(self):
        self.export()
        manifest = native._read(self.package / 'manifest.json')
        for field, value in [('acceptedForProduction', True), ('baseCheckpointUsed', True),
                             ('trainingSource', 'real_operations'), ('operationalTrainingRecords', False),
                             ('schema', 'different-schema')]:
            changed = copy.deepcopy(manifest); changed[field] = value
            (self.package / 'manifest.json').write_text(json.dumps(changed), encoding='utf-8')
            with self.assertRaises(ValueError):
                native.load_package(self.package)

    def test_rehashed_provenance_and_config_cannot_override_selection(self):
        self.export()
        config = native._read(self.package / 'model_config.json')
        config['hybrid'] = True
        (self.package / 'model_config.json').write_text(json.dumps(config), encoding='utf-8')
        self.reseal('model_config.json')
        with self.assertRaisesRegex(ValueError, 'source lock'):
            native.load_package(self.package)

    def test_exact_provenance_types_and_loaded_inventory_are_enforced(self):
        self.export()
        core = native.load_package(self.package)
        extra = self.package / 'added-after-loading.bin'; extra.write_bytes(b'extra')
        with self.assertRaisesRegex(ValueError, 'inventory changed'):
            core.predict(request(), now_epoch_s=0)
        extra.unlink()
        provenance = native._read(self.package / 'provenance.json')
        provenance['operationalTrainingRecords'] = False
        (self.package / 'provenance.json').write_text(json.dumps(provenance), encoding='utf-8')
        self.reseal('provenance.json')
        with self.assertRaisesRegex(ValueError, 'provenance was altered'):
            native.load_package(self.package)

    def test_hybrid_nonfinite_and_oversized_state_dictionaries_are_rejected(self):
        config = native._read(self.source / 'adapters' / 'numeric_only.json')
        changed = copy.deepcopy(config); changed['hybrid'] = True
        with self.assertRaisesRegex(ValueError, 'hybrid'):
            native._load_head(changed, self.source / 'adapters' / 'numeric_only.pt')
        changed = copy.deepcopy(config); changed['acceptedForProduction'] = False
        with self.assertRaises(ValueError):
            native._load_head(changed, self.source / 'adapters' / 'numeric_only.pt')
        changed = copy.deepcopy(config); changed['deployable'] = 0
        with self.assertRaisesRegex(ValueError, 'exact field types'):
            native._load_head(changed, self.source / 'adapters' / 'numeric_only.pt')
        state = torch.load(self.source / 'adapters' / 'numeric_only.pt', weights_only=True, map_location='cpu')
        next(iter(state.values())).view(-1)[0] = float('nan')
        bad = self.root / 'nonfinite.pt'; torch.save(state, bad)
        with self.assertRaisesRegex(ValueError, 'Invalid float64'):
            native._load_head(config, bad)
        oversized = self.root / 'oversized.pt'; oversized.write_bytes(b'0' * (1024 * 1024 + 1))
        with self.assertRaisesRegex(ValueError, 'small native'):
            native._load_head(config, oversized)

    def test_missing_extra_and_path_escape_inventory_are_rejected(self):
        self.export()
        extra = self.package / 'unknown-model.bin'; extra.write_bytes(b'not allowed')
        with self.assertRaisesRegex(ValueError, 'Unexpected/missing'):
            native.load_package(self.package)
        extra.unlink()
        manifest = native._read(self.package / 'manifest.json')
        manifest['files']['../outside'] = '0' * 64
        (self.package / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            native.load_package(self.package)

    def test_external_manifest_pin_and_loaded_manifest_changes_are_rejected(self):
        self.export()
        core = native.load_package(self.package, expected_manifest_sha256=native._sha(self.package / 'manifest.json'))
        with self.assertRaisesRegex(ValueError, 'externally pinned'):
            native.load_package(self.package, expected_manifest_sha256='0' * 64)
        path = self.package / 'manifest.json'; path.write_text(path.read_text() + ' ', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'manifest changed'):
            core.predict(request(), now_epoch_s=0)

    def test_exported_cli_is_standalone_repeatable_without_base_libraries_or_bytecode_writes(self):
        self.export()
        data = self.root / 'request.json'; native._write(data, request())
        result_path = self.root / 'prediction.json'
        code = ('import sys,runpy; sys.path.insert(0, ' + repr(str(self.package)) + '); '
                'sys.modules.update({n:None for n in ("laya","transformers","tokenizers","safetensors")}); '
                'sys.argv=["mifu_native.py","infer","--package",' + repr(str(self.package)) + ',"--request",'
                + repr(str(data)) + ',"--out",' + repr(str(result_path)) + ',"--now-epoch","0"]; '
                'runpy.run_path(' + repr(str(self.package / 'mifu_native.py')) + ',run_name="__main__")')
        result = subprocess.run([sys.executable, '-c', code], cwd=self.root, capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('Mifu Core', native._read(result_path)['brand'])
        self.assertFalse((self.package / '__pycache__').exists())
        native.load_package(self.package)
        second = subprocess.run([sys.executable, '-c', code], cwd=self.root, capture_output=True, text=True, encoding='utf-8')
        self.assertNotEqual(0, second.returncode)
        self.assertIn('FileExistsError', second.stderr)


if __name__ == '__main__':
    unittest.main()
