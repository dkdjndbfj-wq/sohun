"""Append-only actual-outcome collection, independent of model readiness.

Public API::

    append_outcome(feedback_path, outcomes_path, event) -> response
    read_attempt_history(outcomes_path, attempt_id) -> list[stored_event]
    read_active_attempts(outcomes_path, record_ids) -> list[attempt_summary]

Paths are server-selected local JSONL files, never fields accepted from clients.
An event binds a feedback record's exact plate and candidate snapshot. A retry
uses a new attemptId; a repeated HTTP delivery reuses the SAME eventId. An
identical event is idempotent; reusing its ID with different data is a conflict.
Corrections append a new event with supersedesEventId and correctionReason;
only the latest active event of the same type can be corrected. No row is edited.

Required common fields: schemaVersion=1, eventId, attemptId, recordId, plateId,
candidateId, eventType (execution|quality), occurredAt (timezone-aware ISO 8601),
source, payload. source has kind (device_telemetry|manual_entry|imported_log),
sourceId, and optional actorId/referenceId. Manual entries require actorId.

Execution payload requires all keys (unknown measurements are explicitly null):
  status: queued|running|paused|completed|failed|cancelled|unknown
  startedAt, endedAt, actualDurationSeconds, materialUsedGrams,
  completionPercent, failureCategory, failureEvidence
Quality payload requires all keys:
  status: not_inspected|pass|rework|reject|unknown|null
  inspectedAt, inspectorId, qualityScore, defectCodes (list), notes

Quality events require a prior execution event and manual_entry source. Machine
completion NEVER implies a quality pass. An explicit not_inspected, unknown,
null, missing quality event, cancellation and failure remain distinct. Failure
attribution is optional reported evidence, never automatically assigned to the
printer. This ledger is unreviewed observational evidence, not reward/ranking
labels: trainingEligible is always false, even after a manual quality pass.
Snapshot timing is tracked separately. A snapshot recorded after actual start
must never be presented as pre-decision evidence; missing timestamps remain
unknown, and even timestamps preceding start do not independently approve data.
No model, network, printer command, dataset export or training operation occurs.
"""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import threading
import time
import uuid
from typing import Any

# A feedback envelope may include a 256 KiB multi-AMS observation snapshot.
# Individual outcome events retain their separate 32 KiB limit below.
MAX_LINE_BYTES = 384 * 1024
MAX_EVENT_BYTES = 32768
EXECUTION_STATUSES = {'queued', 'running', 'paused', 'completed', 'failed', 'cancelled', 'unknown'}
TERMINAL_STATUSES = {'completed', 'failed', 'cancelled'}
QUALITY_STATUSES = {'not_inspected', 'pass', 'rework', 'reject', 'unknown', None}
INSPECTED_STATUSES = {'pass', 'rework', 'reject'}
FAILURE_CATEGORIES = {'unknown', 'material', 'operator', 'slicer', 'environment', 'device', 'multiple'}
DEFECT_CODES = {'warping', 'stringing', 'layer_shift', 'under_extrusion', 'dimensions',
                'surface', 'missing_part', 'support', 'adhesion', 'other'}
_locks: dict[str, threading.RLock] = {}
_locks_guard = threading.Lock()


class OutcomeError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def canonical(value: Any) -> bytes:
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'),
                          allow_nan=False).encode('utf-8')
    except (TypeError, ValueError, OverflowError, RecursionError) as exc:
        raise OutcomeError('invalid_event', 'Only finite JSON values are accepted') from exc


def digest(value: Any) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()


def identifier(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 128 or any(ord(c) < 32 for c in value):
        raise OutcomeError('invalid_event', field + ' must be a nonempty identifier of at most 128 characters')
    return value


def nullable_text(value: Any, field: str, limit: int = 2000) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > limit or any(ord(c) < 32 and c not in '\n\t' for c in value):
        raise OutcomeError('invalid_event', field + ' must be null or bounded nonempty text')
    return value


def number_or_null(value: Any, field: str, maximum: float) -> int | float | None:
    if value is None:
        return None
    if type(value) not in (int, float) or value < 0 or value > maximum or not math.isfinite(value):
        raise OutcomeError('invalid_event', field + ' must be null or a finite number in range')
    return value


def timestamp(value: Any, field: str, nullable: bool = False) -> tuple[str | None, datetime | None]:
    if value is None and nullable:
        return None, None
    if not isinstance(value, str) or len(value) > 40 or 'T' not in value:
        raise OutcomeError('invalid_event', field + ' must be a timezone-aware ISO 8601 timestamp')
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None or parsed.utcoffset() is None:
            raise ValueError('Missing timezone')
        parsed = parsed.astimezone(timezone.utc)
    except (ValueError, OverflowError) as exc:
        raise OutcomeError('invalid_event', field + ' has an invalid timestamp') from exc
    return parsed.isoformat().replace('+00:00', 'Z'), parsed


def _now(value: datetime | None) -> datetime:
    value = value or datetime.now(timezone.utc)
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ValueError('now must be a timezone-aware datetime')
    return value.astimezone(timezone.utc)


def normalize_event(event: Any, *, now: datetime | None = None) -> dict:
    required = {'schemaVersion', 'eventId', 'attemptId', 'recordId', 'plateId', 'candidateId',
                'eventType', 'occurredAt', 'source', 'payload'}
    optional = {'supersedesEventId', 'correctionReason'}
    if not isinstance(event, dict) or not required <= set(event) or set(event) - required - optional:
        raise OutcomeError('invalid_event', 'Event fields are missing or unsupported')
    if type(event['schemaVersion']) is not int or event['schemaVersion'] != 1:
        raise OutcomeError('invalid_event', 'Unsupported outcome schema')
    if len(canonical(event)) > MAX_EVENT_BYTES:
        raise OutcomeError('invalid_event', 'Outcome event exceeds size limit')
    normalized = {'schemaVersion': 1}
    for field in ('eventId', 'attemptId', 'recordId', 'plateId', 'candidateId'):
        normalized[field] = identifier(event[field], field)
    if event['eventType'] not in ('execution', 'quality'):
        raise OutcomeError('invalid_event', 'Unknown event type')
    normalized['eventType'] = event['eventType']
    occurred_text, occurred = timestamp(event['occurredAt'], 'occurredAt')
    if occurred > _now(now) + timedelta(minutes=5):
        raise OutcomeError('invalid_event', 'occurredAt is more than five minutes in the future')
    normalized['occurredAt'] = occurred_text
    source = event['source']
    if not isinstance(source, dict) or not {'kind', 'sourceId'} <= set(source) or set(source) - {'kind', 'sourceId', 'actorId', 'referenceId'}:
        raise OutcomeError('invalid_event', 'Explicit data source is required')
    if source['kind'] not in ('device_telemetry', 'manual_entry', 'imported_log'):
        raise OutcomeError('invalid_event', 'Unknown data source kind')
    normalized['source'] = {'kind': source['kind'], 'sourceId': identifier(source['sourceId'], 'source.sourceId'),
                            'actorId': None, 'referenceId': None}
    for field in ('actorId', 'referenceId'):
        if source.get(field) is not None:
            normalized['source'][field] = identifier(source[field], 'source.' + field)
    if source['kind'] == 'manual_entry' and normalized['source']['actorId'] is None:
        raise OutcomeError('invalid_event', 'Manual entries require an actor identifier')
    supersedes = event.get('supersedesEventId')
    normalized['supersedesEventId'] = identifier(supersedes, 'supersedesEventId') if supersedes is not None else None
    normalized['correctionReason'] = nullable_text(event.get('correctionReason'), 'correctionReason')
    if (normalized['supersedesEventId'] is None) != (normalized['correctionReason'] is None):
        raise OutcomeError('invalid_event', 'Corrections require both target event and reason')
    if normalized['supersedesEventId'] == normalized['eventId']:
        raise OutcomeError('invalid_event', 'An event cannot supersede itself')
    payload = event['payload']
    if not isinstance(payload, dict):
        raise OutcomeError('invalid_event', 'payload must be an object')
    if event['eventType'] == 'execution':
        normalized['payload'] = _execution(payload, occurred)
    else:
        if source['kind'] != 'manual_entry':
            raise OutcomeError('invalid_event', 'Quality results must be entered by a human, separately from device completion')
        normalized['payload'] = _quality(payload, occurred)
    return normalized


def _execution(payload: dict, occurred: datetime) -> dict:
    fields = {'status', 'startedAt', 'endedAt', 'actualDurationSeconds', 'materialUsedGrams',
              'completionPercent', 'failureCategory', 'failureEvidence'}
    if set(payload) != fields or not isinstance(payload['status'], str) or payload['status'] not in EXECUTION_STATUSES:
        raise OutcomeError('invalid_event', 'Execution fields or status are invalid')
    status = payload['status']
    start_text, start = timestamp(payload['startedAt'], 'startedAt', True)
    end_text, end = timestamp(payload['endedAt'], 'endedAt', True)
    if any(value is not None and value > occurred for value in (start, end)) or (start and end and end < start):
        raise OutcomeError('invalid_event', 'Execution timestamps are out of order')
    if status in {'running', 'paused', 'completed'} and start is None:
        raise OutcomeError('invalid_event', 'This execution state requires startedAt')
    if (status in TERMINAL_STATUSES and end is None) or (status in {'queued', 'running', 'paused'} and end is not None):
        raise OutcomeError('invalid_event', 'endedAt does not match execution state')
    if status == 'queued' and start is not None:
        raise OutcomeError('invalid_event', 'A queued attempt cannot already have started')
    duration = number_or_null(payload['actualDurationSeconds'], 'actualDurationSeconds', 366 * 86400)
    grams = number_or_null(payload['materialUsedGrams'], 'materialUsedGrams', 10_000_000)
    percent = number_or_null(payload['completionPercent'], 'completionPercent', 100)
    if status == 'queued' and any(value is not None and value != 0 for value in (duration, grams, percent)):
        raise OutcomeError('invalid_event', 'A queued attempt cannot claim printing progress, runtime or consumed material')
    if start is not None and duration is not None and duration > ((end or occurred) - start).total_seconds() + 1:
        raise OutcomeError('invalid_event', 'Active duration exceeds elapsed wall-clock time')
    if status == 'completed' and percent is not None and percent != 100:
        raise OutcomeError('invalid_event', 'Completed percentage must be 100 or unknown')
    category = payload['failureCategory']
    if category is not None and (not isinstance(category, str) or category not in FAILURE_CATEGORIES):
        raise OutcomeError('invalid_event', 'Unknown failure category')
    evidence = nullable_text(payload['failureEvidence'], 'failureEvidence')
    if status != 'failed' and (category is not None or evidence is not None):
        raise OutcomeError('invalid_event', 'Failure attribution belongs to a failed execution event')
    if category not in (None, 'unknown') and evidence is None:
        raise OutcomeError('invalid_event', 'Reported failure attribution needs explicit supporting evidence')
    return {'status': status, 'startedAt': start_text, 'endedAt': end_text, 'actualDurationSeconds': duration,
            'materialUsedGrams': grams, 'completionPercent': percent, 'failureCategory': category,
            'failureEvidence': evidence}


def _quality(payload: dict, occurred: datetime) -> dict:
    fields = {'status', 'inspectedAt', 'inspectorId', 'qualityScore', 'defectCodes', 'notes'}
    status = payload.get('status')
    if set(payload) != fields or (status is not None and not isinstance(status, str)) or status not in QUALITY_STATUSES:
        raise OutcomeError('invalid_event', 'Quality fields or status are invalid')
    when_text, when = timestamp(payload['inspectedAt'], 'inspectedAt', True)
    if when is not None and when > occurred:
        raise OutcomeError('invalid_event', 'Inspection cannot occur after its observation')
    inspector = identifier(payload['inspectorId'], 'inspectorId') if payload['inspectorId'] is not None else None
    score = number_or_null(payload['qualityScore'], 'qualityScore', 100)
    defects = payload['defectCodes']
    if not isinstance(defects, list) or len(defects) > 16 or any(not isinstance(item, str) or item not in DEFECT_CODES for item in defects) or len(set(defects)) != len(defects):
        raise OutcomeError('invalid_event', 'defectCodes must be a bounded unique list of supported codes')
    if status in INSPECTED_STATUSES:
        if when is None or inspector is None:
            raise OutcomeError('invalid_event', 'An inspected outcome needs its human inspector and time')
    elif when is not None or inspector is not None or score is not None or defects:
        raise OutcomeError('invalid_event', 'Uninspected/unknown/null status cannot contain a claimed inspection')
    return {'status': status, 'inspectedAt': when_text, 'inspectorId': inspector, 'qualityScore': score,
            'defectCodes': list(defects), 'notes': nullable_text(payload['notes'], 'notes')}


def _object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('Duplicate JSON field')
        value[key] = item
    return value


def _read_rows(path: Path, *, missing_ok: bool = False) -> list[dict]:
    if missing_ok and not path.exists():
        return []
    rows = []
    try:
        with path.open('rb') as handle:
            while True:
                line = handle.readline(MAX_LINE_BYTES + 1)
                if not line:
                    break
                if len(line) > MAX_LINE_BYTES or not line.endswith(b'\n'):
                    raise ValueError('Oversized or incomplete JSONL line')
                if not line.strip():
                    raise ValueError('Empty JSONL row')
                row = json.loads(line.decode('utf-8-sig'), object_pairs_hook=_object,
                                 parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Nonfinite JSON')))
                if not isinstance(row, dict):
                    raise ValueError('JSONL row must be an object')
                rows.append(row)
    except FileNotFoundError as exc:
        raise OutcomeError('missing_feedback', 'Referenced feedback ledger does not exist') from exc
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise OutcomeError('corrupt_log', 'Local JSONL is malformed or incomplete; it was not modified') from exc
    return rows


def _feedback_binding(feedback_path: Path, event: dict) -> tuple[dict, dict]:
    with _ledger_lock(feedback_path):
        matches = [row for row in _read_rows(feedback_path) if row.get('recordId') == event['recordId']]
    if len(matches) != 1:
        raise OutcomeError('feedback_not_found' if not matches else 'corrupt_log', 'recordId must identify exactly one existing feedback record')
    record = matches[0]
    request = record.get('request')
    if not isinstance(request, dict) or not isinstance(request.get('plate'), dict) or not isinstance(request.get('candidates'), list):
        raise OutcomeError('corrupt_log', 'Feedback does not contain a valid decision snapshot')
    plate = request['plate']
    identifier(request.get('requestId'), 'feedback.requestId')
    if plate.get('id') != event['plateId']:
        raise OutcomeError('identity_conflict', 'Outcome plate differs from the original feedback plate')
    candidates = request['candidates']
    ids = [item.get('id') for item in candidates if isinstance(item, dict)]
    if len(ids) != len(candidates) or any(not isinstance(value, str) for value in ids) or len(set(ids)) != len(ids):
        raise OutcomeError('corrupt_log', 'Feedback candidate identity is ambiguous')
    found = [item for item in candidates if item['id'] == event['candidateId']]
    if len(found) != 1:
        raise OutcomeError('identity_conflict', 'Outcome candidate was not in the original eligible candidate snapshot')
    selected = record.get('selectedCandidateId')
    if selected is not None and selected != event['candidateId']:
        raise OutcomeError('identity_conflict', 'Outcome candidate differs from the feedback selection; record a new decision first')
    binding = {'recordSha256': digest(record), 'requestId': request['requestId'], 'plateId': plate['id'],
               'candidateId': event['candidateId'], 'plateSha256': digest(plate), 'candidateSha256': digest(found[0])}
    return binding, record


def _snapshot_timing(record: dict, event: dict, history: list[dict]) -> dict:
    """Annotate timing only; never transform a retrospective snapshot into a label."""
    start = event['payload'].get('startedAt') if event['eventType'] == 'execution' else None
    if start is None and (event['eventType'] == 'quality' or event['supersedesEventId'] is None):
        removed = {row['supersedesEventId'] for row in history if row['supersedesEventId'] is not None}
        start = next((row['payload']['startedAt'] for row in reversed(history)
                      if row['eventId'] not in removed and row['eventType'] == 'execution'
                      and row['payload']['startedAt'] is not None), None)
    observation = record.get('observation')
    supplied = {'startedAt': start, 'feedbackCreatedAt': record.get('createdAt'),
                'observationSnapshotAt': observation.get('snapshot_at') if isinstance(observation, dict) else None}
    parsed, normalized, reasons = {}, {}, ['unreviewed_observation_not_training_label']
    for name, value in supplied.items():
        try:
            normalized[name], parsed[name] = timestamp(value, name, True)
        except OutcomeError:
            normalized[name], parsed[name] = None, None
            reasons.append(name + '_invalid')
        if parsed[name] is None:
            reasons.append(name + '_missing_or_unverified')
    started = parsed['startedAt']
    late = [name for name in ('feedbackCreatedAt', 'observationSnapshotAt')
            if started is not None and parsed[name] is not None and started < parsed[name]]
    if late:
        flag, status = True, 'captured_after_start'
        reasons.append('decision_snapshot_captured_after_print_start_exclude_from_prospective_labels')
    elif all(value is not None for value in parsed.values()) and \
            all(parsed[name] < started for name in ('feedbackCreatedAt', 'observationSnapshotAt')):
        flag, status = False, 'timestamps_precede_start'
    else:
        flag, status = None, 'unknown'
        reasons.append('decision_snapshot_timing_requires_review')
    return {'snapshotCapturedAfterStart': flag,
            'decision_snapshot_timing': {'status': status, **normalized, 'lateSources': late,
                                         'timestampEvidenceVerified': False,
                                         'prospectiveTrainingUseAllowed': False},
            'reviewReasons': reasons}


@contextmanager
def _ledger_lock(path: Path):
    """Serialize threads and local processes; leave a stable sidecar lock inode."""
    key = str(path.resolve()).casefold() if os.name == 'nt' else str(path.resolve())
    with _locks_guard:
        lock = _locks.setdefault(key, threading.RLock())
    with lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.with_name(path.name + '.lock').open('a+b') as handle:
            handle.seek(0, os.SEEK_END)
            if handle.tell() == 0:
                handle.write(b'0')
                handle.flush()
            deadline = time.monotonic() + 5
            while True:
                try:
                    handle.seek(0)
                    if os.name == 'nt':
                        import msvcrt
                        msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        import fcntl
                        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as exc:
                    if time.monotonic() >= deadline:
                        raise OutcomeError('ledger_busy', 'Outcome ledger is busy; retry the same event ID') from exc
                    time.sleep(.02)
            try:
                yield
            finally:
                handle.seek(0)
                if os.name == 'nt':
                    import msvcrt
                    msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _validate_stored_rows(rows: list[dict]) -> None:
    seen = set()
    for row in rows:
        event_id = row.get('eventId')
        if not isinstance(event_id, str) or event_id in seen or row.get('trainingEligible') is not False or \
                row.get('automaticFaultAttribution') is not False or row.get('sourceVerification') != 'unverified_client_claim' or \
                not isinstance(row.get('binding'), dict):
            raise OutcomeError('corrupt_log', 'Outcome ledger identities or safety metadata are invalid')
        seen.add(event_id)
        original = {key: value for key, value in row.items() if key not in
                    {'binding', 'recordedAt', 'eventSha256', 'trainingEligible', 'sourceVerification', 'automaticFaultAttribution',
                     'snapshotCapturedAfterStart', 'decision_snapshot_timing', 'reviewReasons'}}
        if digest(original) != row.get('eventSha256'):
            raise OutcomeError('corrupt_log', 'Stored event content changed')


def _validate_history(history: list[dict], event: dict, binding: dict) -> None:
    for old in history:
        if any(old.get(key) != event[key] for key in ('recordId', 'plateId', 'candidateId')):
            raise OutcomeError('attempt_conflict', 'An attempt cannot change feedback, plate or candidate identity')
        if old['binding'] != binding:
            raise OutcomeError('feedback_changed', 'Original decision snapshot changed after this attempt was recorded')
    superseded = {row['supersedesEventId'] for row in history if row['supersedesEventId'] is not None}
    active = [row for row in history if row['eventId'] not in superseded]
    same_type = [row for row in active if row['eventType'] == event['eventType']]
    target = event['supersedesEventId']
    if target is not None:
        if not same_type or same_type[-1]['eventId'] != target:
            raise OutcomeError('correction_conflict', 'Correction must supersede the latest active event of the same type in this attempt')
        if event['source']['kind'] != 'manual_entry':
            raise OutcomeError('correction_conflict', 'Corrections require an explicit human source and reason')
    if history and timestamp(event['occurredAt'], 'occurredAt')[1] < max(timestamp(row['occurredAt'], 'occurredAt')[1] for row in history):
        raise OutcomeError('out_of_order', 'New observations must not predate this attempt history; preserve earlier values in payload timestamps')
    executions = [row for row in active if row['eventType'] == 'execution']
    if event['eventType'] == 'quality':
        if not executions:
            raise OutcomeError('attempt_conflict', 'Record an execution observation first, even if its state is unknown')
        inspection = timestamp(event['payload']['inspectedAt'], 'inspectedAt', True)[1]
        starts = [timestamp(row['payload']['startedAt'], 'startedAt', True)[1] for row in executions]
        known_starts = [value for value in starts if value is not None]
        if inspection is not None and known_starts and inspection < min(known_starts):
            raise OutcomeError('invalid_event', 'Inspection predates the known start of this attempt')
    elif same_type and target is None:
        previous = same_type[-1]['payload']
        current = event['payload']
        if previous['status'] in TERMINAL_STATUSES and current['status'] != previous['status']:
            raise OutcomeError('transition_conflict', 'A terminal attempt cannot reopen; create a new attempt or explicit correction')
        if any(row['payload']['status'] in {'running', 'paused'} for row in same_type) and current['status'] == 'queued':
            raise OutcomeError('transition_conflict', 'A started attempt cannot return to queued')
        known_starts = [row['payload']['startedAt'] for row in same_type if row['payload']['startedAt'] is not None]
        if known_starts and current['startedAt'] is not None and known_starts[-1] != current['startedAt']:
            raise OutcomeError('transition_conflict', 'Attempt start changed without a correction')
        if previous['status'] in TERMINAL_STATUSES and current['endedAt'] != previous['endedAt']:
            raise OutcomeError('transition_conflict', 'Attempt end changed without a correction')
    if event['eventType'] == 'execution' and event['payload']['startedAt'] is not None:
        current_start = timestamp(event['payload']['startedAt'], 'startedAt')[1]
        quality_times = [timestamp(row['payload']['inspectedAt'], 'inspectedAt', True)[1]
                         for row in active if row['eventType'] == 'quality']
        if any(value is not None and value < current_start for value in quality_times):
            raise OutcomeError('transition_conflict', 'Execution start would move after an existing inspection')


def append_feedback(feedback_path: Path, body: dict, *, now: datetime | None = None) -> dict:
    """Durably append a validated decision snapshot; identical deliveries reuse it.

    requestId is part of the complete content digest. A new snapshot, selection,
    or feedback is a distinct observation; a network retry of the same snapshot
    cannot split subsequent print attempts across duplicate feedback records.
    Validation of the client envelope remains the HTTP service's responsibility.
    """
    fields = {'request', 'decision', 'feedback', 'selectedCandidateId', 'outcome', 'observation'}
    if not isinstance(body, dict) or set(body) - fields or not {'request', 'feedback'} <= set(body):
        raise OutcomeError('invalid_event', 'Expected a validated feedback envelope')
    submission_hash = digest(body)
    path = Path(feedback_path).resolve()
    with _ledger_lock(path):
        for old in _read_rows(path, missing_ok=True):
            original = {key: value for key, value in old.items() if key in fields}
            original_hash = digest(original)
            if old.get('submissionSha256', original_hash) != original_hash:
                raise OutcomeError('corrupt_log', 'Stored feedback content changed')
            if original_hash == submission_hash:
                record_id = identifier(old.get('recordId'), 'recordId')
                return {'recordId': record_id, 'duplicate': True, 'trainingEligible': False}
        stored = {'recordId': str(uuid.uuid4()), 'createdAt': _now(now).isoformat().replace('+00:00', 'Z'),
                  **body, 'submissionSha256': submission_hash,
                  'trainingEligible': False, 'source': 'client_feedback_unverified'}
        data = canonical(stored) + b'\n'
        if len(data) > MAX_LINE_BYTES:
            raise OutcomeError('invalid_event', 'Feedback exceeds the ledger size limit')
        with path.open('ab') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        return {'recordId': stored['recordId'], 'duplicate': False, 'trainingEligible': False}


def append_outcome(feedback_path: Path, outcomes_path: Path, event: dict, *, now: datetime | None = None) -> dict:
    normalized = normalize_event(event, now=now)
    feedback_path, outcomes_path = Path(feedback_path).resolve(), Path(outcomes_path).resolve()
    if feedback_path == outcomes_path or (feedback_path.exists() and outcomes_path.exists() and feedback_path.samefile(outcomes_path)):
        raise OutcomeError('invalid_path', 'Feedback and outcome ledgers must be separate files')
    with _ledger_lock(outcomes_path):
        binding, feedback = _feedback_binding(feedback_path, normalized)
        rows = _read_rows(outcomes_path, missing_ok=True)
        _validate_stored_rows(rows)
        existing = [row for row in rows if row['eventId'] == normalized['eventId']]
        event_hash = digest(normalized)
        if existing:
            row = existing[0]
            if row['eventSha256'] != event_hash:
                raise OutcomeError('event_conflict', 'eventId already exists with different data; append a correction with a new ID')
            if row['binding'] != binding:
                raise OutcomeError('feedback_changed', 'Referenced feedback changed after the original event')
            return {'eventId': row['eventId'], 'attemptId': row['attemptId'], 'recordId': row['recordId'],
                    'duplicate': True, 'trainingEligible': False,
                    'snapshotCapturedAfterStart': row.get('snapshotCapturedAfterStart'),
                    'decision_snapshot_timing': row.get('decision_snapshot_timing', {'status': 'unknown'}),
                    'reviewReasons': row.get('reviewReasons', ['legacy_snapshot_timing_requires_review'])}
        history = [row for row in rows if row['attemptId'] == normalized['attemptId']]
        _validate_history(history, normalized, binding)
        stored = {**normalized, 'binding': binding, 'recordedAt': _now(now).isoformat().replace('+00:00', 'Z'),
                  'eventSha256': event_hash, 'trainingEligible': False,
                  'sourceVerification': 'unverified_client_claim', 'automaticFaultAttribution': False,
                  **_snapshot_timing(feedback, normalized, history)}
        data = canonical(stored) + b'\n'
        with outcomes_path.open('ab') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        return {'eventId': stored['eventId'], 'attemptId': stored['attemptId'], 'recordId': stored['recordId'],
                'duplicate': False, 'trainingEligible': False,
                'snapshotCapturedAfterStart': stored['snapshotCapturedAfterStart'],
                'decision_snapshot_timing': stored['decision_snapshot_timing'], 'reviewReasons': stored['reviewReasons']}


def read_attempt_history(outcomes_path: Path, attempt_id: str) -> list[dict]:
    attempt_id = identifier(attempt_id, 'attemptId')
    path = Path(outcomes_path).resolve()
    with _ledger_lock(path):
        rows = _read_rows(path, missing_ok=True)
        _validate_stored_rows(rows)
        return [row for row in rows if row['attemptId'] == attempt_id]


def read_active_attempts(outcomes_path: Path, record_ids: set[str]) -> list[dict]:
    """Latest active execution/quality observations per selected record's attempt.

    A missing quality event returns quality=None and qualityEventId=None. An
    explicit null quality status remains a payload with status=None. This is a
    presentation view only: no source verification or training approval occurs.
    The route must select visible feedback IDs before calling this helper.
    """
    if not isinstance(record_ids, (set, frozenset)):
        raise OutcomeError('invalid_event', 'record_ids must be an explicit set')
    for record_id in record_ids:
        identifier(record_id, 'recordId')
    if not record_ids:
        return []
    path = Path(outcomes_path).resolve()
    with _ledger_lock(path):
        rows = _read_rows(path, missing_ok=True)
        _validate_stored_rows(rows)
        grouped: dict[str, list[dict]] = {}
        for row in rows:
            if row['recordId'] in record_ids:
                grouped.setdefault(row['attemptId'], []).append(row)
        summaries = []
        for attempt_id, history in grouped.items():
            removed = {row['supersedesEventId'] for row in history if row['supersedesEventId'] is not None}
            active = [row for row in history if row['eventId'] not in removed]
            latest = {kind: next((row for row in reversed(active) if row['eventType'] == kind), None)
                      for kind in ('execution', 'quality')}
            last = history[-1]
            summaries.append({'attemptId': attempt_id, 'recordId': last['recordId'], 'plateId': last['plateId'],
                              'candidateId': last['candidateId'],
                              'executionEventId': latest['execution']['eventId'] if latest['execution'] else None,
                              'execution': latest['execution']['payload'] if latest['execution'] else None,
                              'qualityEventId': latest['quality']['eventId'] if latest['quality'] else None,
                              'quality': latest['quality']['payload'] if latest['quality'] else None,
                              'lastOccurredAt': last['occurredAt'], 'trainingEligible': False,
                              'snapshotCapturedAfterStart': last.get('snapshotCapturedAfterStart'),
                              'decision_snapshot_timing': last.get('decision_snapshot_timing', {'status': 'unknown'}),
                              'reviewReasons': last.get('reviewReasons', ['legacy_snapshot_timing_requires_review'])})
        return sorted(summaries, key=lambda value: (timestamp(value['lastOccurredAt'], 'lastOccurredAt')[1],
                                                    value['attemptId']), reverse=True)
