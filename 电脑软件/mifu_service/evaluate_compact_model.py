"""Once selected, evaluate a locked experimental checkpoint on reserved data.

Calibration changes only probability temperature, never ranking weights. This
script writes an experiment report and calibration artifact, not a deployable
manifest. Synthetic accuracy is never represented as operational print quality.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import time

from decision_contract import build_decision_input, from_simulation_row, label_for_candidate
from diagnose_learning import renamed_row


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def read_split(path, expected, *, unique_episodes=True):
    rows, groups = [], set()
    with Path(path).open(encoding='utf-8') as f:
        for line in f:
            row = json.loads(line)
            meta = row['mifu_provenance']
            if meta['source'] != 'synthetic_pipeline_only' or meta['split'] != expected:
                raise ValueError('Unexpected split/source')
            if not isinstance(meta.get('groupId'), str) or not meta['groupId']:
                raise ValueError('Missing episode identity')
            if unique_episodes and meta['groupId'] in groups:
                raise ValueError('This evaluation requires one example per independent episode')
            groups.add(meta['groupId'])
            rows.append(row)
    if not rows:
        raise ValueError('Empty evaluation split')
    return rows, groups


def checkpoint_artifact_hashes(checkpoint):
    """Freeze the inference inputs, not only the main weight file."""
    checkpoint = Path(checkpoint)
    paths = [checkpoint / name for name in ('model.safetensors', 'rl_agent_config.json', 'encoder/config.json')]
    tokenizer = checkpoint / 'tokenizer'
    if not tokenizer.is_dir():
        raise ValueError('Checkpoint tokenizer is missing')
    paths.extend(sorted(path for path in tokenizer.rglob('*') if path.is_file()))
    if len(paths) == 3 or any(not path.is_file() for path in paths):
        raise ValueError('Checkpoint inference inputs are incomplete')
    return {path.relative_to(checkpoint).as_posix(): sha256(path) for path in paths}


def require_unchanged_checkpoint(checkpoint, locked):
    if checkpoint_artifact_hashes(checkpoint) != locked:
        raise ValueError('Checkpoint inference inputs changed after evaluation was locked')


def load_checkpoint_readonly(checkpoint, cfg, sdk):
    """Use the pinned SDK architecture without its on-disk tokenizer repair.

    laya.train.load_checkpoint calls _fix_tokenizer_config, which can rewrite a
    saved tokenizer_config.json. Evaluation must fail on incompatible input,
    rather than silently change the artifact after it has been locked.
    """
    import torch
    from safetensors.torch import load_file
    from transformers import AutoTokenizer

    checkpoint = Path(checkpoint)
    tok = AutoTokenizer.from_pretrained(str(checkpoint / 'tokenizer'), local_files_only=True)
    model = sdk.build_model(cfg, encoder_dir=str(checkpoint / 'encoder'))
    weights = load_file(str(checkpoint / 'model.safetensors'), device='cpu')
    for name, tensor in weights.items():
        if not bool(torch.isfinite(tensor).all()):
            raise ValueError('Nonfinite saved weight: ' + name)
    model.load_state_dict(weights, strict=True)
    del weights
    return model.float(), tok


def require_disjoint_groups(*groups):
    if any(a & b for i, a in enumerate(groups) for b in groups[i + 1:]):
        raise ValueError('Episode overlap across train/validation/calibration/holdout')


def wilson(correct, count):
    if not 0 <= correct <= count or count < 1:
        raise ValueError('Invalid binomial counts')
    z = 1.959963984540054
    p, z2 = correct / count, z * z
    center = (p + z2 / (2 * count)) / (1 + z2 / count)
    half = z * math.sqrt(p * (1 - p) / count + z2 / (4 * count * count)) / (1 + z2 / count)
    return [max(0, center - half), min(1, center + half)]


def selection_metrics(rows, choices, reversed_choices, renamed_choices):
    if not rows or not len(rows) == len(choices) == len(reversed_choices) == len(renamed_choices):
        raise ValueError('Decision count mismatch')
    buckets, models, outcomes = {}, {}, []
    for row, choice, permuted, renamed in zip(rows, choices, reversed_choices, renamed_choices):
        candidates = row['state']['candidates']
        # v4 from_simulation_row iterates the physical state, then assigns new
        # option labels. Legacy criteria insertion order is not that mapping.
        keys = list(candidates)
        if not 2 <= len(keys) <= 16 or set(keys) != set(row['questions']['printer']['criteria']):
            raise ValueError('Candidate/criteria identities are inconsistent')
        if any(type(index) is not int or not 0 <= index < len(keys) for index in (choice, permuted, renamed)):
            raise ValueError('Decision index is outside the physical candidate mapping')
        selected = keys[choice]
        if any(type(v.get(field)) not in (int, float) or not 0 <= v[field] <= 31 * 86400 or
               not math.isfinite(v[field]) or int(v[field]) != v[field]
               for v in candidates.values() for field in ('wait_s', 'setup_s', 'run_s')):
            raise ValueError('Evaluation costs must be finite whole nonnegative seconds')
        costs = {k: (v['wait_s'] + v['setup_s'] + v['run_s'], v['setup_s']) for k, v in candidates.items()}
        oracle = min(costs, key=costs.get)
        expected = row['expected']['printer']
        if expected not in costs or costs[expected] != costs[oracle]:
            raise ValueError('Evaluation target disagrees with independent cost calculation')
        result = {'correct': costs[selected] == costs[oracle],
                  'regret': costs[selected][0] - costs[oracle][0],
                  'tieBreakRegret': max(0, costs[selected][1] - costs[oracle][1])
                                    if costs[selected][0] == costs[oracle][0] else 0,
                  'permutation': choice == permuted,
                  'rename': choice == len(keys) - 1 - renamed}
        outcomes.append(result)
        buckets.setdefault(str(len(keys)), []).append(result)
        models.setdefault(row['state']['plate']['target_model'], []).append(result)

    def summary(values):
        n = len(values)
        correct = sum(v['correct'] for v in values)
        return {'independentEpisodes': n, 'correct': correct, 'accuracy': correct / n,
                'accuracyWilson95': wilson(correct, n),
                'meanRegretSeconds': sum(v['regret'] for v in values) / n,
                'maxRegretSeconds': max(v['regret'] for v in values),
                'meanTieBreakPreparationRegretSeconds': sum(v['tieBreakRegret'] for v in values) / n,
                'tieBreakMistakes': sum(v['tieBreakRegret'] > 0 for v in values),
                'optionPermutationConsistency': sum(v['permutation'] for v in values) / n,
                'physicalRenameConsistency': sum(v['rename'] for v in values) / n}
    return {'overall': summary(outcomes), 'candidateBuckets': {k: summary(v) for k, v in buckets.items()},
            'hardwareModelSlices': {k: summary(v) for k, v in models.items()}}


def selective_metrics(records, fitted, thresholds, *, bucket_for):
    """Score fixed calibration-only cuts; unknown SDK buckets reject, not allow.

    SDK choice confidence is rounded to four decimals before thresholding.
    These empirical results are separate from all-choice accuracy and do not
    authorize use of the untrained act head or install a deployment gate.
    """
    outcomes, counts, buckets = [], {}, {}
    for qtype, logits, target, k in records:
        bucket = bucket_for(qtype, k)
        scale = fitted['temperature_by_options'].get(bucket, fitted['temperature'][qtype])
        if not math.isfinite(scale) or scale <= 0:
            raise ValueError('Invalid calibration temperature')
        values = [float(value) / scale for value in logits[:k]]
        if len(values) != k or k < 2 or any(not math.isfinite(value) for value in values):
            raise ValueError('Invalid selective evaluation logits')
        peak = max(values)
        probabilities = [math.exp(value - peak) for value in values]
        total = sum(probabilities)
        confidence = round(max(probabilities) / total, 4)
        threshold = thresholds.get(bucket)
        if threshold is not None and (type(threshold) not in (int, float) or not math.isfinite(threshold) or not 0 <= threshold <= 1):
            raise ValueError('Invalid calibration confidence threshold')
        choice = max(range(k), key=values.__getitem__)
        expected = max(range(k), key=lambda index: target[index])
        result = {'accepted': threshold is not None and confidence >= threshold,
                  'correct': choice == expected, 'unfittedBucket': threshold is None}
        outcomes.append(result)
        counts.setdefault(str(k), []).append(result)
        buckets.setdefault(bucket, []).append(result)

    def summary(values):
        n = len(values)
        accepted = [value for value in values if value['accepted']]
        correct = sum(value['correct'] for value in accepted)
        return {'episodes': n, 'accepted': len(accepted), 'coverage': len(accepted) / n,
                'acceptedCorrect': correct, 'acceptedAccuracy': correct / len(accepted) if accepted else None,
                'acceptedAccuracyWilson95': wilson(correct, len(accepted)) if accepted else None,
                'unfittedBucketRejected': sum(value['unfittedBucket'] for value in values)}
    if not outcomes:
        raise ValueError('Empty selective evaluation')
    return {'overall': summary(outcomes), 'candidateBuckets': {k: summary(v) for k, v in counts.items()},
            'sdkBuckets': {k: summary(v) for k, v in buckets.items()},
            'thresholdSource': 'calibration_only', 'unfittedBucketPolicy': 'reject', 'actHeadUsed': False}


def run(args):
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1')
    weights_hash = sha256(args.checkpoint / 'model.safetensors')
    if weights_hash != args.locked_checkpoint_sha256:
        raise ValueError('Checkpoint differs from the version selected before opening reserved data')
    if args.out.exists():
        raise FileExistsError(args.out)
    locked_artifacts = checkpoint_artifact_hashes(args.checkpoint)
    if locked_artifacts['model.safetensors'] != weights_hash:
        raise ValueError('Checkpoint weights changed while establishing the evaluation lock')
    cfg = json.loads((args.checkpoint / 'rl_agent_config.json').read_text(encoding='utf-8'))
    if cfg.get('mifu_experiment', {}).get('inputContract') != 'mifu-decision-v4' or cfg.get('option_layout') != 'parallel':
        raise ValueError('Expected the compact parallel experimental checkpoint')
    if importlib.metadata.version('laya') != '0.4.31':
        raise ValueError('This evaluation requires pinned laya==0.4.31')
    import torch
    import numpy as np
    from laya import train as sdk
    from laya.calibrate import fit_abstention_thresholds, fit_temperature_map
    from laya.common import collate_items, temp_bucket
    from diagnose_learning import forward
    model, tok = load_checkpoint_readonly(args.checkpoint, cfg, sdk)
    # The loaded model is locked before even calibration data is opened. A
    # concurrent save must not cause this report to cite different weights.
    require_unchanged_checkpoint(args.checkpoint, locked_artifacts)
    device = torch.device('cuda')
    model.to(device).eval()
    _, train_groups = read_split(args.bundle / 'train.jsonl', 'train', unique_episodes=False)
    _, validation_groups = read_split(args.bundle / 'validation.jsonl', 'validation', unique_episodes=False)
    calibration_rows, calibration_groups = read_split(args.bundle / 'calibration.jsonl', 'calibration')
    require_disjoint_groups(train_groups, validation_groups, calibration_groups)

    def adapt(rows):
        adapted = []
        for row in rows:
            prepared = build_decision_input(from_simulation_row(row), tokenizer=tok, now_epoch_s=0)
            adapted.append({'state': prepared['state'], 'questions': prepared['questions'],
                            'expected': {'printer': label_for_candidate(prepared, row['expected']['printer'])}})
        items, skipped = sdk.items_from_rows(tok, adapted, 2048, 1024)
        if len(items) != len(rows):
            raise ValueError(skipped)
        return items

    def records(items, reverse=False):
        result, decisions = [], []
        with torch.no_grad():
            for start in range(0, len(items), 4):
                chunk = items[start:start + 4]
                encoded = [sdk.encode_item(tok, it, 2048, 1024,
                           list(reversed(range(it['k']))) if reverse else None, True) for it in chunk]
                batch = collate_items([encoded], tok.pad_token_id)
                logits = forward(model, batch, device, 'fp32', True).cpu()
                for index, it in enumerate(chunk):
                    z = logits[index, :it['k']]
                    if reverse:
                        z = z.flip(0)
                    if not torch.isfinite(z).all():
                        raise ValueError('Nonfinite logits')
                    result.append((it['qtype'], z.numpy(), np.asarray(it['target']), it['k']))
                    decisions.append(int(z.argmax()))
                if start % 128 == 0:
                    print('EVALUATED', start + len(chunk), '/', len(items), flush=True)
        return result, decisions

    started = time.perf_counter()
    print('CALIBRATION_START', len(calibration_rows), flush=True)
    calibration_records, _ = records(adapt(calibration_rows))
    fitted = fit_temperature_map(calibration_records, compute_ece=False, seed=4070)
    thresholds = fit_abstention_thresholds(calibration_records, fitted['temperature'],
                                           fitted['temperature_by_options'], target_error=0.02,
                                           min_bucket_n=100, conservative=True)
    # Reserved labels do not enter temperature fitting or checkpoint selection.
    holdout_rows, holdout_groups = read_split(args.bundle / 'holdout.jsonl', 'holdout')
    require_disjoint_groups(train_groups, validation_groups, calibration_groups, holdout_groups)
    print('LOCKED_HOLDOUT_START', len(holdout_rows), flush=True)
    items = adapt(holdout_rows)
    holdout_records, choices = records(items)
    _, permuted = records(items, True)
    _, renamed = records(adapt([renamed_row(row) for row in holdout_rows]))
    selection = selection_metrics(holdout_rows, choices, permuted, renamed)
    require_unchanged_checkpoint(args.checkpoint, locked_artifacts)
    report = {'purpose': 'reserved_synthetic_evaluation', 'deployable': False,
              'weightsSha256': weights_hash, 'inputContract': 'mifu-decision-v4',
              'checkpointArtifactsSha256': locked_artifacts,
              'sdkVersion': importlib.metadata.version('laya'),
              'tokenizersVersion': importlib.metadata.version('tokenizers'),
              'evaluationPrecision': 'fp32', 'checkpointConfiguredAmpDtype': cfg.get('amp_dtype'),
              'runnerSha256': sha256(Path(__file__)), 'calibrationEpisodes': len(calibration_groups),
              'holdoutEpisodes': len(holdout_groups), 'episodeOverlapCount': 0,
              'evaluationSource': 'synthetic_pipeline_only',
              'weightsUpdated': False, 'automaticExecutionAuthorized': False,
              'checkpointLoadMode': 'read_only_pinned_sdk_architecture', 'allSavedWeightsFinite': True,
              'reservedReadOrder': ['locked_checkpoint_loaded_and_verified', 'calibration', 'temperature_fitted', 'holdout'],
              'hardwareSliceMeaning': 'task target model; not a causal comparison of printer performance',
              'regretDefinition': 'Known finish-time difference; same-finish preparation mistakes reported separately.',
              'confidencePolicy': {'thresholds': thresholds, 'source': 'calibration_only',
                                   'targetError': 0.02, 'minSdkBucketN': 100, 'conservative': True,
                                   'unfittedBucketPolicy': 'reject', 'actHeadUsed': False,
                                   'productionGateInstalled': False,
                                   'limitation': 'Empirical FP32 calibration cut; no error/coverage guarantee. A different runtime precision needs separate validation.'},
              'selectiveHoldout': selective_metrics(holdout_records, fitted, thresholds, bucket_for=temp_bucket),
              'calibration': fitted, 'selection': selection,
              'uncalibrated': sdk.evaluate_records(holdout_records),
              'calibrated': sdk.evaluate_records(holdout_records, fitted['temperature'], fitted['temperature_by_options']),
              'seconds': time.perf_counter() - started,
              'filesSha256': {s: sha256(args.bundle / (s + '.jsonl')) for s in ('train', 'validation', 'calibration', 'holdout')}}
    args.out.mkdir(parents=True)
    (args.out / 'reserved_evaluation.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({'selection': selection['overall'], 'buckets': selection['candidateBuckets'],
                      'calibrated': report['calibrated'], 'deployable': False}), flush=True)
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--checkpoint', type=Path, required=True)
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--locked-checkpoint-sha256', required=True)
    p.add_argument('--out', type=Path, required=True)
    run(p.parse_args())


if __name__ == '__main__':
    main()
