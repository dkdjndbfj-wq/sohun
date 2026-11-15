from __future__ import annotations

import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mifu_server import (ApiError, HostSampler, LocalServer, MifuService, SDK_VERSION,
                         build_question, load_manifest, validate_prediction, validate_request)
from training import export_dataset, read_jsonl, train_model
from test_model_acceptance import accepted_report, accepted_runtime
from model_acceptance import checkpoint_artifact_hashes


def request(task="task-01", duration=120):
    return {
        "requestId": "request-01",
        "plate": {"id": "plate-01", "taskId": task, "name": "private order name", "estimatedMinutes": duration,
                  "materials": [{"tool_index": 0, "resource_id": "material-01", "grams_per_run": 75,
                                 "available_grams": 1000}]},
        "candidates": [
            {"id": "device-01", "features": {"queueMinutes": 10, "materials": [
                {"tool_index": 0, "resource_id": "material-01", "grams_per_run": 75, "available_grams": 1000}]}},
            {"id": "device-02", "features": {"queueMinutes": 60, "materials": [
                {"tool_index": 0, "resource_id": "material-01", "grams_per_run": 75, "available_grams": 2000}]}}
        ]
    }


def prediction():
    return {"answers": {"printer": {"type": "choice", "choice": "candidate_00",
                                     "probabilities": {"candidate_00": 0.7, "candidate_01": 0.3}}},
            "usage": {"truncated": False, "state_tokens_dropped": 0, "truncated_questions": []}}


class StubAgent:
    """Explicit execution-policy doubles; none are real GPU or precision evidence."""
    def __init__(self, output=None, fail=False, device="cpu", precision='float32'):
        self.output = output if output is not None else prediction()
        self.fail, self.device = fail, device
        self.calls = []
        self.dtype, self.amp_enabled = precision, precision != 'float32'
        self.backend, self._fast, self._compiled = 'eager', None, False
        self.cpu_fallback_count = self._amp_failures = 0
        self.parameter = SimpleNamespace(dtype='float32', device=device)
        self.model = SimpleNamespace(training=False,
            encoder=SimpleNamespace(config=SimpleNamespace(reference_compile=False, _attn_implementation='sdpa')),
            parameters=lambda: iter([self.parameter]))
        self.model.modules = lambda: iter([self.model])

    def _amp_enabled_for(self, rows):
        return self.amp_enabled

    def dtype_for(self, rows):
        return self.dtype if self._amp_enabled_for(rows) else 'float32'

    def predict(self, state, questions, **kwargs):
        self.calls.append((state, questions, kwargs))
        if self.fail:
            raise RuntimeError("sensitive/path/should/not/leak")
        return self.output


class StubSampler:
    def sample(self):
        return {"gpuName": "test-only RTX 4070", "utilizationPercent": 5.0,
                "memoryUsedMb": 100.0, "memoryTotalMb": 12000.0, "temperatureC": 35.0}


def make_checkpoint(path):
    path.mkdir()
    (path / "tokenizer").mkdir()
    (path / "encoder").mkdir()
    (path / 'encoder/config.json').write_text('{}', encoding='utf-8')
    (path / 'tokenizer/tokenizer.json').write_text('{}', encoding='utf-8')
    (path / 'tokenizer/tokenizer_config.json').write_text('{}', encoding='utf-8')
    (path / "model.safetensors").write_bytes(b"stub weights, not a real model")
    (path / "rl_agent_config.json").write_text(json.dumps({"encoder": "jhu-clsp/mmBERT-base",
                                                         "training": {"laya_train": {"epochs": 4}}}), encoding="utf-8")
    (path / "train_report.json").write_text(json.dumps({"is_held_out": True, "eval_items": 2}), encoding="utf-8")
    manifest = {"schemaVersion": 1, "modelName": "Mifu", "version": "test-only-v1", "base": "laya-multilingual",
                "trainingCompleted": True, "sdkVersion": SDK_VERSION, 'inputContract': 'legacy_v1',
                "weightsSha256": hashlib.sha256((path / "model.safetensors").read_bytes()).hexdigest()}
    (path / "mifu_manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    (path / 'acceptance_report.json').write_text(json.dumps(accepted_report(manifest['weightsSha256'], artifacts=checkpoint_artifact_hashes(path))), encoding='utf-8')
    return manifest


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.agent = StubAgent()
        self.service = MifuService(data_dir=self.root / "records", sampler=StubSampler())

    def tearDown(self):
        self.tmp.cleanup()

    def ready(self, agent=None):
        checkpoint = self.root / "checkpoint"
        make_checkpoint(checkpoint)
        self.service = MifuService(checkpoint, self.root / "records", device='cpu', agent_loader=lambda *_: agent or self.agent,
                                   sampler=StubSampler(), input_auditor=lambda *_: {'errors': []})
        self.service.initialize()
        self.assertEqual(self.service.state, "ready")

    def test_unconfigured_health_is_honest_and_does_not_load_sdk(self):
        with patch("mifu_server.load_agent", side_effect=AssertionError("must not load")):
            self.service.initialize()
        health = self.service.health()
        self.assertEqual(health["trainingState"], "unconfigured")
        self.assertIsNone(health["model"]["device"])
        self.assertIsNone(health["model"]["base"])
        self.assertIsNone(health["model"]["engine"])
        self.assertEqual(health["host"]["gpuName"], "test-only RTX 4070")
        with self.assertRaises(ApiError) as context:
            self.service.decide(request())
        self.assertEqual(context.exception.status, 503)

    def test_missing_or_untrained_checkpoint_is_error_not_a_base_fallback(self):
        self.service = MifuService(self.root / "missing", agent_loader=lambda *_: self.fail("must not load"))
        self.service.initialize()
        self.assertEqual(self.service.state, "error")
        self.assertNotIn(str(self.root), self.service.last_error)

    def test_unchanged_loader_publishes_only_the_accepted_agent(self):
        checkpoint = self.root / 'checkpoint'
        manifest = make_checkpoint(checkpoint)
        before = checkpoint_artifact_hashes(checkpoint)
        calls = []

        def loader(path, device):
            calls.append((path, device))
            self.assertEqual('loading', self.service.state)
            self.assertIsNone(self.service.agent)
            self.assertEqual({}, self.service.manifest)
            return self.agent

        self.service = MifuService(checkpoint, device='cpu', agent_loader=loader, sampler=StubSampler())
        self.service.last_error = 'earlier failed load'
        self.service.initialize()
        self.assertEqual([(checkpoint.resolve(), 'cpu')], calls)
        self.assertEqual(before, checkpoint_artifact_hashes(checkpoint))
        self.assertEqual('ready', self.service.state)
        self.assertIs(self.agent, self.service.agent)
        self.assertEqual(manifest['version'], self.service.manifest['version'])
        self.assertIsNone(self.service.last_error)
        self.assertEqual('laya-multilingual', self.service.model_metadata()['base'])
        self.assertEqual('compat_multilingual', self.service.model_metadata()['engine'])

    def test_loader_mutation_cannot_become_ready_or_retain_previous_agent(self):
        for index, relative in enumerate(('tokenizer/tokenizer_config.json', 'tokenizer/tokenizer.json',
                                          'tokenizer/added_tokens.json', 'encoder/config.json',
                                          'rl_agent_config.json', 'model.safetensors')):
            with self.subTest(relative=relative):
                checkpoint = self.root / f'mutation-{index}'
                make_checkpoint(checkpoint)
                self.service = MifuService(checkpoint, device='cpu', agent_loader=lambda *_: self.agent, sampler=StubSampler())
                self.service.initialize()
                self.assertEqual('ready', self.service.state)

                def mutating_loader(path, _device):
                    (path / relative).write_text('{"changed_by_loader":true}', encoding='utf-8')
                    return self.agent

                self.service.agent_loader = mutating_loader
                self.service.initialize()
                self.assertEqual('error', self.service.state)
                self.assertIsNone(self.service.agent)
                self.assertEqual({}, self.service.manifest)
                self.assertIsNone(self.service.health()['model']['device'])
                self.assertNotIn(str(self.root), self.service.last_error)
                with self.assertRaises(ApiError) as raised:
                    self.service.decide(request())
                self.assertEqual('model_unavailable', raised.exception.code)
        self.assertEqual([], self.agent.calls)

    def test_acceptance_validation_mutation_is_rejected_before_loader(self):
        checkpoint = self.root / 'checkpoint'
        make_checkpoint(checkpoint)
        loader_calls = []

        def changing_validation(path):
            manifest = load_manifest(path)
            (path / 'tokenizer/tokenizer_config.json').write_text('{"changed":true}', encoding='utf-8')
            return manifest

        def loader(*args):
            loader_calls.append(args)
            return self.agent

        self.service = MifuService(checkpoint, device='cpu', agent_loader=loader)
        with patch('mifu_server.load_manifest', side_effect=changing_validation):
            self.service.initialize()
        self.assertEqual('error', self.service.state)
        self.assertIsNone(self.service.agent)
        self.assertEqual({}, self.service.manifest)
        self.assertEqual([], loader_calls)

    def test_manifest_rejects_tampered_weights(self):
        checkpoint = self.root / "checkpoint"
        make_checkpoint(checkpoint)
        (checkpoint / "model.safetensors").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "integrity"):
            load_manifest(checkpoint)

    def test_manifest_rejects_no_held_out_evaluation(self):
        checkpoint = self.root / "checkpoint"
        make_checkpoint(checkpoint)
        (checkpoint / "train_report.json").write_text('{"is_held_out":false,"eval_items":2}', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Independent"):
            load_manifest(checkpoint)

    def test_completed_training_without_quality_acceptance_is_not_ready(self):
        checkpoint = self.root / 'checkpoint'
        make_checkpoint(checkpoint)
        report = accepted_report(hashlib.sha256((checkpoint / 'model.safetensors').read_bytes()).hexdigest(), artifacts=checkpoint_artifact_hashes(checkpoint))
        report['candidateBuckets']['2']['accuracy'] = 0.4629
        (checkpoint / 'acceptance_report.json').write_text(json.dumps(report), encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'accuracy'):
            load_manifest(checkpoint)

    def test_option_text_truncation_rejected_before_sdk_prediction(self):
        self.ready()
        self.service.input_auditor = lambda *_: {'errors': ['option_description_truncated']}
        with self.assertRaises(ApiError) as context:
            self.service.decide(request())
        self.assertEqual(context.exception.code, 'context_truncated')
        self.assertEqual(self.agent.calls, [])

    def test_single_candidate_can_be_observed_but_is_not_model_comparison(self):
        body = request()
        body['candidates'] = body['candidates'][:1]
        saved = self.service.record({'request': body, 'feedback': 'observed', 'selectedCandidateId': 'device-01'})
        self.assertFalse(saved['trainingEligible'])
        with self.assertRaises(ApiError):
            self.service.decide(body)
        with self.assertRaises(ApiError):
            self.service.record({'request': body, 'feedback': 'accepted', 'selectedCandidateId': 'device-01',
                                 'decision': {'requestId': body['requestId'], 'choice': 'device-01'}})

    def test_relabelled_v4_unknown_and_missing_contracts_are_not_loaded_as_legacy(self):
        for index, contract in enumerate(('mifu-decision-v4', 'unknown', None)):
            checkpoint = self.root / f'checkpoint-{index}'
            manifest = make_checkpoint(checkpoint)
            if contract is None:
                del manifest['inputContract']
            else:
                manifest['inputContract'] = contract
            (checkpoint / 'mifu_manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'input contract'):
                load_manifest(checkpoint)

    def test_tokenizer_configuration_changes_or_added_files_invalidate_acceptance(self):
        for index, relative in enumerate(('tokenizer/tokenizer.json', 'tokenizer/tokenizer_config.json',
                                          'tokenizer/added_tokens.json', 'encoder/config.json')):
            checkpoint = self.root / f'checkpoint-{index}'
            make_checkpoint(checkpoint)
            (checkpoint / relative).write_text('{"changed":true}', encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'integrity'):
                load_manifest(checkpoint)

    def test_truthy_eval_item_counts_are_not_valid_evaluation(self):
        for index, value in enumerate((True, '2', -1, 0.5)):
            checkpoint = self.root / f'checkpoint-{index}'
            make_checkpoint(checkpoint)
            (checkpoint / 'train_report.json').write_text(json.dumps({'is_held_out': True, 'eval_items': value}), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'Independent'):
                load_manifest(checkpoint)

    def test_unvalidated_candidate_count_is_not_inferred_ready(self):
        self.ready()
        body = request()
        body['candidates'].append({'id': 'device-03', 'features': {}})
        with self.assertRaises(ApiError) as context:
            self.service.decide(body)
        self.assertEqual(context.exception.code, 'candidate_count_unvalidated')

    def test_manifest_rejects_base_checkpoint_relabeling(self):
        checkpoint = self.root / "checkpoint"
        make_checkpoint(checkpoint)
        (checkpoint / "rl_agent_config.json").write_text('{"encoder":"jhu-clsp/mmBERT-base"}', encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "fine-tuned"):
            load_manifest(checkpoint)

    def test_real_sdk_call_shape_and_neutral_ids(self):
        self.ready()
        answer = self.service.decide(request())
        self.assertEqual(answer["choice"], "device-01")
        self.assertEqual(answer["probabilities"], {"device-01": 0.7, "device-02": 0.3})
        self.assertEqual(answer["model"]["device"], "cpu")
        self.assertFalse(answer["model"]["autoExecutionEnabled"])
        self.assertGreaterEqual(answer["elapsedMs"], 0)
        state, questions, kwargs = self.agent.calls[0]
        self.assertNotIn("id", state["plate"])
        self.assertNotIn("name", state["plate"])
        self.assertNotIn("taskId", state["plate"])
        self.assertEqual(set(questions["printer"]["criteria"]), {"candidate_00", "candidate_01"})
        self.assertEqual(kwargs, {"max_len": 1024, "head_max_len": 256})

    def test_inference_failure_never_returns_fallback(self):
        self.ready(StubAgent(fail=True))
        with self.assertRaises(ApiError) as context:
            self.service.decide(request())
        self.assertEqual(context.exception.code, "inference_failed")
        self.assertNotIn("sensitive", context.exception.message)

    def test_opaque_ids_are_removed_but_shared_resource_relationship_survives(self):
        body = request()
        body["plate"]["package_id"] = "private-package"
        materials = body["candidates"][0]["features"]["materials"]
        materials.extend([{**materials[0], "tool_index": 1}, {**materials[0], "tool_index": 2, "resource_id": "another-slot"}])
        state, questions, _ = build_question(body)
        self.assertNotIn("package_id", state["plate"])
        features = json.loads(questions["printer"]["criteria"]["candidate_00"])
        self.assertEqual([item["resource_slot"] for item in features["materials"]], ["slot_0", "slot_0", "slot_1"])
        self.assertTrue(all("resource_id" not in item for item in features["materials"]))
        second = json.loads(questions["printer"]["criteria"]["candidate_01"])
        self.assertEqual(second["materials"][0]["resource_slot"], "slot_0")
        self.assertIn("resource_id", body["candidates"][0]["features"]["materials"][0])

    def test_busy_is_bounded(self):
        self.ready()
        self.service.inference_lock.acquire()
        try:
            with self.assertRaises(ApiError) as context:
                self.service.decide(request())
            self.assertEqual(context.exception.status, 429)
        finally:
            self.service.inference_lock.release()

    def test_candidates_unique_and_count_bounded(self):
        for count in (0, 1, 17):
            body = request()
            body["candidates"] = [{"id": str(n), "features": {}} for n in range(count)]
            with self.subTest(count=count), self.assertRaises(ApiError):
                validate_request(body)
        body = request()
        body["candidates"][1]["id"] = body["candidates"][0]["id"]
        with self.assertRaises(ApiError):
            validate_request(body)

    def test_private_feature_keys_rejected(self):
        for key in ("accessCode", "access_code", "ipAddress", "serialNumber", "password", "token", "ip"):
            body = request()
            body["candidates"][0]["features"][key] = "private"
            with self.subTest(key=key), self.assertRaises(ApiError):
                validate_request(body)

    def test_real_material_arrays_are_valid_in_record_envelope(self):
        body = {"request": request(), "feedback": "accepted", "selectedCandidateId": "device-01", "decision": None,
                "outcome": {"actualMinutes": 121}}
        response = self.service.record(body)
        self.assertFalse(response["trainingEligible"])
        stored = read_jsonl(self.root / "records" / "feedback.jsonl")[0]
        self.assertEqual(stored["source"], "client_feedback_unverified")
        self.assertFalse(stored["trainingEligible"])

    def test_record_does_not_allow_paths_or_fake_candidate(self):
        for extra in ({"path": "elsewhere"}, {"selectedCandidateId": "unknown"}, {"feedback": []}):
            body = {"request": request(), "feedback": "observed", **extra}
            with self.subTest(extra=extra), self.assertRaises(ApiError):
                self.service.record(body)
        self.assertFalse((self.root / "records").exists())

    def test_deeper_data_rejected_even_inside_records(self):
        body = request()
        body["candidates"][0]["features"]["nested"] = {"a": {"b": {"c": {"d": 1}}}}
        with self.assertRaises(ApiError):
            self.service.record({"request": body, "feedback": "observed"})


class PredictionTests(unittest.TestCase):
    def test_truncation_is_not_silently_accepted(self):
        _, _, mapping = build_question(request())
        for field, value in (("truncated", True), ("state_tokens_dropped", 1), ("truncated_questions", ["printer"])):
            result = prediction()
            result["usage"][field] = value
            with self.subTest(field=field), self.assertRaises(ApiError):
                validate_prediction(result, mapping)

    def test_invalid_model_output_rejected(self):
        _, _, mapping = build_question(request())
        for probabilities in ({"candidate_00": float("nan"), "candidate_01": 0.3},
                              {"candidate_00": True, "candidate_01": 0.0},
                              {"candidate_00": 0.71, "candidate_01": 0.3},
                              {"candidate_00": 0.2, "candidate_01": 0.8},
                              {"candidate_00": 1.0}):
            result = prediction()
            result["answers"]["printer"]["probabilities"] = probabilities
            with self.subTest(probabilities=probabilities), self.assertRaises(ApiError):
                validate_prediction(result, mapping)

    def test_invalid_model_metadata_rejected(self):
        _, _, mapping = build_question(request())
        for result in ({"usage": [1], "answers": {}}, {"usage": {}, "answers": [1]}, None):
            with self.subTest(result=result), self.assertRaises(ApiError):
                validate_prediction(result, mapping)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.service = MifuService(data_dir=Path(self.tmp.name), sampler=StubSampler())
        self.server = LocalServer(0, self.service)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def send(self, method="GET", path="/health", body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        request_headers = dict(headers or {})
        payload = None if body is None else json.dumps(body)
        if payload is not None:
            request_headers.setdefault("Content-Type", "application/json")
        try:
            connection.request(method, path, payload, request_headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read()), dict(response.getheaders())
        finally:
            connection.close()

    def test_actual_loopback_unconfigured_health_and_503(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        status, body, headers = self.send()
        self.assertEqual(status, 200)
        self.assertEqual(body["trainingState"], "unconfigured")
        self.assertNotIn("Access-Control-Allow-Origin", headers)
        self.assertEqual(headers["Cache-Control"], "no-store")
        status, body, _ = self.send("POST", "/v1/decisions", request())
        self.assertEqual(status, 503)
        self.assertEqual(body["requestId"], "request-01")
        self.assertNotIn("choice", body)

    def test_actual_loopback_stub_inference_and_record(self):
        self.service.state = "ready"
        self.service.agent = StubAgent()
        self.service.manifest = {"version": "stub-only", 'supportedCandidateCounts': [2], 'inputContract': 'legacy_v1',
                                 'runtimeProfile': accepted_runtime()}
        self.service.input_auditor = lambda *_: {'errors': []}
        status, decision, _ = self.send("POST", "/v1/decisions", request())
        self.assertEqual(status, 200)
        self.assertEqual(decision["choice"], "device-01")
        status, body, _ = self.send("POST", "/v1/records", {"request": request(), "decision": decision,
                                                           "feedback": "accepted", "selectedCandidateId": "device-01"})
        self.assertEqual(status, 201)
        self.assertFalse(body["trainingEligible"])

    def test_browser_and_rebinding_hosts_rejected(self):
        for headers in ({"Host": "attacker.example"}, {"Host": "localhost"}, {"Origin": "null"},
                        {"Origin": "http://127.0.0.1"}, {"Sec-Fetch-Site": "same-origin"}):
            with self.subTest(headers=headers):
                self.assertEqual(self.send(headers=headers)[0], 403)
        self.assertEqual(self.send("OPTIONS")[0], 403)

    def test_optional_bearer_token(self):
        self.server.api_token = "secret-for-stub-tests-only"
        self.assertEqual(self.send()[0], 401)
        self.assertEqual(self.send(headers={"Authorization": "Bearer wrong"})[0], 401)
        self.assertEqual(self.send(headers={"Authorization": "Bearer secret-for-stub-tests-only"})[0], 200)

    def test_duplicate_host_and_duplicate_json_rejected(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.putrequest("GET", "/health")
            connection.putheader("Host", f"127.0.0.1:{self.server.server_port}")
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 403)
            response.read()
        finally:
            connection.close()
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request("POST", "/v1/decisions", '{"requestId":"a","requestId":"b"}', {"Content-Type": "application/json"})
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            response.read()
        finally:
            connection.close()

    def test_invalid_request_paths_media_and_nan(self):
        self.assertEqual(self.send(path="/health?token=anything")[0], 404)
        self.assertEqual(self.send("POST", "/v1/train", {})[0], 404)
        self.assertEqual(self.send("POST", "/v1/decisions", request(), {"Content-Type": "text/plain"})[0], 415)
        body = request()
        body["plate"]["weight"] = float("nan")
        self.assertEqual(self.send("POST", "/v1/decisions", body)[0], 422)
        body = request()
        body["plate"]["huge"] = "a" * 70000
        self.assertEqual(self.send("POST", "/v1/decisions", body)[0], 413)


class SamplerTests(unittest.TestCase):
    @patch("mifu_server.shutil.which", return_value="nvidia-smi")
    @patch("mifu_server.subprocess.run")
    def test_real_probe_shape_and_cache_without_claiming_gpu_inference(self, run, _which):
        run.return_value.stdout = "NVIDIA GeForce RTX 4070, 12, 1234, 12282, 47\n"
        sampler = HostSampler()
        first = sampler.sample()
        self.assertEqual(first["memoryUsedMb"], 1234.0)
        self.assertEqual(first["temperatureC"], 47.0)
        self.assertEqual(sampler.sample(), first)
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.kwargs["timeout"], 1.5)
        self.assertFalse(run.call_args.kwargs.get("shell", False))

    @patch("mifu_server.shutil.which", return_value="nvidia-smi")
    @patch("mifu_server.subprocess.run", side_effect=subprocess.TimeoutExpired("nvidia-smi", 1.5))
    def test_timeout_yields_null_values(self, _run, _which):
        self.assertTrue(all(value is None for value in HostSampler().sample().values()))


class TrainingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def data(self):
        records, labels = [], []
        for task, plate, duration in (("task-a", "a1", 10), ("task-a", "a2", 20), ("task-b", "b1", 30), ("task-c", "c1", 40)):
            body = request(task, duration)
            body["plate"]["id"] = plate
            records.append({"recordId": plate, "request": body, "feedback": "accepted", "trainingEligible": False})
            labels.append({"recordId": plate, "selectedCandidateId": "device-01", "reviewSource": "expert_review",
                           "reviewer": "operator", "rationale": "reviewed measured queue result"})
        for name, rows in (("feedback", records), ("labels", labels)):
            (self.root / f"{name}.jsonl").write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
        return records, labels

    def test_export_keeps_all_plates_of_one_task_in_one_split(self):
        self.data()
        report = export_dataset(self.root / "feedback.jsonl", self.root / "labels.jsonl", self.root / "dataset")
        self.assertEqual(report["trainRows"] + report["evalRows"], 4)
        train_groups = {item["taskHash"] for item in report["sources"]["train"]}
        eval_groups = {item["taskHash"] for item in report["sources"]["eval"]}
        self.assertFalse(train_groups & eval_groups)
        for name in ("train", "eval"):
            for row in read_jsonl(self.root / "dataset" / f"{name}.jsonl"):
                self.assertNotIn("taskId", row["state"]["plate"])
                self.assertEqual(row["expected"]["printer"], "candidate_00")

    def test_single_candidate_outcomes_are_excluded_from_ranking_export(self):
        records, labels = self.data()
        single = json.loads(json.dumps(records[0]))
        single['recordId'] = 'single-record'
        single['request']['candidates'] = single['request']['candidates'][:1]
        label = dict(labels[0], recordId='single-record')
        (self.root / 'feedback.jsonl').write_text('\n'.join(json.dumps(r) for r in [*records, single]), encoding='utf-8')
        (self.root / 'labels.jsonl').write_text('\n'.join(json.dumps(r) for r in [*labels, label]), encoding='utf-8')
        result = export_dataset(self.root / 'feedback.jsonl', self.root / 'labels.jsonl', self.root / 'dataset')
        self.assertEqual(result['excludedSingleCandidateRecords'], ['single-record'])
        self.assertEqual(result['trainRows'] + result['evalRows'], 4)

    def test_accept_feedback_cannot_be_used_as_review_label(self):
        _, labels = self.data()
        labels[0]["reviewSource"] = "accepted"
        (self.root / "labels.jsonl").write_text("\n".join(json.dumps(row) for row in labels), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "expert_review"):
            export_dataset(self.root / "feedback.jsonl", self.root / "labels.jsonl", self.root / "dataset")
        self.assertFalse((self.root / "dataset").exists())

    def test_missing_task_id_prevents_plate_leakage(self):
        records, _ = self.data()
        del records[0]["request"]["plate"]["taskId"]
        (self.root / "feedback.jsonl").write_text("\n".join(json.dumps(row) for row in records), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "taskId"):
            export_dataset(self.root / "feedback.jsonl", self.root / "labels.jsonl", self.root / "dataset")

    def test_existing_export_not_overwritten(self):
        self.data()
        output = self.root / "dataset"
        output.mkdir()
        with self.assertRaises(FileExistsError):
            export_dataset(self.root / "feedback.jsonl", self.root / "labels.jsonl", output)

    def test_training_plan_requires_no_sdk_or_gpu_and_uses_real_encoder_key(self):
        self.data()
        output = self.root / "dataset"
        export_dataset(self.root / "feedback.jsonl", self.root / "labels.jsonl", output)
        base = self.root / "base"
        make_checkpoint(base)
        with patch("training.importlib.metadata.version", side_effect=AssertionError("must not import SDK")):
            plan = train_model(output / "train.jsonl", output / "eval.jsonl", base,
                               self.root / "trained", "test-v1", dry_run=True)
        self.assertEqual(plan["microBatch"], 1)
        self.assertEqual(plan["gradientAccumulation"], 8)
        self.assertTrue(plan["freezeEncoder"])
        self.assertFalse((self.root / "trained").exists())

    def test_identical_training_eval_inputs_are_rejected(self):
        self.data()
        output = self.root / "dataset"
        export_dataset(self.root / "feedback.jsonl", self.root / "labels.jsonl", output)
        base = self.root / "base"
        make_checkpoint(base)
        with self.assertRaisesRegex(ValueError, "overlap"):
            train_model(output / "train.jsonl", output / "train.jsonl", base,
                        self.root / "trained", "test-v1", dry_run=True)


if __name__ == "__main__":
    unittest.main()
