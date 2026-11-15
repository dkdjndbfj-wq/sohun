"""Offline, staged numeric-adapter experiment. Never starts a service or deploys.

dry-run imports no torch and writes nothing. prepare writes only train/validation.
cache reads the frozen H on CUDA; train learns adapters on CPU from frozen logits.
evaluate creates a fresh holdout only after both validation-selected adapters are
hash-locked. Synthetic exact labels/baselines are not claimed as Laya predictions.
"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import json
import math
from pathlib import Path
import random
import sys
import time

SCENARIOS = ('gap1', 'gap2', 'gap30', 'largegap', 'primarytie', 'allties', 'oppositewait', 'boundary')
COUNTS = (2, 4, 8, 16)
BASE_HASH = 'a06c061af7552675d46179f9a8b1c8ad9168bc215491d5345f575eb739b7cfe4'
PLAN = {'schema': 'mifu-numeric-adapter-experiment-v1', 'source': 'synthetic_pipeline_only',
        'experimentId': 'numeric-adapter-20261113-v1', 'trainEpisodes': 4096,
        'validationEpisodes': 512, 'holdoutEpisodes': 4096, 'variantsPerEpisode': 2,
        'candidateCounts': list(COUNTS), 'scenarios': list(SCENARIOS),
        'scenarioFractions': {s: 1 / 8 for s in SCENARIOS},
        'seed': 202611135701, 'optimizerUpdates': 2048, 'pairsPerUpdate': 256,
        'learningRate': .003, 'validateEvery': 128, 'numericPrecision': 'float64',
        'layaPrecision': 'fp32', 'layaBatchSize': 4, 'physicalPermutationProbeEpisodes': 256,
        'baseWeightsSha256': BASE_HASH, 'selection': 'best validation nondegenerate accuracy; first wins ties',
        'holdoutPolicy': 'generate only after validation-selected adapter files are frozen',
        'sourceMeaning': 'simulated exact numeric objective, not operational printer outcomes',
        'deployable': False}
PIPELINE_FILES = ('train_numeric_adapter.py', 'mifu_numeric_ranker.py', 'decision_contract.py',
                  'audit_token_budget.py', 'evaluate_compact_model.py', 'diagnose_learning.py')


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write(path, value):
    with Path(path).open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')


def rows(path):
    with Path(path).open(encoding='utf-8') as stream:
        return [json.loads(line) for line in stream if line.strip()]


def write_rows(path, values):
    with Path(path).open('x', encoding='utf-8') as stream:
        for value in values:
            stream.write(json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False) + '\n')


def file_specs(directory, names):
    return {name: sha(directory / name) for name in names}


def verify_files(directory, specs):
    if file_specs(directory, specs) != specs:
        raise ValueError('Frozen file hash mismatch')


def pipeline_fingerprint():
    return file_specs(Path(__file__).resolve().parent, PIPELINE_FILES)


def runtime_fingerprint():
    """Versions and actual installed Laya sources, without importing its model."""
    import importlib.metadata as metadata
    packages = ('laya', 'torch', 'transformers', 'tokenizers', 'safetensors', 'huggingface-hub')
    versions = {name: metadata.version(name) for name in packages}
    dist = metadata.distribution('laya')
    sources = {name: sha(dist.locate_file(name)) for name in ('laya/train.py', 'laya/common.py')}
    return {'python': sys.version, 'packages': versions, 'layaSources': sources}


def verify_pipeline(record):
    if record.get('pipelineSha256') != pipeline_fingerprint():
        raise ValueError('Pipeline source changed; cached projections/selected artifacts cannot be reused')


def verify_cache(output, cached, *, check_runtime=True):
    verify_pipeline(cached)
    verify_files(output, cached['files'])
    if cached['preparedSha256'] != sha(output / 'prepared.json'):
        raise ValueError('Cache dataset mismatch')
    if check_runtime and cached.get('runtimeFingerprint') != runtime_fingerprint():
        raise ValueError('Cache runtime/SDK changed')


def costs(request):
    return {c['id']: (sum(c['features'][key] for key in
                         ('available_after_seconds', 'setup_seconds', 'run_seconds')),
                      c['features']['setup_seconds']) for c in request['candidates']}


def semantic(request):
    return digest(sorted((c['features'] for c in request['candidates']), key=lambda x: json.dumps(x, sort_keys=True)))


def episode_signatures(request):
    # Prevent the same objective values leaking across splits even when wait/run
    # decomposition or arbitrary physical IDs change.
    return {'features:' + semantic(request), 'costs:' + digest(sorted(costs(request).values()))}


def numeric_geometry(request):
    """Model-input equivalence under order, IDs, decomposition and common shifts."""
    values = list(costs(request).values())
    first, second = min(v[0] for v in values), min(v[1] for v in values)
    return digest(sorted((a - first, b - second) for a, b in values))


def geometry_overlap(reference, evaluated):
    known = {numeric_geometry(e['variants'][0]) for e in reference}
    overlaps = [e for e in evaluated if numeric_geometry(e['variants'][0]) in known]
    return {'evaluatedBaseEpisodes': len(evaluated), 'overlappingBaseEpisodes': len(overlaps),
            'uniqueEvaluatedGeometries': len({numeric_geometry(e['variants'][0]) for e in evaluated}),
            'byCountScenario': dict(Counter(f"{e['candidateCount']}/{e['scenario']}" for e in overlaps)),
            'meaning': 'input-equivalent numeric difference geometry; episodes are not all novel feature inputs'}


def generate(split, count, plan=PLAN, occupied=None):
    """Independent base episodes; both decomposition variants remain together."""
    if count < 32 or count % 32 or split not in ('train', 'validation', 'holdout'):
        raise ValueError('Each split needs a multiple of 32 base episodes')
    occupied = set() if occupied is None else occupied
    rng = random.Random(f"{plan['seed']}:{split}")
    from decision_contract import normalize_request
    result = []
    for k in COUNTS:
        for scene in SCENARIOS:
            for index in range(count // 32):
                episode = f"{plan['experimentId']}:{split}:{k}:{scene}:{index}"
                while True:
                    best = rng.randint(1000, 180000)
                    if scene == 'boundary':
                        best = rng.randint(7_900_000, 8_000_000)
                    gap = {'gap1': 1, 'gap2': 2, 'gap30': 30, 'boundary': 1}.get(scene, rng.randint(300, 30000))
                    targets = [(best + (0 if j == 0 else gap if j == 1 else gap + rng.randint(1, 30000)),
                                rng.randint(0, 900)) for j in range(k)]
                    if scene == 'primarytie':
                        targets[0] = (best, rng.randint(0, 300))
                        targets[1] = (best, targets[0][1] + rng.randint(1, 30))
                    if scene == 'allties':
                        targets = [(best, targets[0][1])] * k
                    variants = []
                    for variant in range(2):
                        candidates = []
                        for j, (finish, setup) in enumerate(targets):
                            if scene == 'boundary':
                                setup = 2_677_000 + setup
                                finish = targets[j][0]
                                # Every component stays within the 31-day contract maximum.
                                lo = max(1, finish - setup - 2_678_400)
                                hi = min(2_678_400, finish - setup)
                            else:
                                lo, hi = 1, finish - setup
                            run = rng.randint(lo, hi)
                            if scene == 'oppositewait':
                                run = 1 if j == 0 else finish - setup
                                if variant:
                                    run = max(1, (finish - setup) // (3 if j == 0 else 1))
                            candidates.append({'id': f'unit-{j:02d}',
                                'admission': {'status': 'synthetic_declared_eligible', 'version': 'synthetic-numeric-v1',
                                              'snapshot_id': episode, 'observed_at_epoch_s': 0},
                                'features': {'available_after_seconds': finish - setup - run,
                                             'setup_seconds': setup, 'run_seconds': run, 'max_runs': 1, 'queued_runs': None}})
                        rng.shuffle(candidates)
                        variants.append({'requestId': episode + ':' + str(variant),
                            'decision_context': {'schema': 'mifu-decision-v4', 'source': 'synthetic_pipeline_only',
                                'objective': 'earliest_known_finish', 'snapshot_id': episode,
                                'gate_version': 'synthetic-numeric-v1', 'observed_at_epoch_s': 0, 'max_age_seconds': 120},
                            'plate': {'id': 'plate-' + episode, 'estimated_seconds': None, 'remaining_runs': 1},
                            'candidates': candidates})
                    for req in variants:
                        normalize_request(req, now_epoch_s=0)
                    signatures = set().union(*(episode_signatures(req) for req in variants))
                    if not signatures & occupied:
                        occupied.update(signatures)
                        break
                assert costs(variants[0]) == costs(variants[1])
                result.append({'episodeId': episode, 'split': split, 'scenario': scene, 'candidateCount': k,
                               'source': 'synthetic_pipeline_only', 'variants': variants})
    rng.shuffle(result)
    return result


def flat(episodes):
    return [(e, v, req) for e in episodes for v, req in enumerate(e['variants'])]


def key(episode, variant):
    return episode['episodeId'] + '/variant-' + str(variant)


def prepare(output, plan=PLAN):
    if output.exists():
        raise FileExistsError(output)
    output.mkdir(parents=True)
    write(output / 'plan.json', plan)
    occupied = set()
    training = generate('train', plan['trainEpisodes'], plan, occupied)
    validation = generate('validation', plan['validationEpisodes'], plan, occupied)
    for split, values in (('train', training), ('validation', validation)):
        write_rows(output / (split + '.jsonl'), values)
    manifest = {'source': 'synthetic_pipeline_only', 'operationalRecords': 0,
                'pipelineSha256': pipeline_fingerprint(),
                'files': file_specs(output, ('plan.json', 'train.jsonl', 'validation.jsonl')),
                'baseEpisodes': {'train': len(training), 'validation': len(validation)},
                'modelInputs': {'train': len(flat(training)), 'validation': len(flat(validation))},
                'numericGeometryOverlap': geometry_overlap(training, validation),
                'holdoutGenerated': False, 'deployable': False}
    write(output / 'prepared.json', manifest)
    return manifest


class FrozenLaya:
    """Strict actual CUDA FP32 model forwards; no Agent fallback or training."""
    def __init__(self, checkpoint, plan):
        import os
        os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', TOKENIZERS_PARALLELISM='false')
        import importlib.metadata
        import torch
        from laya import train as sdk
        from evaluate_compact_model import checkpoint_artifact_hashes, load_checkpoint_readonly
        if importlib.metadata.version('laya') != '0.4.31' or not torch.cuda.is_available():
            raise RuntimeError('Pinned SDK 0.4.31 and actual CUDA are required')
        torch.set_float32_matmul_precision('highest')
        torch.backends.cuda.matmul.allow_tf32 = False
        torch.backends.cudnn.allow_tf32 = False
        self.checkpoint, self.plan = Path(checkpoint), plan
        self.inventory = checkpoint_artifact_hashes(self.checkpoint)
        if self.inventory['model.safetensors'] != plan['baseWeightsSha256']:
            raise ValueError('Unexpected H weights')
        cfg = read(self.checkpoint / 'rl_agent_config.json')
        if (cfg.get('max_len'), cfg.get('head_max_len'), cfg.get('option_layout')) != (2048, 1024, 'parallel'):
            raise ValueError('Unexpected input contract/layout')
        self.model, self.tok = load_checkpoint_readonly(self.checkpoint, cfg, sdk)
        self.model.to('cuda').eval()
        self.model.requires_grad_(False)
        if any(p.dtype != torch.float32 for p in self.model.parameters()):
            raise ValueError('Frozen baseline parameters must actually be FP32')
        self.sdk, self.torch = sdk, torch
        self.calls = 0
        self.max_tokens = 0
        def check(_module, inputs):
            if inputs[0].device.type != 'cuda' or torch.is_autocast_enabled('cuda'):
                raise RuntimeError('Expected actual CUDA FP32 without autocast')
            self.calls += 1
        self.hook = self.model.register_forward_pre_hook(check)
        self.verify()

    def verify(self):
        from evaluate_compact_model import checkpoint_artifact_hashes
        if checkpoint_artifact_hashes(self.checkpoint) != self.inventory:
            raise ValueError('Frozen H files changed')

    def predict(self, requests):
        from decision_contract import build_decision_input
        from laya.common import collate_items
        from diagnose_learning import forward
        result = []
        for start in range(0, len(requests), 4):
            chunk = requests[start:start + 4]
            packed = []
            for req in chunk:
                p = build_decision_input(req, tokenizer=self.tok, now_epoch_s=0)
                self.max_tokens = max(self.max_tokens, p['diagnostics']['token_audit']['sequence_tokens'])
                q = self.sdk.to_internal('printer', p['questions']['printer'])
                # Dummy uniform packing target is never passed to the model.
                item, reason = self.sdk.make_item(self.tok, q, [1 / len(p['mapping'])] * len(p['mapping']),
                    self.sdk.encode_state(self.tok, p['state'], 2048), 1024, 2048)
                if item is None:
                    raise ValueError(reason)
                packed.append(self.sdk.encode_item(self.tok, item, 2048, 1024, None, True))
            batch = collate_items([packed], self.tok.pad_token_id)
            with self.torch.no_grad():
                logits = forward(self.model, batch, self.torch.device('cuda'), 'fp32', True).cpu()
            for i, req in enumerate(chunk):
                z = logits[i, :len(req['candidates'])]
                if not self.torch.isfinite(z).all():
                    raise ValueError('Nonfinite baseline logits')
                result.append({c['id']: float(z[j]) for j, c in enumerate(req['candidates'])})
            if start % 512 == 0:
                print(json.dumps({'stage': 'laya_cache', 'done': start + len(chunk), 'total': len(requests)}), flush=True)
        return result

    def evidence(self):
        self.verify()
        return {'checkpointArtifactsSha256': self.inventory, 'device': 'cuda', 'precision': 'fp32',
                'autocastEnabled': False, 'cpuFallback': False, 'forwardCalls': self.calls,
                'allowTF32Matmul': self.torch.backends.cuda.matmul.allow_tf32,
                'allowTF32Cudnn': self.torch.backends.cudnn.allow_tf32,
                'maxSequenceTokens': self.max_tokens, 'allInputAuditsPassed': True,
                'filesUnchanged': True, 'modelWeightsUpdated': False}


def cache(output, checkpoint):
    prepared = read(output / 'prepared.json')
    verify_pipeline(prepared)
    verify_files(output, prepared['files'])
    plan = read(output / 'plan.json')
    if (output / 'cache_report.json').exists():
        existing = read(output / 'cache_report.json')
        verify_cache(output, existing)
        from evaluate_compact_model import checkpoint_artifact_hashes
        if existing['preparedSha256'] != sha(output / 'prepared.json') or existing['runtime']['checkpointArtifactsSha256'] != checkpoint_artifact_hashes(checkpoint):
            raise ValueError('Cache no longer matches frozen inputs/checkpoint')
        return existing
    target = output / 'laya_logits.json'
    if target.exists():
        raise FileExistsError(target)
    runner = FrozenLaya(checkpoint, plan)
    episodes = rows(output / 'train.jsonl') + rows(output / 'validation.jsonl')
    inputs = flat(episodes)
    values = runner.predict([req for _e, _v, req in inputs])
    write(target, {key(e, v): z for (e, v, req), z in zip(inputs, values)})
    report = {'source': 'synthetic_pipeline_only', 'preparedSha256': sha(output / 'prepared.json'),
              'pipelineSha256': pipeline_fingerprint(), 'runtimeFingerprint': runtime_fingerprint(),
              'files': {'laya_logits.json': sha(target)}, 'runtime': runner.evidence(),
              'inputs': len(inputs), 'deployable': False}
    write(output / 'cache_report.json', report)
    return report


def pair_target(a, b):
    return 1.0 if a < b else 0.0 if a > b else .5


def wilson(correct, n):
    if not n:
        return None
    z = 1.959963984540054
    p, d = correct / n, 1 + z * z / n
    center = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return [max(0, center - half), min(1, center + half)]


def summary(values):
    n = len(values)
    correct = sum(v['correct'] for v in values)
    interval = wilson(correct, n)
    return {'n': n, 'correct': correct, 'accuracy': correct / n if n else None,
            'wilson95': interval, 'accuracyAtLeast95': bool(n and correct / n >= .95),
            'wilsonLowerAtLeast95': bool(interval and interval[0] >= .95),
            'coverage': 1.0 if n else None,
            'meanRegretSeconds': sum(v['regretSeconds'] for v in values) / n if n else None,
            'maxRegretSeconds': max((v['regretSeconds'] for v in values), default=None),
            'preparationTieMistakes': sum(v['preparationTieMistake'] for v in values)}


def grouped(values):
    useful = [v for v in values if v['scenario'] != 'allties']
    return {'overall': summary(values), 'nondegenerate': summary(useful),
            'candidateBuckets': {str(k): summary([v for v in values if v['candidateCount'] == k]) for k in COUNTS},
            'nondegenerateCandidateBuckets': {str(k): summary([v for v in useful if v['candidateCount'] == k]) for k in COUNTS},
            'scenarioBuckets': {s: summary([v for v in values if v['scenario'] == s]) for s in SCENARIOS},
            'countScenarioBuckets': {f'{k}/{s}': summary([v for v in values if v['candidateCount'] == k and v['scenario'] == s])
                                    for k in COUNTS for s in SCENARIOS}}


def novel_projection_report(reference, evaluated, details):
    known = {numeric_geometry(e['variants'][0]) for e in reference}
    novel = {e['episodeId'] for e in evaluated if numeric_geometry(e['variants'][0]) not in known}
    model_metrics = {}
    for name, decisions in details.items():
        metrics = grouped([d for d in decisions if d['episodeId'] in novel])
        full = grouped(decisions)
        for section in metrics:
            pairs = [(metrics[section], full[section])] if section in ('overall', 'nondegenerate') else [
                (metrics[section][bucket], full[section][bucket]) for bucket in metrics[section]]
            for subset, population in pairs:
                subset['coverage'] = subset['n'] / population['n'] if population['n'] else None
                subset['fullDistributionN'] = population['n']
        model_metrics[name] = metrics
    return {'overlap': geometry_overlap(reference, evaluated), 'modelMetrics': model_metrics,
            'meaning': 'unseen numeric-difference inputs, not independent real printer outcomes; empty buckets cannot pass'}


def select(model, request, baseline):
    import torch
    from mifu_numeric_ranker import prepare_numeric_request, pair_features, candidate_scores
    ids = [c['id'] for c in request['candidates']]
    if model == 'exact':
        values = costs(request)
        return min(values, key=values.get)
    if model == 'laya':
        return max(ids, key=baseline.__getitem__)
    with torch.no_grad():
        x = pair_features(prepare_numeric_request(request, now_epoch_s=0), device='cpu')
        logits = torch.tensor([baseline[i] for i in ids], dtype=torch.float64)
        scores = candidate_scores(model(x, logits if model.hybrid else None))
    if not torch.isfinite(scores).all():
        raise ValueError('Nonfinite numeric scores')
    return ids[int(scores.argmax())]


def evaluate_choices(model, episodes, baseline):
    results = []
    for e in episodes:
        req = e['variants'][0]
        choice = select(model, req, baseline[key(e, 0)])
        c = costs(req)
        best = min(c.values())
        results.append({'episodeId': e['episodeId'], 'scenario': e['scenario'], 'candidateCount': e['candidateCount'],
                        'selected': choice, 'correct': c[choice] == best,
                        'regretSeconds': c[choice][0] - best[0],
                        'preparationTieMistake': c[choice][0] == best[0] and c[choice][1] != best[1]})
    return grouped(results), results


def tensor_fingerprint(state):
    return {name: hashlib.sha256(str((tuple(value.shape), str(value.dtype))).encode()
                                + value.detach().cpu().contiguous().numpy().tobytes()).hexdigest()
            for name, value in state.items()}


def train(output):
    import torch
    from mifu_numeric_ranker import NumericPairwiseRanker
    prep, cached, plan = read(output / 'prepared.json'), read(output / 'cache_report.json'), read(output / 'plan.json')
    verify_pipeline(prep)
    verify_files(output, prep['files']); verify_cache(output, cached)
    if (output / 'holdout_evaluation').exists():
        raise ValueError('Holdout already exposed; this run cannot select weights again')
    destination = output / 'adapters'
    destination.mkdir(exist_ok=False)
    training, validation = rows(output / 'train.jsonl'), rows(output / 'validation.jsonl')
    baseline = read(output / 'laya_logits.json')
    reports = {}
    for hybrid in (False, True):
        name = 'hybrid' if hybrid else 'numeric_only'
        # Controlled ablation: identical MLP initialization and pair draws.
        torch.manual_seed(plan['seed'])
        rng = random.Random(plan['seed'])
        model = NumericPairwiseRanker(hidden_sizes=(32, 16), hybrid=hybrid, activation='tanh')
        initial = tensor_fingerprint(model.state_dict())
        optimizer = torch.optim.Adam(model.parameters(), lr=plan['learningRate'])
        best, best_state, trace, used, variant_used = -1.0, None, [], set(), set()
        started = time.perf_counter()
        for update in range(1, plan['optimizerUpdates'] + 1):
            xs, ys, ds = [], [], []
            for _ in range(plan['pairsPerUpdate']):
                e = rng.choice(training); variant = rng.randrange(len(e['variants'])); req = e['variants'][variant]
                c = costs(req); a, b = rng.sample(list(c), 2)
                # Integer differences precede any floating conversion; no rank/label in features.
                delta = (c[a][0] - c[b][0], c[a][1] - c[b][1])
                xs.append([math.copysign(math.log1p(abs(v)), v) if v else 0.0 for v in delta])
                ys.append(pair_target(c[a], c[b]))
                ds.append(baseline[key(e, variant)][a] - baseline[key(e, variant)][b])
                used.add(e['episodeId']); variant_used.add(key(e, variant))
            x, target, delta_laya = (torch.tensor(v, dtype=torch.float64) for v in (xs, ys, ds))
            optimizer.zero_grad(set_to_none=True)
            prediction = model.pair_logits(x, delta_laya if hybrid else None)
            loss = torch.nn.functional.binary_cross_entropy_with_logits(prediction, target)
            if not torch.isfinite(loss):
                raise ValueError('Nonfinite pair loss')
            loss.backward(); optimizer.step()
            if update % plan['validateEvery'] == 0 or update == plan['optimizerUpdates']:
                model.eval()
                metrics, _ = evaluate_choices(model, validation, baseline)
                score = metrics['nondegenerate']['accuracy']
                trace.append({'updates': update, 'lastBatchLoss': float(loss.detach()), 'validation': metrics})
                if score > best:
                    best, best_update = score, update
                    best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
                print(json.dumps({'stage': name, 'updates': update, 'loss': float(loss.detach()), 'validationNondegenerate': score}), flush=True)
                model.train()
        config = model.artifact_config()
        state_path = destination / (name + '.pt')
        torch.save(best_state, state_path)
        write(destination / (name + '.json'), config)
        reports[name] = {'optimizerUpdates': plan['optimizerUpdates'], 'pairDraws': plan['optimizerUpdates'] * plan['pairsPerUpdate'],
                         'seed': plan['seed'], 'controlledPairOrderAcrossAblations': True,
                         'initialTensorSha256': initial, 'selectedTensorSha256': tensor_fingerprint(best_state),
                         'changedSelectedTensors': [n for n, h in tensor_fingerprint(best_state).items() if h != initial[n]],
                         'selectedAlpha': float(best_state['alpha']) if hybrid else None,
                         'uniqueEpisodesSampled': len(used), 'uniqueVariantsSampled': len(variant_used),
                         'bestValidationUpdate': best_update, 'bestValidationNondegenerateAccuracy': best,
                         'seconds': time.perf_counter() - started, 'trace': trace,
                         'files': file_specs(destination, (name + '.pt', name + '.json'))}
    report = {'source': 'synthetic_pipeline_only', 'precision': 'float64', 'models': reports,
              'pipelineSha256': pipeline_fingerprint(), 'runtimeFingerprint': runtime_fingerprint(),
              'planSha256': sha(output / 'plan.json'), 'cacheReportSha256': sha(output / 'cache_report.json'),
              'holdoutRead': False, 'deployable': False}
    verify_pipeline(prep); verify_cache(output, cached)
    write(output / 'training_report.json', report)
    write(output / 'selection_lock.json', {'source': 'synthetic_pipeline_only', 'heldoutNotGenerated': True,
          'pipelineSha256': pipeline_fingerprint(), 'runtimeFingerprint': runtime_fingerprint(),
          'files': file_specs(output, ('plan.json', 'prepared.json', 'cache_report.json', 'training_report.json')),
          'adapters': {name: r['files'] for name, r in reports.items()}, 'deployable': False})
    return report


def load_selected(output, lock):
    import torch
    from mifu_numeric_ranker import load_ranker
    models = {}
    for name, specs in lock['adapters'].items():
        verify_files(output / 'adapters', specs)
        model = load_ranker(read(output / 'adapters' / (name + '.json')),
                            torch.load(output / 'adapters' / (name + '.pt'), map_location='cpu', weights_only=True), device='cpu')
        model.eval(); models[name] = model
    return models


def comparison_evidence(episodes, requests, old_details, choices):
    values = []
    for e, req, old, choice in zip(episodes, requests, old_details, choices):
        objective = costs(req)
        best = min(objective.values())
        values.append({'episodeId': e['episodeId'], 'scenario': e['scenario'],
                       'samePhysicalChoice': choice == old['selected'],
                       'sameObjectiveCost': objective[choice] == objective[old['selected']],
                       'originalCorrect': objective[old['selected']] == best,
                       'changedInputCorrect': objective[choice] == best,
                       'bothOptimal': objective[old['selected']] == best == objective[choice]})
    fields = ('samePhysicalChoice', 'sameObjectiveCost', 'originalCorrect', 'changedInputCorrect', 'bothOptimal')
    def aggregate(subset):
        return {'n': len(subset), **{name: sum(v[name] for v in subset) for name in fields}}
    return {'overall': aggregate(values),
            'nondegenerate': aggregate([v for v in values if v['scenario'] != 'allties']),
            'allties': aggregate([v for v in values if v['scenario'] == 'allties']),
            'sameObjectiveCostMeaning': 'equal cost to original selection, including equally wrong choices; see bothOptimal',
            'pairedEvidenceNotAdditionalIndependentEpisodes': True}


def evaluate(output, checkpoint):
    plan, lock = read(output / 'plan.json'), read(output / 'selection_lock.json')
    verify_pipeline(lock)
    verify_files(output, lock['files'])
    prep, cached = read(output / 'prepared.json'), read(output / 'cache_report.json')
    verify_pipeline(prep); verify_files(output, prep['files']); verify_cache(output, cached)
    if lock.get('runtimeFingerprint') != runtime_fingerprint():
        raise ValueError('Selected adapter runtime/SDK changed')
    from evaluate_compact_model import checkpoint_artifact_hashes
    if checkpoint_artifact_hashes(checkpoint) != cached['runtime']['checkpointArtifactsSha256']:
        raise ValueError('Frozen H inference inputs differ from training cache, including tokenizer/config')
    models = load_selected(output, lock)
    destination = output / 'holdout_evaluation'
    destination.mkdir(exist_ok=False)
    write(destination / 'pre_holdout_lock.json', {'selectionLockSha256': sha(output / 'selection_lock.json'),
          'source': 'synthetic_pipeline_only', 'deployable': False})
    training_episodes = rows(output / 'train.jsonl')
    previous = training_episodes + rows(output / 'validation.jsonl')
    occupied = set().union(*(episode_signatures(req) for e in previous for req in e['variants']))
    holdout = generate('holdout', plan['holdoutEpisodes'], plan, occupied)
    write_rows(destination / 'holdout.jsonl', holdout)
    runner = FrozenLaya(checkpoint, plan)
    if runner.inventory != cached['runtime']['checkpointArtifactsSha256']:
        raise ValueError('Frozen H inference inputs changed while opening evaluation')
    base_values = runner.predict([e['variants'][0] for e in holdout])
    base = {key(e, 0): z for e, z in zip(holdout, base_values)}
    write(destination / 'laya_logits.json', base)
    reports, details = {}, {}
    for name, model in {**models, 'laya_only': 'laya', 'deterministic_exact_baseline_not_model': 'exact'}.items():
        reports[name], details[name] = evaluate_choices(model, holdout, base)
    # Numeric-only can be checked on every episode; hybrid/Laya require actual re-encoding.
    permuted = []
    for index, e in enumerate(holdout):
        req = copy.deepcopy(e['variants'][0]); random.Random(plan['seed'] + index).shuffle(req['candidates'])
        if [c['id'] for c in req['candidates']] == [c['id'] for c in e['variants'][0]['candidates']]:
            req['candidates'] = req['candidates'][1:] + req['candidates'][:1]
        permuted.append(req)
    numeric_choices = [select(models['numeric_only'], req, base[key(e, 0)]) for e, req in zip(holdout, permuted)]
    # Stratify the bounded actual-Laya permutation probe by count and scenario.
    limit = plan['physicalPermutationProbeEpisodes'] // 32
    seen = Counter(); indices = []
    for i, e in enumerate(holdout):
        group = (e['candidateCount'], e['scenario'])
        if seen[group] < limit:
            indices.append(i); seen[group] += 1
    perm_values = runner.predict([permuted[i] for i in indices])
    stability = {'numeric_only': comparison_evidence(holdout, permuted, details['numeric_only'], numeric_choices)}
    stability['numeric_only']['scope'] = 'all holdout base episodes'
    probe_episodes, probe_requests = [holdout[i] for i in indices], [permuted[i] for i in indices]
    permutation_choices = {'numeric_only': dict(enumerate(numeric_choices))}
    for name, model in (('hybrid', models['hybrid']), ('laya_only', 'laya')):
        changed = [select(model, req, z) for req, z in zip(probe_requests, perm_values)]
        permutation_choices[name] = dict(zip(indices, changed))
        stability[name] = comparison_evidence(probe_episodes, probe_requests, [details[name][i] for i in indices], changed)
        stability[name]['scope'] = 'stratified actual re-encoded subset; not all holdout'
    # Preserve physical order to isolate wait/run decomposition from permutation.
    decomposed = []
    for e in probe_episodes:
        req = copy.deepcopy(e['variants'][1])
        by_id = {c['id']: c for c in req['candidates']}
        req['candidates'] = [by_id[c['id']] for c in e['variants'][0]['candidates']]
        decomposed.append(req)
    decomposition_values = runner.predict(decomposed)
    decomposition, decomposition_choices = {}, {}
    for name, model in {**models, 'laya_only': 'laya'}.items():
        changed = [select(model, req, z) for req, z in zip(decomposed, decomposition_values)]
        decomposition_choices[name] = changed
        decomposition[name] = comparison_evidence(probe_episodes, decomposed, [details[name][i] for i in indices], changed)
        decomposition[name]['scope'] = 'stratified subset, same physical order and objective costs, different wait/run decomposition'
    permutation_logits = dict(zip(indices, perm_values))
    write(destination / 'paired_probe_evidence.json', {
        'source': 'synthetic_pipeline_only', 'additionalIndependentEpisodes': 0,
        'permutation': [{'episodeId': e['episodeId'], 'candidateOrder': [c['id'] for c in permuted[i]['candidates']],
                         'layaLogits': permutation_logits.get(i),
                         'selected': {name: choices[i] for name, choices in permutation_choices.items() if i in choices}}
                        for i, e in enumerate(holdout)],
        'decomposition': [{'episodeId': e['episodeId'], 'variant': 1,
                           'candidateOrder': [c['id'] for c in decomposed[i]['candidates']],
                           'layaLogits': decomposition_values[i],
                           'selected': {name: choices[i] for name, choices in decomposition_choices.items()}}
                          for i, e in enumerate(probe_episodes)]})
    write(destination / 'decisions.json', details)
    result = {'source': 'synthetic_pipeline_only', 'operationalRecords': 0, 'deployable': False,
              'pipelineSha256': pipeline_fingerprint(), 'runtimeFingerprint': runtime_fingerprint(),
              'baseEpisodes': len(holdout), 'variantsCountedAsIndependent': False,
              'modelMetrics': reports, 'physicalPermutation': stability, 'runtime': runner.evidence(),
              'decompositionStability': decomposition, 'numericGeometryOverlap': geometry_overlap(previous, holdout),
              'novelNumericProjection': {
                  'versusTraining': novel_projection_report(training_episodes, holdout, details),
                  'versusTrainingAndValidation': novel_projection_report(previous, holdout, details)},
              'allTiesMeaning': 'property/stability diagnostic; excluded from primary nondegenerate accuracy',
              'files': file_specs(destination, ('holdout.jsonl', 'laya_logits.json', 'pre_holdout_lock.json',
                                               'paired_probe_evidence.json', 'decisions.json')),
              'selectionLockSha256': sha(output / 'selection_lock.json'),
              'thresholdMeaning': '95% summaries are empirical synthetic metrics, not production acceptance',
              'selectionUsedHoldout': False}
    verify_pipeline(lock); verify_files(output, lock['files']); load_selected(output, lock)
    write(destination / 'report.json', result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('dry-run', 'prepare', 'cache', 'train', 'evaluate'))
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--checkpoint', type=Path)
    args = parser.parse_args()
    if args.stage == 'dry-run':
        if args.out.exists():
            raise FileExistsError(args.out)
        print(json.dumps({'plan': PLAN, 'writesFiles': False, 'importsTorch': False, 'usesGPU': False}, indent=2))
        return
    if args.stage in ('cache', 'evaluate') and args.checkpoint is None:
        parser.error('--checkpoint is required for actual frozen Laya forwards')
    try:
        result = {'prepare': lambda: prepare(args.out), 'cache': lambda: cache(args.out, args.checkpoint),
                  'train': lambda: train(args.out), 'evaluate': lambda: evaluate(args.out, args.checkpoint)}[args.stage]()
    except Exception as exc:
        # Preserve partial evidence rather than clean it up or silently restart.
        # Never create an output merely to report that a stage could not start.
        if args.out.is_dir():
            write(args.out / ('failed-' + args.stage + '-' + str(time.time_ns()) + '.json'),
                  {'stage': args.stage, 'completed': False, 'exception': type(exc).__name__,
                   'message': str(exc), 'partialArtifactsPreserved': True, 'deployable': False})
        raise
    print(json.dumps({'stage': args.stage, 'completed': True, 'deployable': False,
                      'out': str(args.out), 'summary': result.get('baseEpisodes')}))


if __name__ == '__main__':
    main()
