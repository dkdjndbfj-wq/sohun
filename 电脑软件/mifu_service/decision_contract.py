"""Shared prospective Mifu ranking input contract; does not dispatch or train.

This module is shared by offline experiments and the versioned HTTP service. Live callers
must supply explicit admission evidence and timestamps. The simulator adapter
declares simulated eligibility, never real hardware verification. Token audit is
mandatory in build_decision_input; normalization alone is not model readiness.
"""
from __future__ import annotations

import copy
import json
import math
import re

SCHEMA = 'mifu-decision-v4'
MAX_LEN = 2048
HEAD_MAX_LEN = 1024
MAX_CANDIDATES = 16
MAX_TIME_SECONDS = 31 * 86400
MAX_SNAPSHOT_AGE_SECONDS = 120
OBJECTIVES = ('earliest_known_finish', 'earliest_known_availability')
SOURCES = ('live_snapshot', 'synthetic_pipeline_only')
FORBIDDEN = {'expected', 'gold', 'oracle', 'oracle_rank', 'rank', 'winner',
             'selected_candidate_id', 'outcome', 'reward', 'costs_in_physical_order'}


class ContractError(ValueError):
    def __init__(self, code: str, message: str, diagnostics: dict | None = None):
        super().__init__(message)
        self.code = code
        self.diagnostics = diagnostics or {}


def _require(condition, code, message):
    if not condition:
        raise ContractError(code, message)


def _text(value, field, limit=128):
    _require(isinstance(value, str) and bool(value.strip()) and len(value) <= limit
             and not any(ord(c) < 32 for c in value), 'invalid_text', field)
    return value


def _number(value, field):
    _require(not isinstance(value, bool) and isinstance(value, (int, float))
             and abs(value) <= 1e15 and (not isinstance(value, float) or math.isfinite(value)), 'invalid_number', field)
    return value


def _integer(value, field, *, minimum=0, maximum=MAX_TIME_SECONDS, nullable=True):
    if value is None and nullable:
        return None
    value = _number(value, field)
    _require(int(value) == value and minimum <= value <= maximum,
             'invalid_integer', field + ' must preserve whole seconds/counts exactly')
    return int(value)


def _reject_labels(value):
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = re.sub(r'(?<!^)(?=[A-Z])', '_', str(key)).lower()
            _require(normalized not in FORBIDDEN, 'label_in_request', 'Outcome/target fields are not model evidence')
            _reject_labels(item)
    elif isinstance(value, list):
        for item in value:
            _reject_labels(item)


def _age(observed, now, maximum, field):
    observed = _number(observed, field)
    age = now - observed
    _require(0 <= age <= maximum, 'stale_or_future_evidence', field)
    return age


def normalize_request(request: dict, *, now_epoch_s: float, minimum_candidates: int = 2) -> dict:
    """Validate and project evidence without importing an SDK or loading weights.

    The returned tokenAudit.status is pending: callers must use
    build_decision_input before inference/training. Original seconds and known
    evidence remain in diagnostics. No expected label, ordering rank, hardware
    speed assumption or missing-value zero is invented.
    """
    _require(isinstance(request, dict) and set(request) == {'requestId', 'plate', 'candidates', 'decision_context'},
             'invalid_envelope', 'Expected the versioned decision envelope')
    _reject_labels(request)
    try:
        size = len(json.dumps(request, ensure_ascii=False, allow_nan=False).encode('utf-8'))
    except (TypeError, ValueError) as exc:
        raise ContractError('invalid_json_evidence', 'Evidence must be finite JSON') from exc
    _require(size <= 65536, 'evidence_too_large', 'Evidence exceeds the local request budget')
    request_id = _text(request['requestId'], 'requestId')
    now = _number(now_epoch_s, 'now_epoch_s')
    context, plate, candidates = request['decision_context'], request['plate'], request['candidates']
    _require(isinstance(context, dict), 'invalid_context', 'decision_context must be an object')
    _require(context.get('schema') == SCHEMA, 'unsupported_schema', 'A matching explicit schema is required')
    source, objective = context.get('source'), context.get('objective')
    _require(source in SOURCES, 'unknown_source', 'Explicit live or synthetic source is required')
    _require(objective in OBJECTIVES, 'unknown_objective', 'Unsupported ranking objective')
    snapshot = _text(context.get('snapshot_id'), 'snapshot_id')
    gate_version = _text(context.get('gate_version'), 'gate_version')
    ttl = _integer(context.get('max_age_seconds'), 'max_age_seconds', minimum=1,
                   maximum=MAX_SNAPSHOT_AGE_SECONDS, nullable=False)
    snapshot_age = _age(context.get('observed_at_epoch_s'), now, ttl, 'snapshot timestamp')
    _require(isinstance(plate, dict), 'invalid_plate', 'plate must be an object')
    _text(plate.get('id'), 'plate.id')
    duration = _integer(plate.get('estimated_seconds'), 'plate.estimated_seconds', minimum=1)
    remaining = _integer(plate.get('remaining_runs'), 'plate.remaining_runs', minimum=1, maximum=1_000_000, nullable=False)
    _require(minimum_candidates in (1, 2), 'candidate_count', 'Invalid validation mode')
    _require(isinstance(candidates, list) and minimum_candidates <= len(candidates) <= MAX_CANDIDATES,
             'candidate_count', 'Ranking requires two through sixteen; collection also accepts one candidate')

    state = {'schema': SCHEMA, 'objective': objective,
             'plate': {'remaining_runs': remaining, 'run_s': duration}, 'candidates': {}}
    mapping, criteria, audit_candidates = {}, {}, []
    seen_ids = set()
    for index, candidate in enumerate(candidates):
        _require(isinstance(candidate, dict) and set(candidate) == {'id', 'features', 'admission'},
                 'invalid_candidate', 'Each candidate needs explicit admission evidence')
        identifier = _text(candidate['id'], 'candidate.id')
        _require(identifier not in seen_ids, 'duplicate_candidate', 'Candidate IDs must be unique')
        seen_ids.add(identifier)
        gate, features = candidate['admission'], candidate['features']
        _require(isinstance(gate, dict) and isinstance(features, dict), 'invalid_candidate', 'Invalid candidate evidence')
        required_gate_status = 'passed' if source == 'live_snapshot' else 'synthetic_declared_eligible'
        _require(gate.get('status') == required_gate_status and gate.get('version') == gate_version
                 and gate.get('snapshot_id') == snapshot, 'admission_not_verified',
                 'Unknown, blocked, mixed-snapshot or implicit admission cannot enter choice')
        age = _age(gate.get('observed_at_epoch_s'), now, ttl, 'candidate admission timestamp')
        allowed = {'max_runs', 'queued_runs', 'available_after_seconds', 'setup_seconds',
                   'run_seconds', 'hardware', 'materials', 'timing_evidence'}
        _require(set(features) <= allowed, 'unknown_feature', 'Unexpected feature requires an explicit schema change')
        wait = _integer(features.get('available_after_seconds'), 'available_after_seconds')
        setup = _integer(features.get('setup_seconds'), 'setup_seconds')
        run = _integer(features['run_seconds'] if 'run_seconds' in features else duration, 'run_seconds', minimum=1)
        max_runs = _integer(features.get('max_runs'), 'max_runs', minimum=1, maximum=1_000_000, nullable=False)
        queued = _integer(features.get('queued_runs'), 'queued_runs', maximum=1_000_000)
        finish = wait + setup + run if all(v is not None for v in (wait, setup, run)) else None
        missing = [key for key, value in (('wait_s', wait), ('setup_s', setup), ('run_s', run)) if value is None]
        if wait is None or (objective == 'earliest_known_finish' and missing):
            raise ContractError('objective_evidence_missing', 'Unknown timing cannot support the requested objective',
                                {'candidate_id': identifier, 'missing': missing, 'wait_s': wait,
                                 'setup_s': setup, 'run_s': run, 'finish_s': finish})
        timing_evidence = features.get('timing_evidence')
        if source == 'live_snapshot':
            _require(isinstance(timing_evidence, dict) and set(timing_evidence) == {'setup', 'wait', 'run'},
                     'timing_evidence_missing', 'Live timing needs explicit setup/wait/run sources')
            for key, required_source in (('setup', 'manual_estimate'), ('wait', 'queue_and_device_lower_bound')):
                entry = timing_evidence[key]
                _require(isinstance(entry, dict) and set(entry) == {'source', 'observed_at_epoch_s'}
                         and entry['source'] == required_source, 'timing_evidence_invalid', 'Unsupported live timing source')
                _age(entry['observed_at_epoch_s'], now, ttl, key + ' timing observation')
            run_evidence = timing_evidence['run']
            artifact = plate.get('artifact_sha256')
            _require(isinstance(run_evidence, dict) and set(run_evidence) == {'source', 'artifact_sha256'}
                     and run_evidence['source'] == 'selected_slice_estimate'
                     and isinstance(artifact, str) and re.fullmatch('[0-9a-fA-F]{64}', artifact)
                     and run_evidence['artifact_sha256'] == artifact,
                     'timing_evidence_invalid', 'Run estimate must bind the selected slice hash')
        label = f'candidate_{index:02d}'
        mapping[label] = identifier
        show = lambda value: '?' if value is None else str(value)
        criteria[label] = f'wait {show(wait)}s; prep {show(setup)}s; finish {show(finish)}s'
        # Hardware legality is a precondition, not a label the model is allowed
        # to invent. Hardware affects observed durations/preparation; its full
        # audit evidence is retained outside the encoder instead of repeated.
        state['candidates'][label] = {'max_runs': max_runs, 'queued_runs': queued}
        audit_candidates.append({'label': label, 'candidate_id': identifier, 'evidence_age_s': age,
                                 'wait_s': wait, 'setup_s': setup, 'run_s': run, 'finish_s': finish,
                                 'hardware': copy.deepcopy(features.get('hardware')),
                                 'materials': copy.deepcopy(features.get('materials')),
                                 'timing_evidence': copy.deepcopy(timing_evidence),
                                 'admission': copy.deepcopy(gate)})
    instructions = ('Choose the eligible candidate with earliest known finish; ties prefer shorter preparation.'
                    if objective == 'earliest_known_finish' else
                    'Choose the eligible candidate with smallest known wait. Do not infer unknown preparation.')
    return {'state': state, 'questions': {'printer': {'type': 'choice', 'instructions': instructions, 'criteria': criteria}},
            'mapping': mapping, 'budget': {'max_len': MAX_LEN, 'head_max_len': HEAD_MAX_LEN},
            'diagnostics': {'request_id': request_id, 'source': source, 'snapshot_id': snapshot,
                            'snapshot_age_s': snapshot_age, 'gate_version': gate_version,
                            'raw_plate': copy.deepcopy(plate), 'candidates': audit_candidates,
                            'derived_fields': {'finish_s': 'known wait_s + known setup_s + known run_s; otherwise null'},
                            'time_precision': 'exact integer seconds; no rounding to minutes',
                            'live_time_meaning': 'queue/device lower bound + manual setup estimate + selected-slice estimate; not a promised finish',
                            'hardware_role': 'upstream admission and observed timing; not a learned permission',
                            'advisory_only': True, 'dispatch_authorized': False,
                            'token_audit': {'status': 'pending'}, 'model_quality_evaluated': False}}


def build_decision_input(request: dict, *, tokenizer, now_epoch_s: float) -> dict:
    """The shared training/inference boundary: reject every real SDK truncation."""
    prepared = normalize_request(request, now_epoch_s=now_epoch_s)
    from audit_token_budget import inspect_question
    check = inspect_question(tokenizer, prepared['state'], prepared['questions']['printer'], MAX_LEN, HEAD_MAX_LEN)
    if check['errors']:
        raise ContractError('token_budget_failed', 'Model evidence would be truncated or collide', check)
    prepared['diagnostics']['token_audit'] = {'status': 'passed', **check}
    return prepared


def label_for_candidate(prepared: dict, selected_candidate_id: str) -> str:
    """Map an independently supplied training label; never add it to model input."""
    matches = [key for key, value in prepared['mapping'].items() if value == selected_candidate_id]
    _require(len(matches) == 1, 'unknown_label_candidate', 'Reviewed selection is not in this request')
    return matches[0]


def from_simulation_row(row: dict) -> dict:
    """Adapt v3 evidence only. Ignore expected, questions, costs and audit targets.

    Call build_decision_input with now_epoch_s=0 for these synthetic snapshots.
    This adapter cannot turn synthetic examples into verified live evidence.
    """
    meta, state = row.get('mifu_provenance', {}), row.get('state', {})
    _require(meta.get('source') == 'synthetic_pipeline_only'
             and state.get('featureSchemaVersion') == 'mifu-hardware-sim-v3',
             'unsupported_simulation_source', 'Only explicitly marked v3 simulation evidence is accepted')
    plate = state['plate']
    snapshot = 'synthetic-' + str(meta.get('episode', 'unknown')) + '-' + str(meta.get('step', 'unknown'))
    gate_version = 'hardware-sim-v3-declared-eligibility'
    request = {'requestId': snapshot,
               'decision_context': {'schema': SCHEMA, 'source': 'synthetic_pipeline_only',
                                    'objective': 'earliest_known_finish', 'snapshot_id': snapshot,
                                    'gate_version': gate_version, 'observed_at_epoch_s': 0, 'max_age_seconds': 120},
               'plate': {'id': snapshot, 'estimated_seconds': plate['estimated_seconds'],
                         'remaining_runs': plate['remaining_runs'], 'target_model': plate['target_model'],
                         'nozzle_mm': plate['nozzle_mm'], 'material': plate['material'], 'tools': copy.deepcopy(plate['tools'])},
               'candidates': []}
    for identifier, candidate in state['candidates'].items():
        request['candidates'].append({'id': identifier,
            'admission': {'status': 'synthetic_declared_eligible', 'version': gate_version,
                          'snapshot_id': snapshot, 'observed_at_epoch_s': 0},
            'features': {'available_after_seconds': candidate['wait_s'], 'setup_seconds': candidate['setup_s'],
                         'run_seconds': candidate['run_s'], 'max_runs': candidate['max_runs'], 'queued_runs': None,
                         'hardware': {key: copy.deepcopy(candidate.get(key))
                                      for key in ('model', 'nozzle_mm', 'nozzle_material', 'feed')},
                         'materials': copy.deepcopy(candidate['materials'])}})
    return request
