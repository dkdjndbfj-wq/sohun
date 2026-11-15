"""Execution-policy guard tests using explicit, non-measured runtime doubles."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mifu_server import ApiError, MifuService, SDK_VERSION, load_agent, load_manifest
from runtime_profile import inspect_agent_runtime
from test_mifu_service import StubAgent, StubSampler, make_checkpoint, request
from test_model_acceptance import accepted_runtime
from test_v4_service import fresh_request, v4_checkpoint


class RuntimeProfileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def service(self, agent=None, profile=None, device='cuda', name='checkpoint', v4=False):
        agent = agent or StubAgent(device=device)
        profile = profile or accepted_runtime(device)
        path = self.root / name
        (v4_checkpoint if v4 else make_checkpoint)(path)
        report = json.loads((path / 'acceptance_report.json').read_text(encoding='utf-8'))
        report['runtimeProfile'] = profile
        (path / 'acceptance_report.json').write_text(json.dumps(report), encoding='utf-8')
        service = MifuService(path, self.root / 'data', device=device, agent_loader=lambda *_: agent,
                              input_auditor=lambda *_: {'errors': []}, sampler=StubSampler())
        service.initialize()
        return service, agent, path

    def assert_retired(self, service, request_body=None):
        with self.assertRaises(ApiError) as caught:
            service.decide(request_body or request())
        self.assertEqual('runtime_not_accepted', caught.exception.code)
        self.assertEqual('error', service.state)
        self.assertIsNone(service.agent)
        self.assertIsNone(service.runtime_profile)
        self.assertNotIn(str(self.root), service.last_error)

    def test_matching_runtime_is_bound_to_manifest_and_can_predict(self):
        for index, (device, precision) in enumerate((('cuda', 'float32'), ('cuda', 'bfloat16'),
                                                   ('cuda', 'float16'), ('cpu', 'float32'), ('cpu', 'bfloat16'))):
            with self.subTest(device=device, precision=precision):
                profile = accepted_runtime(device, precision)
                service, agent, path = self.service(StubAgent(device=device, precision=precision), profile,
                                                    device=device, name=f'case-{index}')
                self.assertEqual('ready', service.state)
                self.assertEqual(profile, load_manifest(path)['runtimeProfile'])
                self.assertEqual(profile, service.decide(request())['model']['runtimeProfile'])
                self.assertEqual(1, len(agent.calls))

    def test_fp32_acceptance_cannot_be_reused_by_bf16_or_cpu(self):
        for index, agent in enumerate((StubAgent(device='cuda', precision='bfloat16'), StubAgent(device='cpu'))):
            service, agent, _ = self.service(agent, name=f'mismatch-{index}')
            self.assertEqual('error', service.state)
            self.assertIsNone(service.agent)
            self.assertEqual([], agent.calls)
            with self.assertRaises(ApiError) as caught:
                service.decide(request())
            self.assertEqual('model_unavailable', caught.exception.code)

    def test_missing_or_malformed_runtime_observability_cannot_be_ready(self):
        mutations = [lambda agent: delattr(agent, 'dtype_for'),
                     lambda agent: setattr(agent, 'amp_enabled', None),
                     lambda agent: setattr(agent, 'cpu_fallback_count', 1),
                     lambda agent: setattr(agent, '_amp_failures', 1),
                     lambda agent: setattr(agent.parameter, 'dtype', 'bfloat16'),
                     lambda agent: setattr(agent.parameter, 'device', 'cpu')]
        # Override a class method on the first instance instead of deleting it.
        mutations[0] = lambda agent: setattr(agent, 'dtype_for', None)
        for index, mutate in enumerate(mutations):
            agent = StubAgent(device='cuda')
            mutate(agent)
            service, _, _ = self.service(agent, name=f'missing-{index}')
            with self.subTest(index=index):
                self.assertEqual('error', service.state)
                self.assertIsNone(service.agent)

    def test_checkpoint_amp_config_is_not_assumed_to_be_actual_precision(self):
        agent = StubAgent(device='cuda')
        agent.cfg = {'amp_dtype': 'bf16'}
        self.assertEqual('float32', inspect_agent_runtime(agent)['computePrecision'])
        service, _, _ = self.service(agent)
        self.assertEqual('ready', service.state)

    def test_pre_inference_precision_and_backend_drift_retires_without_predict(self):
        mutations = [lambda agent: (setattr(agent, 'amp_enabled', True), setattr(agent, 'dtype', 'bfloat16')),
                     lambda agent: setattr(agent, 'backend', 'compile'),
                     lambda agent: setattr(agent, '_compiled', True),
                     lambda agent: setattr(agent, '_fast', object()),
                     lambda agent: setattr(agent.model.encoder.config, 'reference_compile', True),
                     lambda agent: setattr(agent.model.encoder.config, '_attn_implementation', 'eager'),
                     lambda agent: setattr(agent.model, 'training', True)]
        for index, mutate in enumerate(mutations):
            service, agent, _ = self.service(name=f'drift-{index}')
            self.assertEqual('ready', service.state)
            mutate(agent)
            with self.subTest(index=index):
                self.assert_retired(service)
                self.assertEqual([], agent.calls)

    def test_counter_drift_before_predict_is_rejected_even_if_device_is_cuda(self):
        for index, counter in enumerate(('cpu_fallback_count', '_amp_failures')):
            service, agent, _ = self.service(name=f'counter-{index}')
            setattr(agent, counter, 1)
            self.assert_retired(service)
            self.assertEqual([], agent.calls)

    def test_scoped_cpu_fallback_counter_discards_result_after_device_restoration(self):
        service, agent, _ = self.service()
        original = agent.predict
        def fallback(*args, **kwargs):
            result = original(*args, **kwargs)
            agent.cpu_fallback_count += 1
            # SDK restores the GPU and precision after its scoped CPU retry.
            self.assertEqual('cuda', agent.device)
            return result
        agent.predict = fallback
        self.assert_retired(service)
        self.assertEqual(1, len(agent.calls))

    def test_cpu_amp_retry_counter_discards_fp32_retry_result(self):
        service, agent, _ = self.service(StubAgent(precision='bfloat16'), accepted_runtime('cpu', 'bfloat16'), device='cpu')
        original = agent.predict
        def fp32_retry(*args, **kwargs):
            result = original(*args, **kwargs)
            agent._amp_failures += 1
            return result
        agent.predict = fp32_retry
        self.assert_retired(service)

    def test_post_prediction_device_and_parameter_drift_discards_result(self):
        for index, mutate in enumerate((lambda agent: setattr(agent, 'device', 'cpu'),
                                       lambda agent: setattr(agent.parameter, 'dtype', 'float16'))):
            service, agent, _ = self.service(name=f'post-{index}')
            original = agent.predict
            def drift(*args, **kwargs):
                result = original(*args, **kwargs)
                mutate(agent)
                return result
            agent.predict = drift
            self.assert_retired(service)

    def test_predict_exception_does_not_hide_fallback_runtime_change(self):
        service, agent, _ = self.service()
        def fails(*args, **kwargs):
            agent.cpu_fallback_count += 1
            raise RuntimeError('private/device/path')
        agent.predict = fails
        self.assert_retired(service)
        self.assertNotIn('private', service.last_error)

    def test_auditor_cannot_change_runtime_between_first_check_and_predict(self):
        service, agent, _ = self.service()
        def input_audit(*args):
            agent.cpu_fallback_count += 1
            return {'errors': []}
        service.input_auditor = input_audit
        self.assert_retired(service)
        self.assertEqual([], agent.calls)

    def test_v4_preflight_cannot_claim_ready_after_runtime_drift(self):
        service, agent, _ = self.service(device='cpu', v4=True)
        agent.tok = object()
        agent.cpu_fallback_count = 1
        checked = service.check_decision(fresh_request())
        self.assertFalse(checked['modelReady'])
        self.assertFalse(checked['canInfer'])
        self.assertEqual('pending', checked['tokenAudit']['status'])
        self.assertEqual('runtime_not_accepted', checked['issues'][0]['code'])
        self.assertEqual([], agent.calls)

    def test_loader_explicitly_keeps_eager_without_fast_or_compilation(self):
        loader = Mock(return_value=object())
        with patch.dict(sys.modules, {'laya': SimpleNamespace(load=loader), 'torch': None}), \
                patch('mifu_server.importlib.metadata.version', return_value=SDK_VERSION):
            load_agent(self.root, 'cuda')
        loader.assert_called_once_with(str(self.root), device='cuda', vegaml=False,
                                        fast=False, compile=False, backend='eager')

    def test_runtime_inspection_and_standard_gate_tests_do_not_import_torch(self):
        with patch.dict(sys.modules, {'torch': None, 'laya': None}):
            service, agent, _ = self.service()
            self.assertEqual('ready', service.state)
            self.assertEqual(accepted_runtime('cuda'), inspect_agent_runtime(agent))
            self.assertEqual('device-01', service.decide(request())['choice'])

    def test_device_request_must_match_acceptance_before_loading(self):
        path = self.root / 'checkpoint'
        make_checkpoint(path)  # Explicit CPU-only acceptance fixture.
        loader = Mock(return_value=StubAgent())
        service = MifuService(path, device='cuda', agent_loader=loader)
        service.initialize()
        self.assertEqual('error', service.state)
        loader.assert_not_called()


if __name__ == '__main__':
    unittest.main()
