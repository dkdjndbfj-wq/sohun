"""Loopback-only Mifu inference and feedback collection, without hidden downloads.

The HTTP/validation layer uses only the Python standard library. Laya is imported
only when an explicitly configured, locally trained Mifu checkpoint is loaded.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import hmac
import importlib.metadata
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from collections import deque

from model_acceptance import checkpoint_artifact_hashes, validate_acceptance
from runtime_profile import device_type, require_matching_runtime
from validate_observation import ObservationError, validate_observation
from decision_contract import (SCHEMA as V4_CONTRACT, MAX_LEN as V4_MAX_LEN, HEAD_MAX_LEN as V4_HEAD_MAX_LEN,
                               ContractError, build_decision_input, normalize_request)

SDK_VERSION = "0.4.31"
DEFAULT_PORT = 27961
MAX_BODY = 65536
MAX_RECORD_BODY = 256 * 1024
MAX_CANDIDATES = 16
SUPPORTED_INPUT_CONTRACTS = ('legacy_v1', V4_CONTRACT)
V4_OBJECTIVES = ('earliest_known_finish',)
INSTRUCTIONS = "选择最适合此盘的一个合格候选设备，以缩短完成时间并减少换料。候选已由业务约束检查；仅比较提供的事实。"
SENSITIVE_KEYS = re.compile(r"password|token|secret|access.?code|ip.?address|serial|email", re.I)


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, details: dict | None = None):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message
        self.details = details


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def unique_json_object(pairs: list[tuple[str, Any]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


def text_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 128:
        raise ApiError(422, "invalid_request", f"{label} 必须是1至128字符的非空字符串")
    if any(ord(char) < 32 for char in value):
        raise ApiError(422, "invalid_request", f"{label} 不允许控制字符")
    return value


def validate_json(value: Any, depth: int = 0, list_limit: int = 64) -> None:
    if depth > 6:
        raise ApiError(422, "invalid_request", "特征嵌套过深")
    if isinstance(value, dict):
        if len(value) > 64:
            raise ApiError(422, "invalid_request", "单个对象字段过多")
        for key, item in value.items():
            if not isinstance(key, str) or len(key) > 128 or SENSITIVE_KEYS.search(key) or key.lower() in {"ip", "address", "host"}:
                raise ApiError(422, "sensitive_feature", "特征不允许包含凭据、网络地址或设备序列号字段")
            validate_json(item, depth + 1, list_limit)
    elif isinstance(value, list):
        if len(value) > list_limit:
            raise ApiError(422, "invalid_request", "特征数组过长")
        for item in value:
            validate_json(item, depth + 1, list_limit)
    elif isinstance(value, str):
        if len(value) > 4096:
            raise ApiError(422, "invalid_request", "特征文本过长")
    elif isinstance(value, float):
        if not math.isfinite(value):
            raise ApiError(422, "invalid_request", "数字必须有限")
    elif type(value) is int and abs(value) > 2**63 - 1:
        raise ApiError(422, 'invalid_request', '整数超过支持范围')
    elif value is not None and not isinstance(value, (bool, int)):
        raise ApiError(422, "invalid_request", "不支持的特征类型")


def request_contract(body: Any) -> str:
    if isinstance(body, dict) and 'decision_context' in body:
        context = body['decision_context']
        if not isinstance(context, dict) or context.get('schema') != V4_CONTRACT:
            raise ApiError(422, 'unsupported_input_contract', '请求使用了不支持的模型输入版本')
        return V4_CONTRACT
    return 'legacy_v1'


def live_v4_envelope(body: Any) -> None:
    if request_contract(body) != V4_CONTRACT:
        raise ApiError(422, 'unsupported_input_contract', '预检需要新版 Mifu 输入')
    context = body['decision_context']
    if context.get('source') != 'live_snapshot':
        raise ApiError(422, 'live_source_required', '在线接口只接收当前软件的设备快照，不接收模拟训练数据')
    if context.get('objective') not in V4_OBJECTIVES:
        raise ApiError(422, 'objective_unvalidated', '当前输入只支持预计最早完成；缺少准备时间时请补齐，不能改目标绕过')
    validate_json(body)


def contract_api_error(exc: ContractError) -> ApiError:
    messages = {
        'objective_evidence_missing': '请补齐候选设备的等待、准备和本盘打印时间；未知时长不能按零计算',
        'stale_or_future_evidence': '设备快照已过期或时间异常，请刷新设备状态后重新比较',
        'admission_not_verified': '候选设备尚未通过本次快照的兼容检查，请重新检查设备与耗材',
        'candidate_count': '比较需要2至16台候选设备',
        'token_budget_failed': '设备信息超过模型输入限制，本次不生成建议',
        'label_in_request': '输入中包含结果或目标标签，不能作为决策依据',
        'timing_evidence_missing': '请记录准备时间、等待时间和切片时长的来源，才能进行预计完成时间比较',
        'timing_evidence_invalid': '时长来源或切片绑定不一致，请重新确认准备时间和本盘切片',
    }
    return ApiError(422, exc.code, messages.get(exc.code, '新版模型输入不完整或格式无效，请重新检查本盘和设备'),
                    exc.diagnostics or None)


def validate_request(body: Any, minimum_candidates: int = 2, *, archive_observation: bool = False) -> dict:
    if request_contract(body) == V4_CONTRACT:
        live_v4_envelope(body)
        now = time.time()
        if archive_observation:
            times = [body['decision_context'].get('observed_at_epoch_s')]
            candidates = body.get('candidates')
            if isinstance(candidates, list):
                for candidate in candidates:
                    if not isinstance(candidate, dict):
                        continue
                    gate, features = candidate.get('admission'), candidate.get('features')
                    if isinstance(gate, dict):
                        times.append(gate.get('observed_at_epoch_s'))
                    timing = features.get('timing_evidence') if isinstance(features, dict) else None
                    if isinstance(timing, dict):
                        for name in ('setup', 'wait'):
                            entry = timing.get(name)
                            if isinstance(entry, dict):
                                times.append(entry.get('observed_at_epoch_s'))
            if any(type(value) not in (int, float) or not math.isfinite(value) or value > now for value in times):
                raise ApiError(422, 'stale_or_future_evidence', '采集快照时间无效或晚于当前时间')
            # Archival observation preserves the old snapshot; it grants no new
            # inference freshness and remains trainingEligible=false.
            now = max(times)
        try:
            normalize_request(body, now_epoch_s=now, minimum_candidates=minimum_candidates)
        except ContractError as exc:
            raise contract_api_error(exc) from exc
        return body
    if not isinstance(body, dict) or set(body) != {"requestId", "plate", "candidates"}:
        raise ApiError(422, "invalid_request", "需要 requestId、plate、candidates")
    text_id(body["requestId"], "requestId")
    plate = body["plate"]
    if not isinstance(plate, dict):
        raise ApiError(422, "invalid_request", "plate 必须是对象")
    text_id(plate.get("id"), "plate.id")
    candidates = body["candidates"]
    if not isinstance(candidates, list) or not minimum_candidates <= len(candidates) <= MAX_CANDIDATES:
        raise ApiError(422, "invalid_request", f"候选设备数量必须为{minimum_candidates}至16")
    ids = []
    for candidate in candidates:
        if not isinstance(candidate, dict) or set(candidate) != {"id", "features"}:
            raise ApiError(422, "invalid_request", "候选需要 id 和 features")
        ids.append(text_id(candidate["id"], "candidate.id"))
        if not isinstance(candidate["features"], dict):
            raise ApiError(422, "invalid_request", "features 必须是对象")
    if len(set(ids)) != len(ids):
        raise ApiError(422, "invalid_request", "候选ID不能重复")
    validate_json(body)
    return body


def build_question(request: dict) -> tuple[dict, dict, dict]:
    """Use neutral option tokens; never use device names as classifier labels."""
    def anonymous_features(value: Any, resource_slots: dict) -> Any:
        if isinstance(value, list):
            return [anonymous_features(item, resource_slots) for item in value]
        if not isinstance(value, dict):
            return value
        sanitized = {}
        for key, item in value.items():
            normalized = re.sub(r"(?<!^)(?=[A-Z])", "_", key).lower()
            if normalized == "resource_id":
                # Multiple tools can consume one physical spool/slot. Preserve
                # equality within this candidate, but never learn physical IDs.
                if isinstance(item, (str, int)) and not isinstance(item, bool):
                    identity = str(item)
                    resource_slots.setdefault(identity, f"slot_{len(resource_slots)}")
                    sanitized["resource_slot"] = resource_slots[identity]
                continue
            if normalized == "id" or normalized.endswith("_id") or normalized == "name" or normalized.endswith("_name"):
                continue
            sanitized[key] = anonymous_features(item, resource_slots)
        return sanitized

    mapping = {f"candidate_{index:02d}": c["id"] for index, c in enumerate(request["candidates"])}
    criteria = {key: json.dumps(anonymous_features(c["features"], {}), ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                for key, c in zip(mapping, request["candidates"])}
    # Drop identifiers and job names from the model context and exported datasets.
    plate = anonymous_features(request["plate"], {})
    state = {"plate": plate, "objective": "minimize_completion_and_changeover"}
    questions = {"printer": {"type": "choice", "instructions": INSTRUCTIONS, "criteria": criteria}}
    return state, questions, mapping


def validate_prediction(result: Any, mapping: dict) -> tuple[str, dict]:
    if not isinstance(result, dict):
        raise ApiError(502, "invalid_prediction", "模型返回了无效结果")
    usage = result.get("usage") or {}
    if not isinstance(usage, dict) or not isinstance(result.get("answers"), dict):
        raise ApiError(502, "invalid_prediction", "模型返回了无效元数据")
    if usage.get("truncated") or usage.get("state_tokens_dropped", 0) or usage.get("truncated_questions"):
        raise ApiError(502, "context_truncated", "模型输入发生截断，本次建议不予采用")
    answer = (result.get("answers") or {}).get("printer")
    if not isinstance(answer, dict) or answer.get("type") != "choice":
        raise ApiError(502, "invalid_prediction", "模型未返回设备选择")
    choice, probabilities = answer.get("choice"), answer.get("probabilities")
    if not isinstance(choice, str) or choice not in mapping or not isinstance(probabilities, dict) or set(probabilities) != set(mapping):
        raise ApiError(502, "invalid_prediction", "模型候选与本次请求不一致")
    if any(isinstance(p, bool) or not isinstance(p, (int, float)) or not math.isfinite(p) or not 0 <= p <= 1
           for p in probabilities.values()):
        raise ApiError(502, "invalid_prediction", "模型概率无效")
    if abs(sum(probabilities.values()) - 1.0) > 0.001:
        raise ApiError(502, "invalid_prediction", "模型概率和无效")
    if probabilities[choice] < max(probabilities.values()) - 0.0001:
        raise ApiError(502, "invalid_prediction", "选择与候选概率不一致")
    return mapping[choice], {mapping[key]: value for key, value in probabilities.items()}


def load_manifest(checkpoint: Path) -> dict:
    manifest = json.loads((checkpoint / "mifu_manifest.json").read_text(encoding="utf-8"))
    required = ("rl_agent_config.json", "model.safetensors", "tokenizer", "encoder", "train_report.json")
    if any(not (checkpoint / name).exists() for name in required):
        raise ValueError("Incomplete local checkpoint")
    if (type(manifest.get("schemaVersion")) is not int or manifest.get("schemaVersion") != 1 or manifest.get("modelName") != "Mifu"
            or manifest.get("trainingCompleted") is not True or manifest.get("base") != "laya-multilingual"
            or manifest.get("sdkVersion") != SDK_VERSION
            or not isinstance(manifest.get("version"), str) or not manifest["version"].strip()):
        raise ValueError("Not a trained Mifu checkpoint")
    if manifest.get('inputContract') not in SUPPORTED_INPUT_CONTRACTS:
        raise ValueError('Unsupported or missing input contract for this service')
    report = json.loads((checkpoint / "train_report.json").read_text(encoding="utf-8"))
    if report.get("is_held_out") is not True or type(report.get("eval_items")) is not int or report['eval_items'] < 1:
        raise ValueError("Independent evaluation is required")
    config = json.loads((checkpoint / "rl_agent_config.json").read_text(encoding="utf-8"))
    if "mmbert" not in str(config.get("encoder", "")).lower() or not (config.get("training") or {}).get("laya_train"):
        raise ValueError("Checkpoint is not a locally fine-tuned multilingual model")
    if manifest['inputContract'] == V4_CONTRACT:
        if (type(config.get('max_len')) is not int or config['max_len'] != V4_MAX_LEN or
                type(config.get('head_max_len')) is not int or config['head_max_len'] != V4_HEAD_MAX_LEN or
                config.get('option_layout') != 'parallel' or manifest.get('supportedObjectives') != list(V4_OBJECTIVES)):
            raise ValueError('The v4 checkpoint budget, option layout and objective must match the shared input contract')
    expected_hash = manifest.get("weightsSha256", "")
    if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        raise ValueError("Missing checkpoint integrity hash")
    digest = hashlib.sha256()
    with (checkpoint / "model.safetensors").open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if not hmac.compare_digest(digest.hexdigest(), expected_hash):
        raise ValueError("Checkpoint integrity check failed")
    acceptance = json.loads((checkpoint / 'acceptance_report.json').read_text(encoding='utf-8'))
    validate_acceptance(acceptance, weights_sha256=expected_hash,
                        input_contract=manifest['inputContract'],
                        artifact_sha256=checkpoint_artifact_hashes(checkpoint))
    if manifest['inputContract'] == V4_CONTRACT and acceptance.get('supportedObjectives') != manifest['supportedObjectives']:
        raise ValueError('Objective acceptance belongs to a different objective')
    manifest = dict(manifest, supportedCandidateCounts=[int(k) for k in acceptance['candidateBuckets']],
                    runtimeProfile=dict(acceptance['runtimeProfile']))
    return manifest


def load_agent(checkpoint: Path, device: str):
    # SDK must never resolve an absent local checkpoint to a Hub download.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    if importlib.metadata.version("laya") != SDK_VERSION:
        raise RuntimeError("Unsupported Laya SDK version")
    import laya
    return laya.load(str(checkpoint), device=device, vegaml=False,
                     fast=False, compile=False, backend='eager')


def audit_model_input(agent, state, questions):
    from audit_token_budget import inspect_question
    return inspect_question(agent.tok, state, questions['printer'], 1024, 256)


class HostSampler:
    """Bounded cached probe. Physical GPU presence is not model CUDA execution."""
    def __init__(self):
        self.lock = threading.Lock()
        self.sampled_at = -math.inf
        self.value = dict.fromkeys(("gpuName", "utilizationPercent", "memoryUsedMb", "memoryTotalMb", "temperatureC"))

    def sample(self) -> dict:
        with self.lock:
            if time.monotonic() - self.sampled_at < 3:
                return dict(self.value)
            self.sampled_at = time.monotonic()
            value = dict.fromkeys(self.value)
            executable = shutil.which("nvidia-smi")
            if executable:
                try:
                    result = subprocess.run([executable, "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
                                             "--format=csv,noheader,nounits", "--id=0"],
                                            capture_output=True, text=True, timeout=1.5, check=True,
                                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                    fields = next(csv.reader(result.stdout.splitlines()))
                    if len(fields) == 5:
                        value["gpuName"] = fields[0].strip()
                        for key, raw in zip(list(value)[1:], fields[1:]):
                            try:
                                number = float(raw.strip())
                                value[key] = number if math.isfinite(number) and number >= 0 else None
                            except ValueError:
                                pass
                except (OSError, subprocess.SubprocessError, StopIteration):
                    pass
            self.value = value
            return dict(value)


class MifuService:
    def __init__(self, checkpoint: Path | None = None, data_dir: Path | None = None,
                 device: str = "cuda", agent_loader=load_agent, sampler=None,
                 input_auditor=audit_model_input):
        self.checkpoint = checkpoint.resolve() if checkpoint else None
        self.data_dir = data_dir or Path(__file__).resolve().parent / "data"
        self.device_preference = device
        self.agent_loader = agent_loader
        self.input_auditor = input_auditor
        self.sampler = sampler or HostSampler()
        self.state = "unconfigured" if checkpoint is None else "loading"
        self.last_error = None
        self.manifest: dict = {}
        self.agent = None
        self.runtime_profile = None
        self.inference_lock = threading.Lock()
        self.record_lock = threading.Lock()

    def initialize(self) -> None:
        if self.checkpoint is None:
            return
        with self.inference_lock:
            self.state, self.last_error = "loading", None
            self.agent, self.manifest = None, {}
            self.runtime_profile = None
            try:
                locked_artifacts = checkpoint_artifact_hashes(self.checkpoint)
                manifest = load_manifest(self.checkpoint)
                if device_type(self.device_preference) != manifest['runtimeProfile']['deviceType']:
                    raise ValueError('Requested device differs from the evaluated runtime')
                if checkpoint_artifact_hashes(self.checkpoint) != locked_artifacts:
                    raise ValueError('Checkpoint inputs changed during acceptance validation')
                # SDK loading can rewrite tokenizer configuration. Such a load
                # no longer represents the accepted inference inputs, even if
                # the SDK successfully returned an otherwise usable agent.
                agent = self.agent_loader(self.checkpoint, self.device_preference)
                if checkpoint_artifact_hashes(self.checkpoint) != locked_artifacts:
                    raise ValueError('Checkpoint inputs changed during model loading')
                # Revalidate the weights and acceptance evidence too. Publish no
                # agent or ready status until the loaded checkpoint is stable.
                if load_manifest(self.checkpoint) != manifest:
                    raise ValueError('Checkpoint manifest changed during model loading')
                actual_runtime = require_matching_runtime(agent, manifest['runtimeProfile'])
                self.manifest, self.agent = manifest, agent
                self.runtime_profile = actual_runtime
                self.state = "ready"
            except Exception:
                self.agent, self.manifest = None, {}
                self.runtime_profile = None
                # Do not expose local paths, tokens or dependency traces through HTTP.
                self.last_error = "Mifu 模型加载失败，请检查本地训练产物和固定版本依赖"
                self.state = "error"

    def _assert_runtime(self):
        """Called under inference_lock; a mismatch retires the accepted agent."""
        if self.state != 'ready' or self.agent is None:
            raise ApiError(503, 'model_unavailable', 'Mifu 模型当前不可用，请重新验收并加载')
        try:
            self.runtime_profile = require_matching_runtime(self.agent, self.manifest.get('runtimeProfile'))
        except Exception as exc:
            self.state = 'error'
            self.last_error = 'Mifu 运行设备或精度偏离验收环境，本次建议已停用，请重新验收并加载'
            self.agent, self.manifest, self.runtime_profile = None, {}, None
            raise ApiError(503, 'runtime_not_accepted', self.last_error) from exc

    def model_metadata(self) -> dict:
        actual_device = getattr(self.agent, "device", None)
        # Product identity is not evidence of a loaded architecture. Keep the
        # compatibility backend's true provenance only when a manifest exists;
        # never advertise the separate native core as online through this path.
        return {"name": "Mifu", "version": self.manifest.get("version"), "base": self.manifest.get("base"),
                "engine": "compat_multilingual" if self.manifest else None,
                "checkpointConfigured": self.checkpoint is not None,
                "device": str(actual_device) if actual_device is not None else None,
                "inputContract": self.manifest.get('inputContract'),
                "supportedObjectives": self.manifest.get('supportedObjectives', []),
                "supportedCandidateCounts": self.manifest.get('supportedCandidateCounts', []),
                "runtimeProfile": self.runtime_profile,
                "evaluation": "held_out" if self.state == "ready" else None,
                "autoExecutionEnabled": False}

    def health(self) -> dict:
        return {"service": "mifu", "apiVersion": 1, "status": "ok", "trainingState": self.state,
                "supportedInputContracts": list(SUPPORTED_INPUT_CONTRACTS),
                "model": self.model_metadata(), "lastError": self.last_error, "host": self.sampler.sample()}

    def check_decision(self, body: Any) -> dict:
        """Validate evidence without weights; audit tokens only with accepted v4.

        A successful structural check is not a ranking, a hardware attestation,
        model qualification, reservation, or permission to execute a print.
        """
        live_v4_envelope(body)
        request_id = text_id(body.get('requestId'), 'requestId')
        issues, evidence_status = [], 'passed'
        token_audit = {'status': 'pending', 'reason': 'accepted_v4_tokenizer_unavailable'}
        try:
            normalize_request(body, now_epoch_s=time.time())
        except ContractError as exc:
            error = contract_api_error(exc)
            issues.append({'code': error.code, 'message': error.message, 'details': error.details or {}})
            evidence_status = 'blocked'
        ready = self.state == 'ready' and self.agent is not None and self.manifest.get('inputContract') == V4_CONTRACT
        if not ready:
            issues.append({'code': 'model_unavailable', 'message': '新版模型尚未通过验收并加载；当前仅检查输入', 'details': {}})
        elif evidence_status != 'passed':
            pass
        elif len(body.get('candidates', [])) not in self.manifest.get('supportedCandidateCounts', []):
            issues.append({'code': 'candidate_count_unvalidated', 'message': '当前模型尚未通过此候选数量的独立验收', 'details': {}})
        elif body['decision_context']['objective'] not in self.manifest.get('supportedObjectives', []):
            issues.append({'code': 'objective_unvalidated', 'message': '当前模型尚未通过此比较目标的验收', 'details': {}})
        elif evidence_status == 'passed':
            if not self.inference_lock.acquire(blocking=False):
                issues.append({'code': 'model_busy', 'message': '模型正在处理上一项请求，输入审核稍后重试', 'details': {}})
            else:
                try:
                    self._assert_runtime()
                    prepared = build_decision_input(body, tokenizer=self.agent.tok, now_epoch_s=time.time())
                    token_audit = prepared['diagnostics']['token_audit']
                    self._assert_runtime()
                except ApiError as exc:
                    ready = False
                    issues.append({'code': exc.code, 'message': exc.message, 'details': {}})
                except ContractError as exc:
                    error = contract_api_error(exc)
                    issues.append({'code': error.code, 'message': error.message, 'details': error.details or {}})
                    evidence_status = 'blocked'
                except Exception:
                    issues.append({'code': 'input_audit_unavailable', 'message': '无法确认模型完整读取本次输入', 'details': {}})
                finally:
                    self.inference_lock.release()
        return {'requestId': request_id, 'inputContract': V4_CONTRACT, 'evidenceStatus': evidence_status,
                'tokenAudit': token_audit, 'modelReady': ready,
                'canInfer': ready and evidence_status == 'passed' and token_audit['status'] == 'passed' and not issues,
                'issues': issues, 'advisoryOnly': True, 'automaticExecutionAuthorized': False}

    def decide(self, body: Any) -> dict:
        request = validate_request(body)
        if self.state != "ready" or self.agent is None:
            raise ApiError(503, "model_unavailable", "Mifu 尚未完成训练或尚未加载，不能生成模型建议")
        if len(request['candidates']) not in self.manifest.get('supportedCandidateCounts', []):
            raise ApiError(422, 'candidate_count_unvalidated', '当前模型尚未通过此候选数量的独立验收')
        if not self.inference_lock.acquire(blocking=False):
            raise ApiError(429, "model_busy", "Mifu 正在处理上一项推理，请稍后重试")
        try:
            self._assert_runtime()
            contract = request_contract(request)
            if self.manifest.get('inputContract') != contract:
                raise ApiError(422, 'input_contract_mismatch', '软件输入版本与已加载模型不一致，请使用匹配版本')
            if contract == V4_CONTRACT:
                if request['decision_context']['objective'] not in self.manifest.get('supportedObjectives', []):
                    raise ApiError(422, 'objective_unvalidated', '当前模型尚未通过此比较目标的验收')
                try:
                    prepared = build_decision_input(request, tokenizer=self.agent.tok, now_epoch_s=time.time())
                except ContractError as exc:
                    raise contract_api_error(exc) from exc
                except Exception as exc:
                    raise ApiError(503, 'input_audit_unavailable', '无法确认模型完整读取了新版输入') from exc
                state, questions, mapping = prepared['state'], prepared['questions'], prepared['mapping']
                max_len, head_max_len = V4_MAX_LEN, V4_HEAD_MAX_LEN
            else:
                state, questions, mapping = build_question(request)
                try:
                    input_check = self.input_auditor(self.agent, state, questions)
                except Exception as exc:
                    raise ApiError(503, 'input_audit_unavailable', '无法确认模型完整读取了本次输入') from exc
                if not isinstance(input_check, dict) or input_check.get('errors') != []:
                    raise ApiError(422, 'context_truncated', '设备信息超过模型输入限制，本次不生成建议')
                max_len, head_max_len = 1024, 256
            self._assert_runtime()
            started = time.perf_counter()
            try:
                result = self.agent.predict(state, questions, max_len=max_len, head_max_len=head_max_len)
            except Exception as exc:
                # A failed GPU call can still have changed runtime or retried on
                # CPU. Never preserve ready solely because predict raised.
                self._assert_runtime()
                raise ApiError(503, "inference_failed", "Mifu 推理失败，本次未生成建议") from exc
            self._assert_runtime()
            elapsed = round((time.perf_counter() - started) * 1000, 3)
            choice, probabilities = validate_prediction(result, mapping)
            return {"requestId": request["requestId"], "trainingState": "ready", "choice": choice,
                    "probabilities": probabilities, "elapsedMs": elapsed, "model": self.model_metadata(),
                    "inputContract": contract}
        finally:
            self.inference_lock.release()

    def record(self, body: Any) -> dict:
        allowed = {"request", "decision", "feedback", "selectedCandidateId", "outcome", "observation"}
        if not isinstance(body, dict) or set(body) - allowed or not {"request", "feedback"} <= set(body):
            raise ApiError(422, "invalid_record", "记录格式无效")
        request = validate_request(body["request"], minimum_candidates=1, archive_observation=True)
        feedback = body["feedback"]
        if not isinstance(feedback, str) or feedback not in {"accepted", "corrected", "observed"}:
            raise ApiError(422, "invalid_record", "未知反馈类型")
        selected = body.get("selectedCandidateId")
        candidates = {c["id"] for c in request["candidates"]}
        if selected is not None and (not isinstance(selected, str) or selected not in candidates):
            raise ApiError(422, "invalid_record", "反馈选择不在候选中")
        if feedback in {"accepted", "corrected"} and selected is None:
            raise ApiError(422, "invalid_record", "接受或纠正反馈必须指定候选")
        decision = body.get("decision")
        if len(request['candidates']) == 1 and decision is not None:
            raise ApiError(422, 'invalid_record', '单候选只记录实际选择，不能标为模型比较结果')
        if decision is not None and (not isinstance(decision, dict)
                                     or decision.get("requestId") != request["requestId"]
                                     or not isinstance(decision.get("choice"), str)
                                     or decision.get("choice") not in candidates):
            raise ApiError(422, "invalid_record", "建议与反馈请求不一致")
        if decision is not None and request_contract(request) == V4_CONTRACT and decision.get('inputContract') != V4_CONTRACT:
            raise ApiError(422, 'input_contract_mismatch', '模型建议与采集快照不是同一输入版本')
        outcome = body.get("outcome", {})
        if not isinstance(outcome, dict):
            raise ApiError(422, "invalid_record", "outcome 必须是对象")
        observation = body.get('observation')
        if observation is not None:
            try:
                validate_observation(observation, request)
            except ObservationError as exc:
                raise ApiError(422, exc.code, str(exc)) from exc
        # The record envelope adds one level around an already validated request.
        # Keep the request's six-level limit without rejecting material arrays.
        validate_json({key: value for key, value in body.items() if key != 'observation'}, depth=-1)
        if observation is not None:
            validate_json(observation, list_limit=1024)
        from outcome_collection import OutcomeError, append_feedback
        try:
            with self.record_lock:
                return append_feedback(self.data_dir / 'feedback.jsonl', body)
        except OutcomeError as exc:
            status = 503 if exc.code in {'ledger_busy', 'corrupt_log'} else 422
            raise ApiError(status, exc.code, '选择记录暂未确认，请保留当前内容重试') from exc

    def query_records(self, body: Any) -> dict:
        """Only return the current visible plate/device scope, with bounded output."""
        if not isinstance(body, dict) or set(body) != {'plateId', 'candidateIds'}:
            raise ApiError(422, 'invalid_query', '需要打印盘和当前可见设备范围')
        plate = text_id(body['plateId'], 'plateId')
        ids = body['candidateIds']
        if not isinstance(ids, list) or not 1 <= len(ids) <= 64:
            raise ApiError(422, 'invalid_query', '可见设备数量超出查询范围')
        allowed_ids = {text_id(value, 'candidateId') for value in ids}
        if len(allowed_ids) != len(ids):
            raise ApiError(422, 'invalid_query', '设备范围不能重复')
        records = deque(maxlen=20)
        with self.record_lock:
            path = self.data_dir / 'feedback.jsonl'
            if path.exists():
                with path.open(encoding='utf-8') as handle:
                    for line in handle:
                        value = json.loads(line)
                        request = value.get('request', {})
                        source_plate = request.get('plate', {})
                        candidate = value.get('selectedCandidateId')
                        if source_plate.get('id') != plate or candidate not in allowed_ids:
                            continue
                        records.append({'recordId': value['recordId'], 'plateId': plate,
                                        'candidateId': candidate, 'createdAt': value['createdAt'],
                                        'plateIndex': source_plate.get('plate_index')})
        from outcome_collection import read_active_attempts
        attempts = read_active_attempts(self.data_dir / 'outcomes.jsonl', {r['recordId'] for r in records})
        return {'records': list(reversed(records)), 'attempts': attempts[:100],
                'limit': 20, 'attemptLimit': 100, 'attemptsTruncated': len(attempts) > 100,
                'trainingEligible': False}

    def record_outcome(self, body: Any) -> dict:
        # No state == ready condition: collection works before a model is trained.
        validate_json(body)
        from outcome_collection import OutcomeError, append_outcome
        try:
            return append_outcome(self.data_dir / 'feedback.jsonl', self.data_dir / 'outcomes.jsonl', body)
        except OutcomeError as exc:
            status = (409 if 'conflict' in exc.code or exc.code == 'feedback_changed' else
                      404 if exc.code in {'missing_feedback', 'feedback_not_found'} else
                      503 if exc.code in {'ledger_busy', 'corrupt_log'} else 422)
            raise ApiError(status, exc.code, '结果记录不一致，请检查原始选择、时间、结果状态及更正原因') from exc


class LocalServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 8

    def __init__(self, port: int, service: MifuService, api_token: str | None = None):
        self.service, self.api_token = service, api_token
        self.slots = threading.BoundedSemaphore(8)
        super().__init__(("127.0.0.1", port), RequestHandler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "Mifu/1"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, _format, *args):
        pass  # Never log request contents or bearer tokens.

    def reply(self, status: int, payload: dict):
        encoded = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(encoded)

    def guard(self):
        expected = f"127.0.0.1:{self.server.server_port}"
        if self.client_address[0] != "127.0.0.1" or self.headers.get_all("Host") != [expected]:
            raise ApiError(403, "local_only", "仅允许本机127.0.0.1访问")
        if self.headers.get("Origin") is not None or any(key.lower().startswith("sec-fetch-") for key in self.headers):
            raise ApiError(403, "browser_forbidden", "此接口仅供本机桌面客户端调用")
        token = self.server.api_token
        if token and not hmac.compare_digest(self.headers.get("Authorization", "").encode("utf-8"), ("Bearer " + token).encode("utf-8")):
            raise ApiError(401, "unauthorized", "需要本地访问令牌")

    def dispatch(self, is_post: bool):
        request_id = None
        try:
            self.guard()
            if not is_post:
                if self.path != "/health":
                    raise ApiError(404, "not_found", "接口不存在")
                return self.reply(200, self.server.service.health())
            if self.path not in {"/v1/decisions", "/v1/decisions/check", "/v1/records", "/v1/records/query", "/v1/outcomes"}:
                raise ApiError(404, "not_found", "接口不存在")
            if self.headers.get("Transfer-Encoding") or len(self.headers.get_all("Content-Length", [])) != 1:
                raise ApiError(400, "invalid_length", "需要唯一的Content-Length")
            if self.headers.get("Content-Type", "").split(";", 1)[0].lower().strip() != "application/json":
                raise ApiError(415, "json_required", "仅接受application/json")
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                raise ApiError(400, "invalid_length", "Content-Length无效") from None
            body_limit = MAX_RECORD_BODY if self.path == '/v1/records' else MAX_BODY
            if not 0 < length <= body_limit:
                raise ApiError(413, "body_too_large", f"请求必须为1至{body_limit}字节")
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ApiError(400, "incomplete_body", "请求未完整传输")
            try:
                body = json.loads(raw, object_pairs_hook=unique_json_object)
            except (ValueError, UnicodeError, RecursionError):
                raise ApiError(400, "invalid_json", "JSON无效") from None
            if isinstance(body, dict) and isinstance(body.get("requestId"), str):
                request_id = body["requestId"][:128]
            if self.path == "/v1/decisions":
                return self.reply(200, self.server.service.decide(body))
            if self.path == '/v1/decisions/check':
                return self.reply(200, self.server.service.check_decision(body))
            if self.path == '/v1/records/query':
                return self.reply(200, self.server.service.query_records(body))
            if self.path == '/v1/outcomes':
                return self.reply(201, self.server.service.record_outcome(body))
            return self.reply(201, self.server.service.record(body))
        except ApiError as exc:
            payload = {"error": {"code": exc.code, "message": exc.message}, "trainingState": self.server.service.state}
            if exc.details is not None:
                payload['error']['details'] = exc.details
            if request_id is not None:
                payload["requestId"] = request_id
            self.reply(exc.status, payload)
        except (TimeoutError, ConnectionError):
            self.close_connection = True
        except Exception:
            self.reply(500, {"error": {"code": "internal_error", "message": "本地服务处理失败"},
                             "trainingState": self.server.service.state})

    def do_GET(self):
        self.dispatch(False)

    def do_POST(self):
        self.dispatch(True)

    def do_OPTIONS(self):
        self.reply(403, {"error": {"code": "browser_forbidden", "message": "不提供跨域访问"}})


def main():
    parser = argparse.ArgumentParser(description="Mifu 本机模型服务；不会下载权重")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--checkpoint", type=Path, default=Path(os.environ["MIFU_CHECKPOINT"]) if os.environ.get("MIFU_CHECKPOINT") else None)
    parser.add_argument("--device", choices=("cuda", "cpu", "auto"), default="cuda")
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("端口必须在1024至65535之间")
    token = os.environ.get("MIFU_API_TOKEN") or None
    if token is not None and (len(token) < 24 or not token.isascii()):
        parser.error("MIFU_API_TOKEN必须至少24个ASCII字符")
    service = MifuService(args.checkpoint, device=args.device)
    server = LocalServer(args.port, service, token)
    threading.Thread(target=service.initialize, daemon=True).start()
    print(f"Mifu: http://127.0.0.1:{args.port}; checkpoint={'configured' if args.checkpoint else 'unconfigured'}; auth={'bearer' if token else 'local-native-only'}", flush=True)
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
