"""Frozen, synthetic, zero-update paired probes. Generation needs stdlib only.

This is NOT an online projection, trainer, calibration run or acceptance gate.
Only evaluate imports the model stack. Every output directory must be new.
"""
from __future__ import annotations

import argparse
import copy
import gc
import hashlib
import json
import math
from pathlib import Path
import random
import re
import time
import traceback


SEED = 2026111307
SCHEMA = 'mifu-v4-paired-diagnostic-v1'
PROJECTION = 'mifu-v4-diagnostic-criteria-seconds-zpad7-v1'
MODELS = {
    'H': 'a06c061af7552675d46179f9a8b1c8ad9168bc215491d5345f575eb739b7cfe4',
    'final512': '5160610c9874a59354c869fdc1fb0058e1593a3ff98eb463c35ca1cd3e9f2df7',
}
VARIANTS = {
    'A': 'common run; plate run null; canonical slots',
    'B': 'variable run and compensating wait; same finish/prep; plate run null',
    'C': 'A with truthful common plate run only',
    'D': 'B with criteria seconds text zero-padded to 7 digits only',
    'E': 'A with SDK option slots reversed only',
    'F': 'B with SDK option slots reversed only',
    'G': 'A with physical candidate order reversed and labels rebuilt',
    'H': 'B with physical candidate order reversed and labels rebuilt',
}
PAIRS = (('A', 'B'), ('A', 'C'), ('B', 'D'), ('A', 'E'),
         ('B', 'F'), ('A', 'G'), ('B', 'H'))


def plan():
    return {'schema': SCHEMA, 'seed': SEED, 'source': 'synthetic_pipeline_only',
            'candidateCounts': [2, 4, 8, 16],
            'gapBoundsSeconds': {'small': [1, 30], 'large': [600, 3600]},
            'casesPerCountGap': 4, 'independentBaseCases': 32,
            'variants': dict(VARIANTS), 'diagnosticProjection': PROJECTION,
            'models': dict(MODELS), 'precision': 'bf16', 'parallelOptions': True,
            'maxLen': 2048, 'headMaxLen': 1024, 'maxForwardCalls': 512,
            'deadlineSeconds': 1200, 'trainingUpdates': 0,
            'deployable': False, 'automaticExecutionAuthorized': False,
            'selectionPolicy': 'No tuning, checkpoint selection or budget extension from outcomes.'}


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False,
                      separators=(',', ':'), allow_nan=False).encode('utf-8')


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def _file_digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def _write_new(path, value):
    with Path(path).open('xb') as handle:
        handle.write(canonical(value) + b'\n')


def _append_evidence(path, value):
    """Keep each finished observation readable even after an external watchdog kill."""
    import os
    with Path(path).open('ab') as handle:
        handle.write(canonical(value) + b'\n')
        handle.flush()
        os.fsync(handle.fileno())


def _pipeline_hashes():
    folder = Path(__file__).resolve().parent
    return {name: _file_digest(folder / name) for name in
            ('decision_contract.py', 'audit_token_budget.py',
             'diagnose_learning.py', 'evaluate_compact_model.py')}


def require_separate_output(destination, bundle, specifications):
    output = Path(destination).resolve()
    protected = [Path(bundle).resolve(),
                 *(Path(spec['path']).resolve() for spec in specifications.values())]
    if any(output == root or root in output.parents or output in root.parents for root in protected):
        raise ValueError('Output must be separate from frozen bundle and every checkpoint')


def costs(request):
    return {candidate['id']: (
        candidate['features']['available_after_seconds'] +
        candidate['features']['setup_seconds'] + candidate['features']['run_seconds'],
        candidate['features']['setup_seconds']) for candidate in request['candidates']}


def generate_cases():
    """No old split, report, SDK, tokenizer or checkpoint is read."""
    rng = random.Random(SEED)
    cases = []
    for k in (2, 4, 8, 16):
        for band, bounds in plan()['gapBoundsSeconds'].items():
            for index in range(4):
                case_id = f'paired-{SEED}-k{k}-{band}-{index}'
                gap = rng.randint(*bounds)
                first_finish = rng.randint(4000, 60000)
                winner, runner = rng.sample(range(k), 2)
                finishes = [first_finish + (0 if j == winner else gap if j == runner
                                            else gap + rng.randint(1, 7200)) for j in range(k)]
                setups = [rng.randint(0, min(1800, finish // 4)) for finish in finishes]
                common_run = rng.randint(300, min(f - s for f, s in zip(finishes, setups)) - 1)
                variable_runs = [rng.randint(300, f - s) for f, s in zip(finishes, setups)]
                if len(set(variable_runs)) == 1:
                    variable_runs[-1] = 301 if variable_runs[-1] == 300 else 300
                remaining = rng.randint(1, 12)
                candidates = []
                for j in range(k):
                    candidates.append({
                        'id': f'unit-{j:02d}',
                        'admission': {'status': 'synthetic_declared_eligible',
                                      'version': SCHEMA, 'snapshot_id': case_id,
                                      'observed_at_epoch_s': 0},
                        'features': {'available_after_seconds': finishes[j] - setups[j] - common_run,
                                     'setup_seconds': setups[j], 'run_seconds': common_run,
                                     'max_runs': remaining, 'queued_runs': rng.randint(0, 4)}})
                rng.shuffle(candidates)
                request = {'requestId': case_id,
                           'decision_context': {'schema': 'mifu-decision-v4',
                                                'source': 'synthetic_pipeline_only',
                                                'objective': 'earliest_known_finish',
                                                'snapshot_id': case_id, 'gate_version': SCHEMA,
                                                'observed_at_epoch_s': 0, 'max_age_seconds': 120},
                           'plate': {'id': case_id, 'estimated_seconds': None,
                                     'remaining_runs': remaining}, 'candidates': candidates}
                variable = copy.deepcopy(request)
                for candidate in variable['candidates']:
                    j = int(candidate['id'].split('-')[1])
                    candidate['features']['run_seconds'] = variable_runs[j]
                    candidate['features']['available_after_seconds'] = finishes[j] - setups[j] - variable_runs[j]
                truth = costs(request)
                assert truth == costs(variable)
                expected = min(truth, key=truth.get)
                assert expected == f'unit-{winner:02d}'
                assert sorted(truth.values())[1][0] - min(truth.values())[0] == gap
                cases.append({'caseId': case_id, 'source': 'synthetic_pipeline_only',
                              'candidateCount': k, 'gapBand': band, 'gapSeconds': gap,
                              'commonRunSeconds': common_run, 'expectedCandidateId': expected,
                              'commonRequest': request, 'variableRequest': variable})
    rng.shuffle(cases)
    assert len(cases) == 32
    assert len({digest(case['commonRequest']) for case in cases}) == 32
    return cases


def generate_bundle(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    _write_new(destination / 'plan.json', plan())
    cases = generate_cases()
    with (destination / 'cases.jsonl').open('xb') as handle:
        for case in cases:
            handle.write(canonical(case) + b'\n')
    manifest = {'schema': SCHEMA, 'runnerSha256': _file_digest(__file__),
                'pipelineSha256': _pipeline_hashes(),
                'planSha256': _file_digest(destination / 'plan.json'),
                'casesSha256': _file_digest(destination / 'cases.jsonl'),
                'independentBaseCases': len(cases), 'source': 'synthetic_pipeline_only',
                'trainingUpdates': 0, 'deployable': False}
    _write_new(destination / 'manifest.json', manifest)
    return manifest


def read_bundle(bundle):
    bundle = Path(bundle)
    manifest = json.loads((bundle / 'manifest.json').read_text(encoding='utf-8'))
    expected_manifest = {'schema': SCHEMA, 'runnerSha256': _file_digest(__file__),
                         'pipelineSha256': _pipeline_hashes(),
                         'planSha256': _file_digest(bundle / 'plan.json'),
                         'casesSha256': _file_digest(bundle / 'cases.jsonl'),
                         'independentBaseCases': 32, 'source': 'synthetic_pipeline_only',
                         'trainingUpdates': 0, 'deployable': False}
    if manifest != expected_manifest:
        raise ValueError('Frozen bundle or runner hash does not match')
    frozen_plan = json.loads((bundle / 'plan.json').read_text(encoding='utf-8'))
    if frozen_plan != plan():
        raise ValueError('Plan differs from the fixed zero-update experiment')
    with (bundle / 'cases.jsonl').open(encoding='utf-8') as handle:
        cases = [json.loads(line) for line in handle]
    if cases != generate_cases():
        raise ValueError('Cases differ from the fixed fresh-seed generator')
    return frozen_plan, cases, manifest


def _reject_model_labels(value):
    forbidden = {'expected', 'expected_candidate_id', 'gold', 'oracle', 'oracle_rank',
                 'winner', 'rank', 'target', 'outcome', 'reward', 'selected_candidate_id'}
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = re.sub(r'(?<!^)(?=[A-Z])', '_', str(key)).lower()
            if normalized in forbidden:
                raise ValueError('Label leaked into model input')
            _reject_model_labels(child)
    elif isinstance(value, list):
        for child in value:
            _reject_model_labels(child)


def prepare_variant(case, variant):
    from decision_contract import normalize_request

    if variant not in VARIANTS:
        raise ValueError('Unknown paired variant')
    request = copy.deepcopy(case['variableRequest' if variant in 'BDFH' else 'commonRequest'])
    if variant == 'C':
        request['plate']['estimated_seconds'] = case['commonRunSeconds']
    if variant in 'GH':
        request['candidates'].reverse()
    prepared = normalize_request(request, now_epoch_s=0)
    if variant == 'D':
        criteria = prepared['questions']['printer']['criteria']
        for label, text in criteria.items():
            criteria[label] = re.sub(r'\b(wait|prep|finish) ([0-9]+)s',
                                     lambda match: f'{match[1]} {int(match[2]):07d}s', text)
    model_input = {'state': prepared['state'], 'questions': prepared['questions']}
    _reject_model_labels(model_input)
    labels = list(prepared['mapping'])
    order = list(reversed(range(len(labels)))) if variant in 'EF' else list(range(len(labels)))
    return {'variant': variant, 'modelInput': model_input, 'mapping': prepared['mapping'],
            'slotOrder': order, 'slotLabels': [labels[i] for i in order],
            'slotPhysicalIds': [prepared['mapping'][labels[i]] for i in order],
            'inputSha256': digest(model_input),
            'projection': PROJECTION if variant == 'D' else 'mifu-decision-v4'}


def encode_label_independent(prepared, tokenizer, sdk):
    """Targets exist only to satisfy SDK item construction and are discarded.

    Neither dummy target is the sidecar oracle. Changing it must leave ALL
    encoded model fields identical, including option layout and marker order.
    """
    labels = list(prepared['mapping'])
    encodings = []
    for dummy_label in (labels[0], labels[-1]):
        row = copy.deepcopy(prepared['modelInput'])
        row['expected'] = {'printer': dummy_label}
        items, skipped = sdk.items_from_rows(tokenizer, [row], 2048, 1024)
        if len(items) != 1 or items[0]['k'] != len(labels):
            raise ValueError(f'SDK dropped or changed options: {skipped}')
        encoded = sdk.encode_item(tokenizer, items[0], 2048, 1024, prepared['slotOrder'], True)
        encodings.append({key: value for key, value in encoded.items() if key != 'target'})
    if encodings[0] != encodings[1]:
        raise ValueError('Changing a sidecar target changed model encoding')
    if 'target' in encodings[0] or 'label' in encodings[0]:
        raise ValueError('Target must not reach inference collation')
    return encodings[0]


def outcome(case, prepared, logits):
    if len(logits) != case['candidateCount'] or any(
            isinstance(value, bool) or not isinstance(value, (int, float)) or
            not math.isfinite(value) for value in logits):
        raise ValueError('Invalid or nonfinite logits')
    slot = max(range(len(logits)), key=logits.__getitem__)
    selected = prepared['slotPhysicalIds'][slot]
    truth = costs(case['commonRequest'])
    ordered = sorted(logits, reverse=True)
    shortcut_cost = {c['id']: c['features']['available_after_seconds'] + c['features']['setup_seconds']
                     for c in case['variableRequest' if prepared['variant'] in 'BDFH' else 'commonRequest']['candidates']}
    return {'caseId': case['caseId'], 'candidateCount': case['candidateCount'],
            'gapBand': case['gapBand'], 'gapSeconds': case['gapSeconds'],
            'variant': prepared['variant'], 'projection': prepared['projection'],
            'inputSha256': prepared['inputSha256'], 'labelPhysicalMapping': prepared['mapping'],
            'slotOrder': prepared['slotOrder'], 'slotLabels': prepared['slotLabels'],
            'slotPhysicalIds': prepared['slotPhysicalIds'], 'rawLogitsBySlot': list(logits),
            'rawLogitsByPhysicalId': dict(zip(prepared['slotPhysicalIds'], logits)),
            'topTwoMargin': ordered[0] - ordered[1], 'selectedPhysicalId': selected,
            'expectedPhysicalId': case['expectedCandidateId'],
            'correct': truth[selected] == min(truth.values()),
            'regretSeconds': truth[selected][0] - min(truth.values())[0],
            'minWaitPrepAgreement': shortcut_cost[selected] == min(shortcut_cost.values())}


def summarize(rows):
    if not rows:
        return {'n': 0}
    return {'n': len(rows), 'correct': sum(r['correct'] for r in rows),
            'accuracy': sum(r['correct'] for r in rows) / len(rows),
            'meanRegretSeconds': sum(r['regretSeconds'] for r in rows) / len(rows),
            'maxRegretSeconds': max(r['regretSeconds'] for r in rows),
            'minWaitPrepAgreement': sum(r['minWaitPrepAgreement'] for r in rows) / len(rows),
            'meanTopTwoMargin': sum(r['topTwoMargin'] for r in rows) / len(rows)}


def grouped(rows, measure=summarize):
    return {'overall': measure(rows),
            'candidateCount': {str(k): measure([r for r in rows if r['candidateCount'] == k]) for k in (2, 4, 8, 16)},
            'gapBand': {band: measure([r for r in rows if r['gapBand'] == band]) for band in ('small', 'large')},
            'countGap': {f'{k}/{band}': measure([r for r in rows if r['candidateCount'] == k and r['gapBand'] == band])
                         for k in (2, 4, 8, 16) for band in ('small', 'large')}}


def paired_metrics(left, right):
    matches = {r['caseId']: r for r in right}
    pairs = []
    for first in left:
        second = matches.get(first['caseId'])
        if second is not None:
            pairs.append({'caseId': first['caseId'], 'candidateCount': first['candidateCount'],
                          'gapBand': first['gapBand'],
                          'same': first['selectedPhysicalId'] == second['selectedPhysicalId'],
                          'correctToWrong': first['correct'] and not second['correct'],
                          'wrongToCorrect': not first['correct'] and second['correct'],
                          'regretDeltaSeconds': second['regretSeconds'] - first['regretSeconds']})
    def summary(values):
        if not values:
            return {'n': 0}
        return {'n': len(values), 'consistent': sum(v['same'] for v in values),
                'consistency': sum(v['same'] for v in values) / len(values),
                'correctToWrong': sum(v['correctToWrong'] for v in values),
                'wrongToCorrect': sum(v['wrongToCorrect'] for v in values),
                'meanRegretDeltaSeconds': sum(v['regretDeltaSeconds'] for v in values) / len(values)}
    return grouped(pairs, summary)


def metrics(rows):
    by_model = {}
    for model in MODELS:
        variants = {v: [r for r in rows if r['model'] == model and r['variant'] == v] for v in VARIANTS}
        by_model[model] = {'variants': {v: grouped(items) for v, items in variants.items()},
                           'paired': {f'{a}:{b}': paired_metrics(variants[a], variants[b]) for a, b in PAIRS}}
    return {'byModel': by_model,
            'betweenModels': {v: paired_metrics([r for r in rows if r['model'] == 'H' and r['variant'] == v],
                                                [r for r in rows if r['model'] == 'final512' and r['variant'] == v])
                              for v in VARIANTS}}


def _inventory(checkpoint):
    from evaluate_compact_model import checkpoint_artifact_hashes
    return checkpoint_artifact_hashes(checkpoint)


def _expected_inventory(path):
    if path is None:
        return None
    value = json.loads(Path(path).read_text(encoding='utf-8'))
    return value.get('artifactsSha256', value)


def lock_checkpoints(specifications):
    if set(specifications) != set(MODELS):
        raise ValueError('Exactly the frozen H and final512 checkpoints are required')
    locked = {}
    for name, expected_weight in MODELS.items():
        spec = specifications[name]
        if spec['sha256'] != expected_weight:
            raise ValueError(f'{name}: requested weight differs from frozen plan')
        actual = _inventory(spec['path'])
        required = {'model.safetensors', 'rl_agent_config.json', 'encoder/config.json'}
        if not required <= actual.keys() or not any(k.startswith('tokenizer/') for k in actual):
            raise ValueError(f'{name}: incomplete inference artifact inventory')
        if actual['model.safetensors'] != expected_weight:
            raise ValueError(f'{name}: weight hash does not match')
        external = _expected_inventory(spec.get('artifacts'))
        if external is not None and external != actual:
            raise ValueError(f'{name}: complete artifact lock does not match')
        locked[name] = actual
    for name in ('encoder/config.json', 'tokenizer/tokenizer.json'):
        if locked['H'].get(name) != locked['final512'].get(name):
            raise ValueError(f'Checkpoint architecture/tokenizer differs: {name}')
    return locked


def check_deadline(deadline):
    if time.monotonic() >= deadline:
        raise TimeoutError('Fixed 1200-second diagnostic budget exhausted; no extension')


class _GpuEngine:
    def __init__(self, checkpoint, deadline):
        import importlib.metadata
        import os
        os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
                          HF_HUB_DISABLE_TELEMETRY='1', TOKENIZERS_PARALLELISM='false')
        import torch
        from laya import train as sdk
        from laya.common import collate_items
        from audit_token_budget import inspect_question
        from evaluate_compact_model import load_checkpoint_readonly
        from diagnose_learning import forward
        if importlib.metadata.version('laya') != '0.4.31' or not torch.cuda.is_available():
            raise RuntimeError('Pinned Laya 0.4.31 and CUDA are required; no CPU fallback')
        check_deadline(deadline)
        torch.manual_seed(SEED)
        torch.set_float32_matmul_precision('highest')
        torch.backends.cuda.matmul.allow_tf32 = False
        cfg = json.loads((Path(checkpoint) / 'rl_agent_config.json').read_text(encoding='utf-8'))
        if cfg.get('max_len') != 2048 or cfg.get('head_max_len') != 1024:
            raise ValueError('Checkpoint token budgets differ from frozen plan')
        self.model, self.tokenizer = load_checkpoint_readonly(Path(checkpoint), cfg, sdk)
        self.torch, self.sdk, self.collate = torch, sdk, collate_items
        self.inspect, self.forward = inspect_question, forward
        self.device = torch.device('cuda')
        self.model.requires_grad_(False).to(self.device).eval()
        self.observed = []
        self.forward_calls = 0
        self.runtime = {'gpu': torch.cuda.get_device_name(0), 'precision': 'bf16',
                        'agentConfig': cfg,
                        'modelParameterDtype': str(next(self.model.parameters()).dtype),
                        'parallelOptions': True, 'allowTF32': False,
                        'matmulPrecision': torch.get_float32_matmul_precision(),
                        'packages': {p: importlib.metadata.version(p) for p in ('laya', 'torch', 'transformers', 'tokenizers')}}
        def pre_hook(_module, inputs, kwargs):
            self.forward_calls += 1
            callback = getattr(self, 'on_forward', None)
            if callback is not None:
                callback(self.forward_calls)
            observation = {'device': str(inputs[0].device), 'gradEnabled': torch.is_grad_enabled(),
                           'autocastEnabled': torch.is_autocast_enabled('cuda'),
                           'computeDtype': str(torch.get_autocast_dtype('cuda')),
                           'parallelIds': 'option_ids' in kwargs and 'position_ids' in kwargs}
            if (not observation['device'].startswith('cuda') or observation['gradEnabled'] or
                    not observation['autocastEnabled'] or observation['computeDtype'] != 'torch.bfloat16' or
                    not observation['parallelIds']):
                raise RuntimeError('Observed forward differs from frozen BF16/no-grad GPU profile')
            self.observed.append(observation)
        self.hook = self.model.register_forward_pre_hook(pre_hook, with_kwargs=True)
        def post_hook(_module, _inputs, output):
            self.observed[-1]['rawLogitsDtype'] = str(output[0].dtype)
        self.post_hook = self.model.register_forward_hook(post_hook)

    def predict(self, prepared, deadline):
        check_deadline(deadline)
        model_input = prepared['modelInput']
        audit = self.inspect(self.tokenizer, model_input['state'], model_input['questions']['printer'], 2048, 1024)
        if audit['errors']:
            raise ValueError(f'Token audit failed: {audit}')
        encoded = encode_label_independent(prepared, self.tokenizer, self.sdk)
        encoding_hash = digest(encoded)
        batch = self.collate([[encoded]], self.tokenizer.pad_token_id)
        if 'target' in batch:
            raise ValueError('Targets reached inference batch')
        before = len(self.observed)
        with self.torch.inference_mode():
            tensor = self.forward(self.model, batch, self.device, 'bf16', True)
        if len(self.observed) != before + 1:
            raise RuntimeError('Expected exactly one model forward per variant')
        logits = tensor[0, :len(prepared['slotOrder'])].detach().cpu().tolist()
        check_deadline(deadline)
        return {'logits': logits, 'encodingSha256': encoding_hash,
                'tokenAudit': {'status': 'passed', **audit},
                'sidecarLabelEncodingInvariant': True,
                'forward': {**self.observed[-1], 'returnedLogitsDtype': str(tensor.dtype)}}

    def close(self):
        self.hook.remove()
        self.post_hook.remove()
        del self.model
        del self.tokenizer
        gc.collect()
        self.torch.cuda.empty_cache()


def evaluate_bundle(bundle, destination, specifications, *, engine_factory=None):
    """The injectable engine is for CPU-only tests; CLI always uses _GpuEngine."""
    destination = Path(destination)
    require_separate_output(destination, bundle, specifications)
    destination.mkdir(parents=True, exist_ok=False)
    for filename in ('results.jsonl', 'progress.jsonl'):
        with (destination / filename).open('xb'):
            pass
    started = time.monotonic()
    deadline = started + plan()['deadlineSeconds']
    report = {'schema': SCHEMA, 'status': 'failed', 'source': 'synthetic_pipeline_only',
              'purpose': 'paired_zero_update_diagnostic', 'deployable': False,
              'trainingUpdates': 0, 'realObservations': 0, 'automaticExecutionAuthorized': False,
              'results': [], 'runtime': {}, 'checkpointArtifactsBefore': {},
              'independentBaseCases': 32, 'modelForwardCalls': 0,
              'limitations': [
                  'Only 32 independent synthetic base cases; variants are correlated probes, not acceptance samples.',
                  'Run is not a candidate model token: A/B changes wait while finish and prep stay fixed.',
                  'G/H combines label reassignment and state order; it is not pure option-slot permutation.',
                  'A is a controlled common-run probe, not the complete original H distribution or proof of forgetting.',
                  'Digit padding is an experimental criteria-only projection, never the online v4 contract.',
                  'The execution host must enforce the hard 1200-second deadline with an external process watchdog.',
                  'No training, calibration, threshold refit, production readiness or real printing claim.']}
    locked = {}
    try:
        frozen_plan, cases, manifest = read_bundle(bundle)
        report.update(plan=frozen_plan, bundleManifest=manifest)
        locked = lock_checkpoints(specifications)
        report['checkpointArtifactsBefore'] = locked
        report['externalArtifactLocksUsed'] = {name: bool(specifications[name].get('artifacts')) for name in MODELS}
        _write_new(destination / 'run_lock.json', {'plan': frozen_plan, 'bundleManifest': manifest,
                                                  'checkpointArtifactsBefore': locked,
                                                  'externalArtifactLocksUsed': report['externalArtifactLocksUsed']})
        check_deadline(deadline)
        factory = engine_factory or _GpuEngine
        baseline_encodings = {}
        for name in MODELS:
            check_deadline(deadline)
            path = specifications[name]['path']
            if _inventory(path) != locked[name]:
                raise ValueError(f'{name}: artifacts changed before loading')
            print(json.dumps({'stage': 'load', 'model': name}), flush=True)
            _append_evidence(destination / 'progress.jsonl', {'stage': 'load_started', 'model': name,
                                                            'elapsedSeconds': time.monotonic() - started})
            engine = factory(path, deadline)
            try:
                engine.on_forward = lambda count, model=name: _append_evidence(
                    destination / 'progress.jsonl', {'stage': 'model_forward_started', 'model': model,
                                                     'modelForwardOrdinal': count})
                if _inventory(path) != locked[name]:
                    raise ValueError(f'{name}: loader modified checkpoint')
                report['runtime'][name] = engine.runtime
                for index, case in enumerate(cases):
                    for variant in VARIANTS:
                        check_deadline(deadline)
                        if report['modelForwardCalls'] + engine.forward_calls >= 512:
                            raise RuntimeError('Forward budget exhausted')
                        prepared = prepare_variant(case, variant)
                        _append_evidence(destination / 'progress.jsonl', {'stage': 'variant_started', 'model': name,
                                                                        'caseId': case['caseId'], 'variant': variant})
                        measured = engine.predict(prepared, deadline)
                        row = outcome(case, prepared, measured.pop('logits'))
                        row.update(model=name, **measured)
                        report['results'].append(row)
                        _append_evidence(destination / 'results.jsonl', row)
                        key = (case['caseId'], variant)
                        if name == 'H':
                            baseline_encodings[key] = row['encodingSha256']
                        elif row['encodingSha256'] != baseline_encodings[key]:
                            raise ValueError('Model comparison changed encoded input; tokenizer/config confound')
                    print(json.dumps({'stage': 'progress', 'model': name, 'baseCases': index + 1,
                                      'forwardCalls': report['modelForwardCalls'] + engine.forward_calls}), flush=True)
            finally:
                report['modelForwardCalls'] += engine.forward_calls
                engine.close()
            if _inventory(path) != locked[name]:
                raise ValueError(f'{name}: inference artifacts changed')
            print(json.dumps({'stage': 'released', 'model': name}), flush=True)
            _append_evidence(destination / 'progress.jsonl', {'stage': 'released', 'model': name})
        if len(report['results']) != 512 or report['modelForwardCalls'] != 512:
            raise RuntimeError('Incomplete diagnostic forward count')
        report['status'] = 'completed_diagnostic_only'
        report['pairedModelEncodingsIdentical'] = True
    except Exception as error:
        report['error'] = {'type': type(error).__name__, 'message': str(error),
                           'traceback': traceback.format_exc()}
    finally:
        after = {}
        try:
            after = {name: _inventory(specifications[name]['path']) for name in locked}
            if after != locked:
                raise ValueError('Checkpoint artifacts changed during diagnostic')
        except Exception as error:
            report['status'] = 'failed'
            report['artifactError'] = str(error)
        report['checkpointArtifactsAfter'] = after
        report['checkpointArtifactsUnchanged'] = bool(locked) and after == locked
        report['forwardCalls'] = report['modelForwardCalls']
        report['sampleForwardCalls'] = report['modelForwardCalls']
        report['completedPredictions'] = len(report['results'])
        report['metrics'] = metrics(report['results'])
        report['elapsedSeconds'] = time.monotonic() - started
        _write_new(destination / 'report.json', report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    generate = sub.add_parser('generate-only', help='stdlib-only; no checkpoint or GPU access')
    generate.add_argument('--out', type=Path, required=True)
    evaluate = sub.add_parser('evaluate', help='frozen bundle, two sequential BF16 models, zero updates')
    evaluate.add_argument('--bundle', type=Path, required=True)
    evaluate.add_argument('--out', type=Path, required=True)
    for model in ('h', 'final'):
        evaluate.add_argument(f'--{model}-checkpoint', type=Path, required=True)
        evaluate.add_argument(f'--{model}-sha256', required=True)
        evaluate.add_argument(f'--{model}-artifacts', type=Path,
                              help='Optional exact complete artifact hash JSON, or artifactsSha256 envelope')
    args = parser.parse_args()
    if args.command == 'generate-only':
        print(json.dumps(generate_bundle(args.out)), flush=True)
        return
    specs = {'H': {'path': args.h_checkpoint, 'sha256': args.h_sha256, 'artifacts': args.h_artifacts},
             'final512': {'path': args.final_checkpoint, 'sha256': args.final_sha256,
                          'artifacts': args.final_artifacts}}
    report = evaluate_bundle(args.bundle, args.out, specs)
    print(json.dumps({'status': report['status'], 'forwardCalls': report['forwardCalls'],
                      'error': report.get('error')}), flush=True)
    if report['status'] != 'completed_diagnostic_only':
        raise SystemExit(2)


if __name__ == '__main__':
    main()
