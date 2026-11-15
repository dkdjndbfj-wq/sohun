"""Explicit offline export of independently reviewed v4 feedback; never trains.

Workflow (all paths are local; no checkpoint or GPU is loaded):
  python reviewed_v4_export.py template --records feedback.jsonl --out reviews.jsonl
  # A human supplies episodeId, selectedCandidateId, reviewer, rationale, reviewedAt.
  python reviewed_v4_export.py export --records feedback.jsonl --labels reviews.jsonl --out new_bundle
  # Optional --tokenizer LOCAL_DIRECTORY audits every row through the same input
  # builder as inference. Without it only pending_*.jsonl previews are written.

The ledger and reviewer are declarations, not authenticated hardware provenance.
Hashes bind the exact reviewed content; they do not certify its truth. Known
simulation markers are rejected, but arbitrary relabelling cannot be detected.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import re
import time

from decision_contract import (SCHEMA, MAX_LEN, HEAD_MAX_LEN, build_decision_input,
                               label_for_candidate, normalize_request)
from mifu_server import ApiError, SDK_VERSION, live_v4_envelope, unique_json_object, validate_json
from outcome_collection import digest, identifier
from validate_observation import validate_observation

LABEL_SCHEMA = 'mifu-reviewed-v4-label-v1'
SPLITS = ('train', 'validation', 'calibration', 'heldout')
BODY_FIELDS = {'request', 'decision', 'feedback', 'selectedCandidateId', 'outcome', 'observation'}
LEDGER_FIELDS = {'recordId', 'createdAt', 'submissionSha256', 'trainingEligible', 'source'}
LABEL_FIELDS = {'schema', 'recordId', 'recordSha256', 'requestSha256', 'candidateIds',
                'episodeId', 'selectedCandidateId', 'reviewSource', 'reviewer', 'rationale', 'reviewedAt'}
SOURCE_NOTICE = 'client-declared live_snapshot; unsigned unverified ledger; independently supplied human review declaration'


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _read_jsonl(path: Path):
    """Hash the bytes actually parsed, instead of a second mutable file read."""
    rows, checksum = [], hashlib.sha256()
    with path.open('rb') as handle:
        for number, raw in enumerate(handle, 1):
            _require(len(raw) <= 384 * 1024, f'Line {number} exceeds the record size limit')
            checksum.update(raw)
            text = raw.decode('utf-8-sig' if number == 1 else 'utf-8')
            if not text.strip():
                continue
            row = json.loads(text, object_pairs_hook=unique_json_object,
                             parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Non-finite JSON')))
            _require(isinstance(row, dict), f'Line {number} must be an object')
            rows.append(row)
    return rows, checksum.hexdigest()


def _timestamp(value, field):
    _require(isinstance(value, str) and 1 <= len(value) <= 64, field + ' requires a timezone timestamp')
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        _require(parsed.tzinfo is not None and parsed.utcoffset() is not None, field + ' requires timezone')
        return parsed.timestamp()
    except (ValueError, OverflowError, OSError) as exc:
        raise ValueError(field + ' is not a valid timezone timestamp') from exc


def _reject_known_simulation(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {'source', 'featureSchemaVersion', 'gate_version', 'version'} and isinstance(item, str):
                lowered = item.lower()
                _require(not (lowered.startswith(('synthetic', 'simulation', 'hardware-sim', 'mifu-hardware-sim'))
                              or lowered == 'simulated'), 'Known synthetic provenance cannot enter reviewed live export')
            if key in {'synthetic', 'simulated', 'isSynthetic'}:
                _require(item is not True, 'Known synthetic provenance cannot enter reviewed live export')
            _reject_known_simulation(item)
    elif isinstance(value, list):
        for item in value:
            _reject_known_simulation(item)


def _real_namespace(value, field):
    identifier(value, field)
    _require(re.match(r'^(synthetic|simulation|simulated|sim)(?:[-_:]|$)', value, re.I) is None,
             field + ' uses a reserved simulation namespace')
    return value


def _validate_record(record, *, now_epoch_s):
    _require(isinstance(record, dict) and LEDGER_FIELDS | {'request', 'feedback'} <= set(record)
             and set(record) <= LEDGER_FIELDS | BODY_FIELDS, 'Expected the original feedback ledger record')
    _real_namespace(record['recordId'], 'recordId')
    _require(record['source'] == 'client_feedback_unverified' and record['trainingEligible'] is False,
             'Original unverified client feedback provenance is required; no pre-approved or synthetic source')
    _reject_known_simulation(record)
    body = {key: value for key, value in record.items() if key in BODY_FIELDS}
    _require(record['submissionSha256'] == digest(body), 'Feedback submission hash mismatch')
    request = record['request']
    _require(isinstance(request, dict) and set(request) == {'requestId', 'plate', 'candidates', 'decision_context'},
             'Reviewed export requires the exact v4 request envelope')
    try:
        live_v4_envelope(request)
        validate_json({key: value for key, value in body.items() if key != 'observation'}, depth=-1)
        if body.get('observation') is not None:
            validate_json(body['observation'], list_limit=1024)
    except ApiError as exc:
        raise ValueError(str(exc)) from exc
    created = _timestamp(record['createdAt'], 'createdAt')
    _require(0 < created <= now_epoch_s, 'Feedback creation time is future or invalid')
    context = request['decision_context']
    _real_namespace(request['requestId'], 'requestId')
    _real_namespace(context.get('snapshot_id'), 'snapshot_id')
    plate = request.get('plate')
    _require(isinstance(plate, dict), 'plate must be an object')
    tasks = []
    for key in ('taskId', 'jobId'):
        if key in plate:
            tasks.append((key, _real_namespace(plate[key], 'plate.' + key)))
    _require(tasks, 'plate.taskId or plate.jobId is required for task isolation')
    times = [context.get('observed_at_epoch_s')]
    candidates = request.get('candidates')
    _require(isinstance(candidates, list) and candidates, 'Candidate evidence is missing')
    for candidate in candidates:
        _require(isinstance(candidate, dict), 'Candidate evidence is invalid')
        _real_namespace(candidate.get('id'), 'candidate.id')
        gate, features = candidate.get('admission'), candidate.get('features')
        _require(isinstance(gate, dict) and isinstance(features, dict), 'Candidate timing or admission is missing')
        times.append(gate.get('observed_at_epoch_s'))
        timing = features.get('timing_evidence')
        _require(isinstance(timing, dict), 'Timing evidence is missing')
        for key in ('setup', 'wait'):
            entry = timing.get(key)
            _require(isinstance(entry, dict), key + ' timing evidence is missing')
            times.append(entry.get('observed_at_epoch_s'))
    _require(all(type(value) in (int, float) and math.isfinite(value) and 0 < value <= created for value in times),
             'Evidence timestamps must be finite, present and no later than original record creation')
    # This clock is ONLY for offline internal consistency. Do not copy it into
    # the request or use it to revive a historical request for live inference.
    historical_epoch = max(times)
    prepared = normalize_request(request, now_epoch_s=historical_epoch, minimum_candidates=1)
    observation = body.get('observation')
    if observation is not None:
        validate_observation(observation, request)
        observed = _timestamp(observation['snapshot_at'], 'observation.snapshot_at')
        _require(abs(observed - context['observed_at_epoch_s']) <= .001,
                 'Observation snapshot timestamp does not bind the original decision snapshot')
        for key in ('devices', 'ams_units', 'feed_slots'):
            for entry in observation[key]:
                for field in ('telemetry_at', 'ams_telemetry_at'):
                    if entry.get(field) is not None:
                        _require(0 < _timestamp(entry[field], 'observation.' + field) <= created,
                                 'Observation telemetry cannot be future to the original record')
    ids = list(prepared['mapping'].values())
    selected, feedback = body.get('selectedCandidateId'), body['feedback']
    _require(isinstance(feedback, str) and feedback in {'accepted', 'corrected', 'observed'}, 'Invalid feedback kind')
    _require(selected is None or isinstance(selected, str) and selected in ids, 'Feedback candidate is not in request')
    _require(feedback == 'observed' or selected is not None, 'Accepted/corrected feedback needs its original selection')
    decision = body.get('decision')
    _require(decision is None or len(ids) > 1 and isinstance(decision, dict)
             and decision.get('requestId') == request['requestId'] and decision.get('choice') in ids
             and decision.get('inputContract') == SCHEMA, 'Stored decision is not bound to this v4 request')
    _require(isinstance(body.get('outcome', {}), dict), 'Stored outcome must be an object')
    return prepared, historical_epoch, created, tasks


def review_binding(record):
    """Immutable fields a reviewer must retain; a digest is not authentication."""
    return {'schema': LABEL_SCHEMA, 'recordId': record['recordId'], 'recordSha256': digest(record),
            'requestSha256': digest(record['request']),
            'candidateIds': [candidate['id'] for candidate in record['request']['candidates']]}


def _load_records(path):
    rows, checksum = _read_jsonl(path)
    records = {}
    for record in rows:
        record_id = record.get('recordId')
        identifier(record_id, 'recordId')
        _require(record_id not in records, 'Duplicate recordId in ledger')
        records[record_id] = record
    return records, checksum


def _validate_review(label, record, *, created, now_epoch_s):
    _require(set(label) == LABEL_FIELDS, 'Expected the explicit v4 review label schema')
    for key, value in review_binding(record).items():
        _require(label.get(key) == value, 'Review binding mismatch: ' + key)
    _real_namespace(label['episodeId'], 'episodeId')
    _require(isinstance(label['reviewSource'], str) and label['reviewSource'] in {'expert_review', 'controlled_experiment'},
             'A separate expert_review or controlled_experiment label is required')
    identifier(label['reviewer'], 'reviewer')
    rationale = label['rationale']
    _require(isinstance(rationale, str) and rationale.strip() and len(rationale) <= 4096
             and not any(ord(c) < 32 and c not in '\n\t' for c in rationale), 'A bounded review rationale is required')
    _require(created <= _timestamp(label['reviewedAt'], 'reviewedAt') <= now_epoch_s,
             'Review time must follow the archived record and not be future')
    _require(isinstance(label['selectedCandidateId'], str) and label['selectedCandidateId'] in label['candidateIds'],
             'Reviewed choice is not an eligible candidate')


def _input_hash(prepared):
    """Identity-free, candidate-permutation-invariant model evidence signature."""
    state, question = prepared['state'], prepared['questions']['printer']
    candidates = sorted(digest({'features': features, 'criterion': question['criteria'][key]})
                        for key, features in state['candidates'].items())
    return digest({'state': {key: value for key, value in state.items() if key != 'candidates'},
                   'question': {key: value for key, value in question.items() if key != 'criteria'},
                   'candidates': candidates})


def _group_and_split(items, seed, excluded_links=()):
    # Union shared task/episode/snapshot and identical/permuted model evidence.
    # Transitive links matter: one episode may contain several related tasks.
    # Non-ranking records must not become training rows, but can still connect
    # a task to an episode represented by another ranking example. Dropping
    # those links before the union would leak related work across splits.
    all_items = [*items, *excluded_links]
    parents = list(range(len(all_items)))
    def root(index):
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index
    owners = {}
    for index, item in enumerate(all_items):
        for key in item['groupKeys']:
            if key in owners:
                parents[root(index)] = root(owners[key])
            else:
                owners[key] = index
    members = {}
    for index, item in enumerate(all_items):
        members.setdefault(root(index), []).append(item)
    groups = {}
    for related in members.values():
        ranking_items = [item for item in related if not item.get('excludedFromRanking', False)]
        if not ranking_items:
            continue
        group = digest(sorted({key for item in related for key in item['groupKeys']}))
        groups[group] = ranking_items
    _require(len(groups) >= 4, 'Need at least four independent task/episode/input groups for four isolated splits')
    ordered = sorted(groups, key=lambda group: (digest({'seed': seed, 'group': group}), group))
    reserved = max(1, len(groups) // 10)
    sizes = dict(zip(SPLITS, (len(groups) - 3 * reserved, reserved, reserved, reserved)))
    split_groups, offset = {}, 0
    for split in SPLITS:
        split_groups[split] = ordered[offset:offset + sizes[split]]
        offset += sizes[split]
        for group in split_groups[split]:
            for item in groups[group]:
                item.update(split=split, groupId=group)
    return split_groups


def _tokenizer_hashes(directory):
    _require(directory.is_dir() and (directory / 'tokenizer.json').is_file(),
             '--tokenizer must be an existing local tokenizer directory')
    hashes = {}
    for path in sorted(directory.rglob('*')):
        _require(not path.is_symlink(), 'Tokenizer symlinks are not accepted as stable audit evidence')
        if path.is_file():
            hashes[path.relative_to(directory).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def _load_local_tokenizer(directory):
    packages = {name: importlib.metadata.version(name) for name in ('laya', 'transformers', 'tokenizers')}
    _require(packages['laya'] == SDK_VERSION, 'Use the pinned Laya SDK ' + SDK_VERSION + ' for the input audit')
    # Explicit local_files_only is the download boundary; no weights are loaded.
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(str(directory), local_files_only=True, trust_remote_code=False)
    return tokenizer, packages


def prepare_review_template(records_path: Path, output: Path, *, now_epoch_s=None):
    """Make blank labels, never select a device or invent an independent review."""
    _require(not output.exists(), 'Output already exists; it will not be overwritten')
    now = time.time() if now_epoch_s is None else now_epoch_s
    records, checksum = _load_records(records_path)
    templates, excluded = [], []
    for record_id, record in sorted(records.items()):
        request = record.get('request')
        if not isinstance(request, dict) or 'decision_context' not in request:
            excluded.append(record_id)
            continue
        _validate_record(record, now_epoch_s=now)
        templates.append({**review_binding(record), 'episodeId': '', 'selectedCandidateId': '',
                          'reviewSource': 'expert_review', 'reviewer': '', 'rationale': '', 'reviewedAt': ''})
    _require(templates, 'No v4 records available for review')
    with output.open('x', encoding='utf-8', newline='\n') as handle:
        for label in templates:
            handle.write(json.dumps(label, ensure_ascii=False, allow_nan=False) + '\n')
    return {'status': 'review_required', 'recordsSha256': checksum, 'templates': len(templates),
            'excludedLegacyRecordIds': excluded, 'sourceNotice': SOURCE_NOTICE,
            'trainingStarted': False, 'deployable': False}


def export_reviewed_v4(records_path: Path, labels_path: Path, output: Path, *,
                       tokenizer_dir: Path | None = None, seed: str = '4070', now_epoch_s=None):
    """Export v4 only. Optional audit success is input preservation, not quality."""
    output, records_path, labels_path = Path(output), Path(records_path), Path(labels_path)
    _require(not output.exists(), 'Output already exists; it will not be overwritten')
    identifier(seed, 'split seed')
    now = time.time() if now_epoch_s is None else now_epoch_s
    _require(type(now) in (int, float) and math.isfinite(now) and now > 0, 'Invalid export clock')
    records, records_hash = _load_records(records_path)
    labels, labels_hash = _read_jsonl(labels_path)
    items, excluded, excluded_links, reviewed, choices = [], [], [], set(), {}
    for label in labels:
        record_id = label.get('recordId')
        _require(isinstance(record_id, str) and record_id in records and record_id not in reviewed,
                 'Review references missing or duplicate recordId')
        reviewed.add(record_id)
        record = records[record_id]
        prepared, historical, created, tasks = _validate_record(record, now_epoch_s=now)
        _validate_review(label, record, created=created, now_epoch_s=now)
        selected = label_for_candidate(prepared, label['selectedCandidateId'])
        request_hash = digest(record['request'])
        _require(request_hash not in choices or choices[request_hash] == label['selectedCandidateId'],
                 'Conflicting reviews for the same immutable request')
        choices[request_hash] = label['selectedCandidateId']
        signature = _input_hash(prepared)
        group_keys = [digest(['task', value]) for _, value in tasks]
        group_keys += [digest(['episode', label['episodeId']]), digest(['model_input', signature]),
                       digest(['request', record['request']['requestId']]),
                       digest(['snapshot', record['request']['decision_context']['snapshot_id']])]
        if len(prepared['mapping']) == 1:
            excluded.append({'recordId': record_id, 'reason': 'single_candidate_not_a_ranking_example',
                             'recordSha256': digest(record), 'labelSha256': digest(label),
                             'isolationGroupKeysSha256': group_keys})
            excluded_links.append({'excludedFromRanking': True, 'groupKeys': group_keys})
            continue
        items.append({'record': record, 'review': label, 'prepared': prepared, 'historicalEpoch': historical,
                      'expected': selected, 'inputHash': signature, 'groupKeys': group_keys})
    split_groups = _group_and_split(items, seed, excluded_links)
    tokenizer, packages, tokenizer_hashes = None, {}, {}
    audit = {'status': 'pending', 'rows': 0, 'maxSequenceTokens': None, 'maxOptionTokens': None,
             'maxLen': MAX_LEN, 'headMaxLen': HEAD_MAX_LEN, 'allRowsAudited': False}
    if tokenizer_dir is not None:
        tokenizer_dir = Path(tokenizer_dir).resolve(strict=True)
        tokenizer_hashes = _tokenizer_hashes(tokenizer_dir)
        tokenizer, packages = _load_local_tokenizer(tokenizer_dir)
        maxima = Counter()
        for item in items:
            rebuilt = build_decision_input(item['record']['request'], tokenizer=tokenizer,
                                           now_epoch_s=item['historicalEpoch'])
            _require(rebuilt['state'] == item['prepared']['state'] and rebuilt['questions'] == item['prepared']['questions']
                     and rebuilt['mapping'] == item['prepared']['mapping'], 'Shared input projection changed during audit')
            check = rebuilt['diagnostics']['token_audit']
            _require(check.get('status') == 'passed' and not check.get('errors'), 'Token audit did not pass')
            for key in ('sequence_tokens', 'max_option_tokens'):
                _require(type(check.get(key)) is int and check[key] >= 0, 'Incomplete token audit evidence')
                maxima[key] = max(maxima[key], check[key])
            item['prepared'] = rebuilt
        _require(tokenizer_hashes == _tokenizer_hashes(tokenizer_dir), 'Tokenizer changed during audit')
        audit.update(status='passed_all_rows', rows=len(items), allRowsAudited=True,
                     maxSequenceTokens=maxima['sequence_tokens'], maxOptionTokens=maxima['max_option_tokens'],
                     tokenizerFilesSha256=tokenizer_hashes, packages=packages)
    audited = tokenizer is not None
    rows = {split: [] for split in SPLITS}
    sources = []
    for item in sorted(items, key=lambda item: item['record']['recordId']):
        record, label, prepared = item['record'], item['review'], item['prepared']
        provenance = {'inputContract': SCHEMA, 'source': 'reviewed_client_declared_live_snapshot',
                      'sourceVerification': 'unverified_client_ledger_and_review_declaration',
                      'recordId': record['recordId'], 'recordSha256': digest(record),
                      'requestSha256': digest(record['request']), 'reviewSha256': digest(label),
                      'groupId': item['groupId'], 'inputPermutationInvariantSha256': item['inputHash'],
                      'split': item['split'], 'offlineOnly': True, 'tokenAuditStatus': audit['status']}
        model_row = {'state': prepared['state'], 'questions': prepared['questions'],
                     'expected': {'printer': item['expected']}}
        row = ({**model_row, 'mifu_provenance': provenance} if audited else
               {'inputContract': SCHEMA, 'status': 'pending_token_audit',
                'model_input_preview': model_row, 'mifu_provenance': provenance})
        rows[item['split']].append(row)
        sources.append({'record': record, 'review': label, 'binding': provenance,
                        'offlineValidationEpochS': item['historicalEpoch'],
                        'liveFreshnessGranted': False, 'diagnostics': prepared['diagnostics']})
    report = {'schemaVersion': 1, 'inputContract': SCHEMA,
              'status': 'exported_input_audited_pending_training_and_acceptance' if audited else 'pending_token_audit',
              'sourceNotice': SOURCE_NOTICE,
              'sourceAuthentication': 'not_performed', 'syntheticDetection': 'known_markers_and_reserved_namespaces_only',
              'sources': {'recordsFile': records_path.name, 'recordsSha256': records_hash,
                          'labelsFile': labels_path.name, 'labelsSha256': labels_hash},
              'pipelineFilesSha256': {name: hashlib.sha256((Path(__file__).resolve().parent / name).read_bytes()).hexdigest()
                                      for name in ('reviewed_v4_export.py', 'decision_contract.py', 'audit_token_budget.py')},
              'ledgerRecords': len(records), 'reviewedRecords': len(reviewed),
              'unreviewedRecords': len(records) - len(reviewed), 'exportedRows': len(items),
              'excludedSingleCandidateRecords': excluded,
              'splitMethod': 'seeded_hash_of_transitive_task_episode_snapshot_and_permutation_invariant_input_groups',
              'splitSeed': seed, 'splitTargetFractions': dict(zip(SPLITS, (.7, .1, .1, .1))),
              'splitGroups': split_groups, 'groupCount': sum(map(len, split_groups.values())),
              'splitRows': {split: len(values) for split, values in rows.items()},
              'candidateCounts': dict(sorted(Counter(str(len(item['prepared']['mapping'])) for item in items).items())),
              'tokenAudit': audit, 'trainingFilesWritten': audited, 'trainingStarted': False,
              'modelReady': False, 'deployable': False, 'automaticExecutionAuthorized': False,
              'reservedSplits': ['calibration', 'heldout'],
              'limitations': ['Hash-bound declarations do not authenticate physical devices or reviewer identity.',
                             'No quality, accuracy, schedule benefit or coverage sufficiency is measured by this export.',
                             'Historical timestamps are preserved; offline validation grants no live freshness.',
                             'Task/episode grouping depends on correct source identities and reviewer episode assignment.',
                             'Exact and permutation-equivalent inputs are grouped; near-duplicate and temporal generalization remain unproven.',
                             'Calibration and heldout are reserved; do not use them for fitting or model selection.']}
    # Validate everything and audit every row before creating any output. x/mkdir
    # enforce no-overwrite even if another process races this final step.
    output.mkdir(parents=True, exist_ok=False)
    files = {}
    for split in SPLITS:
        name = f'{split}.jsonl' if audited else f'pending_{split}.jsonl'
        files[split] = _write_jsonl(output / name, rows[split])
    files['sources'] = _write_jsonl(output / 'sources.jsonl', sources)
    report['files'] = files
    with (output / 'dataset_report.json').open('x', encoding='utf-8', newline='\n') as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write('\n')
    return report


def _write_jsonl(path, rows):
    checksum = hashlib.sha256()
    with path.open('xb') as handle:
        for row in rows:
            data = (json.dumps(row, ensure_ascii=False, sort_keys=True, allow_nan=False, separators=(',', ':')) + '\n').encode('utf-8')
            handle.write(data)
            checksum.update(data)
    return {'path': path.name, 'rows': len(rows), 'sha256': checksum.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('template', 'export'):
        command = commands.add_parser(name)
        command.add_argument('--records', type=Path, required=True)
        command.add_argument('--out', type=Path, required=True)
        if name == 'export':
            command.add_argument('--labels', type=Path, required=True)
            command.add_argument('--tokenizer', type=Path, help='Existing local tokenizer only; optional, never downloads weights')
            command.add_argument('--seed', default='4070')
    args = parser.parse_args()
    try:
        result = (prepare_review_template(args.records, args.out) if args.command == 'template' else
                  export_reviewed_v4(args.records, args.labels, args.out, tokenizer_dir=args.tokenizer, seed=args.seed))
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, OSError, RuntimeError, ImportError) as exc:
        parser.exit(1, f'Mifu v4 export: {exc}\n')


if __name__ == '__main__':
    main()
