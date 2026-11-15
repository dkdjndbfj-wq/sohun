"""Versioned live HTTP tests; all model outputs are explicit test stubs."""
import copy
import http.client
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from decision_contract import SCHEMA, normalize_request
from mifu_server import LocalServer, MifuService, load_manifest
from model_acceptance import checkpoint_artifact_hashes
from training import export_dataset, train_model
from test_decision_contract import live_request
from test_mifu_service import StubAgent, StubSampler, make_checkpoint, request as legacy_request
from test_model_acceptance import accepted_report


def fresh_request(count=2):
    body = live_request(count)
    now = int(time.time()) - 1
    body['decision_context']['observed_at_epoch_s'] = now
    body['plate']['taskId'] = 'task-v4'
    for candidate in body['candidates']:
        candidate['admission']['observed_at_epoch_s'] = now
        for key in ('setup', 'wait'):
            candidate['features']['timing_evidence'][key]['observed_at_epoch_s'] = now
    return body


def v4_checkpoint(path):
    manifest = make_checkpoint(path)
    manifest.update(inputContract=SCHEMA, supportedObjectives=['earliest_known_finish'])
    (path / 'mifu_manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
    config_path = path / 'rl_agent_config.json'
    cfg = json.loads(config_path.read_text())
    cfg.update(max_len=2048, head_max_len=1024, option_layout='parallel')
    config_path.write_text(json.dumps(cfg), encoding='utf-8')
    acceptance = accepted_report(manifest['weightsSha256'], SCHEMA, checkpoint_artifact_hashes(path))
    acceptance['supportedObjectives'] = ['earliest_known_finish']
    (path / 'acceptance_report.json').write_text(json.dumps(acceptance), encoding='utf-8')
    return manifest


class V4HttpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.agent = StubAgent()
        self.agent.tok = object()
        self.service = MifuService(data_dir=self.root / 'data', device='cpu', sampler=StubSampler())
        self.server = LocalServer(0, self.service)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temp.cleanup()

    def send(self, path, body=None, method='POST'):
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=5)
        try:
            conn.request(method, path, None if body is None else json.dumps(body),
                         {} if body is None else {'Content-Type': 'application/json'})
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def ready(self):
        self.service.checkpoint = self.root / 'checkpoint'
        v4_checkpoint(self.service.checkpoint)
        self.service.agent_loader = lambda *_: self.agent
        self.service.initialize()
        self.assertEqual('ready', self.service.state)

    def audit(self):
        return patch('audit_token_budget.inspect_question', return_value={'errors': [], 'sequence_tokens': 100})

    def test_unconfigured_check_never_claims_token_audit_or_ready_or_prediction(self):
        with patch('mifu_server.build_decision_input', side_effect=AssertionError('No tokenizer loaded')):
            status, result = self.send('/v1/decisions/check', fresh_request())
        self.assertEqual(200, status)
        self.assertEqual('passed', result['evidenceStatus'])
        self.assertEqual('pending', result['tokenAudit']['status'])
        self.assertFalse(result['canInfer'])
        self.assertFalse(result['automaticExecutionAuthorized'])
        self.assertNotIn('choice', result)
        self.assertEqual([], self.agent.calls)
        _, health = self.send('/health', method='GET')
        self.assertIn(SCHEMA, health['supportedInputContracts'])
        self.assertIsNone(health['model']['inputContract'])

    def test_missing_setup_and_stale_evidence_have_actionable_issues(self):
        body = fresh_request()
        body['candidates'][0]['features']['setup_seconds'] = None
        status, result = self.send('/v1/decisions/check', body)
        self.assertEqual(200, status)
        issue = result['issues'][0]
        self.assertEqual('objective_evidence_missing', issue['code'])
        self.assertIn('准备', issue['message'])
        self.assertEqual(['setup_s'], issue['details']['missing'])
        self.assertEqual('device-0', issue['details']['candidate_id'])
        body = fresh_request()
        body['decision_context']['observed_at_epoch_s'] -= 121
        _, result = self.send('/v1/decisions/check', body)
        self.assertEqual('stale_or_future_evidence', result['issues'][0]['code'])
        self.assertEqual('blocked', result['evidenceStatus'])

    def test_online_cannot_submit_simulations_or_downgrade_objective(self):
        for field, value, code in (('source', 'synthetic_pipeline_only', 'live_source_required'),
                                   ('objective', 'earliest_known_availability', 'objective_unvalidated')):
            body = fresh_request()
            body['decision_context'][field] = value
            for endpoint in ('/v1/decisions/check', '/v1/decisions'):
                status, result = self.send(endpoint, body)
                self.assertEqual(422, status)
                self.assertEqual(code, result['error']['code'])
        self.assertEqual([], self.agent.calls)

    def test_ready_routes_through_identical_shared_projection_and_fixed_budget(self):
        self.ready()
        body = fresh_request()
        with self.audit() as audit:
            status, checked = self.send('/v1/decisions/check', body)
            self.assertEqual(200, status)
            self.assertTrue(checked['canInfer'])
            self.assertEqual([], self.agent.calls)
            status, result = self.send('/v1/decisions', body)
        self.assertEqual(200, status, result)
        self.assertEqual('device-0', result['choice'])
        self.assertEqual(SCHEMA, result['inputContract'])
        self.assertEqual(SCHEMA, result['model']['inputContract'])
        expected = normalize_request(body, now_epoch_s=time.time())
        state, questions, kwargs = self.agent.calls[-1]
        self.assertEqual(expected['state'], state)
        self.assertEqual(expected['questions'], questions)
        self.assertEqual({'max_len': 2048, 'head_max_len': 1024}, kwargs)
        self.assertEqual((2048, 1024), audit.call_args.args[-2:])
        self.assertNotIn('timing_evidence', json.dumps(state))
        self.assertFalse(result['model']['autoExecutionEnabled'])

    def test_contract_mismatch_and_unvalidated_count_cannot_call_model(self):
        self.ready()
        status, result = self.send('/v1/decisions', legacy_request())
        self.assertEqual((422, 'input_contract_mismatch'), (status, result['error']['code']))
        status, result = self.send('/v1/decisions', fresh_request(4))
        self.assertEqual((422, 'candidate_count_unvalidated'), (status, result['error']['code']))
        status, result = self.send('/v1/decisions/check', fresh_request(4))
        self.assertFalse(result['canInfer'])
        self.assertEqual([], self.agent.calls)

    def test_token_truncation_fails_before_predict_and_invalid_body_never_500(self):
        self.ready()
        with patch('audit_token_budget.inspect_question', return_value={'errors': ['option_description_truncated']}):
            status, result = self.send('/v1/decisions', fresh_request())
            self.assertEqual((422, 'token_budget_failed'), (status, result['error']['code']))
            _, result = self.send('/v1/decisions/check', fresh_request())
            self.assertEqual('blocked', result['evidenceStatus'])
            self.assertFalse(result['canInfer'])
        body = fresh_request()
        body['candidates'] = None
        status, result = self.send('/v1/decisions/check', body)
        self.assertEqual(200, status)
        self.assertEqual('blocked', result['evidenceStatus'])
        self.assertEqual([], self.agent.calls)

    def test_live_timing_sources_and_artifact_binding_are_required(self):
        for mode in ('missing', 'wrong_hash', 'unknown_source'):
            body = fresh_request()
            timing = body['candidates'][0]['features']['timing_evidence']
            if mode == 'missing':
                del body['candidates'][0]['features']['timing_evidence']
            elif mode == 'wrong_hash':
                timing['run']['artifact_sha256'] = 'b' * 64
            else:
                timing['setup']['source'] = 'assumed_zero'
            status, result = self.send('/v1/decisions/check', body)
            self.assertEqual(200, status)
            self.assertEqual('blocked', result['evidenceStatus'])
            self.assertTrue(result['issues'][0]['code'].startswith('timing_evidence_'))

    def test_archive_preserves_v4_and_single_candidate_without_reviving_freshness(self):
        body = live_request(1)  # Deliberately old: archive, never fresh inference.
        body['plate']['taskId'] = 'archived-task'
        body['candidates'][0]['features']['timing_evidence']['setup']['observed_at_epoch_s'] = 1010
        envelope = {'request': body, 'feedback': 'observed', 'selectedCandidateId': 'device-0'}
        status, result = self.send('/v1/records', envelope)
        self.assertEqual(201, status, result)
        self.assertFalse(result['trainingEligible'])
        stored = json.loads((self.root / 'data/feedback.jsonl').read_text())
        self.assertEqual(body, stored['request'])
        _, retry = self.send('/v1/records', envelope)
        self.assertEqual(result['recordId'], retry['recordId'])
        self.assertTrue(retry['duplicate'])
        status, _ = self.send('/v1/decisions', body)
        self.assertEqual(422, status)
        envelope['decision'] = {'requestId': body['requestId'], 'choice': 'device-0', 'inputContract': SCHEMA}
        self.assertEqual(422, self.send('/v1/records', envelope)[0])

    def test_v4_record_cannot_attach_legacy_model_decision(self):
        body = fresh_request()
        envelope = {'request': body, 'feedback': 'accepted', 'selectedCandidateId': 'device-0',
                    'decision': {'requestId': body['requestId'], 'choice': 'device-0'}}
        status, result = self.send('/v1/records', envelope)
        self.assertEqual((422, 'input_contract_mismatch'), (status, result['error']['code']))

    def test_v4_qualification_requires_real_scope_and_exact_layout(self):
        path = self.root / 'checkpoint'
        v4_checkpoint(path)
        self.assertEqual(SCHEMA, load_manifest(path)['inputContract'])
        config_path = path / 'rl_agent_config.json'
        cfg = json.loads(config_path.read_text())
        for key, value in (('max_len', 1024), ('head_max_len', 256), ('option_layout', 'sequential')):
            changed = {**cfg, key: value}
            config_path.write_text(json.dumps(changed))
            with self.assertRaises(ValueError):
                load_manifest(path)
        config_path.write_text(json.dumps(cfg))
        report_path = path / 'acceptance_report.json'
        report = json.loads(report_path.read_text())
        for key, value in (('evaluationSource', 'synthetic_pipeline_only'),
                           ('supportedObjectives', ['earliest_known_availability'])):
            report_path.write_text(json.dumps({**report, key: value}))
            with self.assertRaises(ValueError):
                load_manifest(path)

    def test_v4_observations_and_rows_are_not_silently_exported_or_trained_as_legacy(self):
        record_path, label_path = self.root / 'feedback.jsonl', self.root / 'labels.jsonl'
        record_path.write_text(json.dumps({'recordId': 'one', 'request': fresh_request()}) + '\n')
        label_path.write_text(json.dumps({'recordId': 'one', 'selectedCandidateId': 'device-0',
                                          'reviewSource': 'expert_review', 'reviewer': 'person', 'rationale': 'test'}) + '\n')
        with self.assertRaisesRegex(ValueError, 'v4 observations'):
            export_dataset(record_path, label_path, self.root / 'dataset')
        self.assertFalse((self.root / 'dataset').exists())
        make_checkpoint(self.root / 'base')
        for split in ('train', 'eval'):
            (self.root / (split + '.jsonl')).write_text(json.dumps({'state': {'schema': SCHEMA}}) + '\n')
        with self.assertRaisesRegex(ValueError, 'mifu-decision-v4'):
            train_model(self.root / 'train.jsonl', self.root / 'eval.jsonl', self.root / 'base',
                        self.root / 'out', 'test-v4', dry_run=True)
        self.assertFalse((self.root / 'out').exists())


if __name__ == '__main__':
    unittest.main()
