"""Fresh, grouped 2/4/8/16-candidate simulation for the v4 input projection.

Writes raw v3 evidence; it must be projected by decision_contract before model
training. Never reads any earlier corpus, reserved holdout or model checkpoint.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import random
import shutil

from decision_contract import (HEAD_MAX_LEN, MAX_LEN, SCHEMA as CONTRACT,
                               build_decision_input, from_simulation_row, label_for_candidate,
                               normalize_request)
from large_dataset import (ORACLE, SCHEMA, SOURCE, SPLITS, admission, canonical,
                            episode_state, features, file_hash, read_matrix)

COUNTS = (2, 4, 8, 16)
DEFAULT_SIZES = {'train': 10000, 'validation': 1600, 'calibration': 800, 'holdout': 800}


def semantic_hash(state):
    return hashlib.sha256(canonical({'plate': state['plate'],
        'candidates': sorted(state['candidates'].values(), key=canonical)})).hexdigest()


def validate_row(row):
    """Recompute labels from recorded evidence, not from an external rank."""
    state, meta = row['state'], row['mifu_provenance']
    if meta.get('source') != SOURCE or state.get('featureSchemaVersion') != SCHEMA:
        raise ValueError('Unexpected raw evidence schema or source')
    candidates = state['candidates']
    if len(candidates) not in COUNTS or set(candidates) != set(row['questions']['printer']['criteria']):
        raise ValueError('Candidate count or raw label mapping mismatch')
    costs = {key: (value['wait_s'] + value['setup_s'] + value['run_s'], value['setup_s'])
             for key, value in candidates.items()}
    best = min(costs.values())
    if list(costs.values()).count(best) != 1 or row['expected']['printer'] != min(costs, key=costs.get):
        raise ValueError('Recorded target differs from the versioned simulator objective')
    if meta.get('independent_input_sha256') != semantic_hash(state):
        raise ValueError('Raw evidence signature mismatch')
    request = from_simulation_row(row)
    prepared = normalize_request(request, now_epoch_s=0)
    if label_for_candidate(prepared, row['expected']['printer']) not in prepared['questions']['printer']['criteria']:
        raise ValueError('Projected target mapping is invalid')


def prepare(output: Path, matrix_path: Path, *, seed=20261112, sizes=None, tokenizer=None):
    sizes = dict(DEFAULT_SIZES if sizes is None else sizes)
    if set(sizes) != set(SPLITS) or any(type(n) is not int or n < 4 or n % 4 for n in sizes.values()):
        raise ValueError('Each split requires a positive multiple of four rows')
    if type(seed) is not int or seed < 0:
        raise ValueError('A nonnegative integer seed is required')
    matrix, combinations = read_matrix(matrix_path)
    by_slice = {}
    for combo in combinations:
        by_slice.setdefault(combo[:2], []).append(combo)
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(matrix_path, output / 'hardware_matrix.json')
    signatures, groups = set(), set()
    total = duplicates = ambiguous = cross_topology = 0
    coverage, files = {}, {}
    token_audit = {'status': 'pending' if tokenizer is None else 'passed_all_projected_rows',
                   'rows': 0, 'maxSequenceTokens': 0, 'maxOptionTokens': 0,
                   'maxLen': MAX_LEN, 'headMaxLen': HEAD_MAX_LEN, 'byCandidateCount': {}}
    for split in SPLITS:
        kinds, hardware, winners = Counter(), Counter(), Counter()
        topology_order = list(combinations)
        random.Random(f'compact-v4:{seed}:{split}:hardware').shuffle(topology_order)
        path = output / f'{split}.jsonl'
        with path.open('x', encoding='utf-8') as handle:
            for index in range(sizes[split]):
                count = COUNTS[index % len(COUNTS)]
                combo = topology_order[(index // len(COUNTS)) % len(topology_order)]
                group = f'compact-{seed}-{split}-{index}'
                if group in groups:
                    raise AssertionError('Episode identity reused')
                for attempt in range(100):
                    rng = random.Random(f'compact-v4:{seed}:{split}:{index}:{attempt}')
                    task, devices = episode_state(combo, rng, count, by_slice[combo[:2]])
                    if any(admission(task, device) for device in devices):
                        raise AssertionError('Invalid candidate entered the simulated choice set')
                    compiled = [features(task, device) for device in devices]
                    costs = [(v['wait_s'] + v['setup_s'] + v['run_s'], v['setup_s']) for v in compiled]
                    best = min(costs)
                    if costs.count(best) != 1:
                        ambiguous += 1
                        continue
                    order = list(range(count))
                    rng.shuffle(order)
                    state = {'featureSchemaVersion': SCHEMA, 'objective': ORACLE,
                             'plate': task, 'candidates': {f'candidate_{i:02d}': compiled[j] for i, j in enumerate(order)}}
                    fingerprint = semantic_hash(state)
                    if fingerprint in signatures:
                        duplicates += 1
                        continue
                    break
                else:
                    raise RuntimeError('Could not create a distinct unambiguous episode')
                expected = f'candidate_{order.index(costs.index(best)):02d}'
                row = {'state': state,
                       'questions': {'printer': {'type': 'choice',
                           'instructions': 'Select the eligible candidate with earliest known finish; ties prefer shorter setup.',
                           'criteria': {key: key for key in state['candidates']}}},
                       'expected': {'printer': expected},
                       'mifu_provenance': {'source': SOURCE, 'dataset_kind': 'compact_projection_experiment',
                           'hardware_schema': SCHEMA, 'projection_contract': CONTRACT,
                           'episode': total, 'groupId': group, 'step': 0, 'variant': 0, 'seed': seed,
                           'split': split, 'oracle': ORACLE, 'independent_input_sha256': fingerprint,
                           'material_evidence': 'synthetic_declared_material_compatibility'}}
                validate_row(row)
                if tokenizer is not None:
                    projected = build_decision_input(from_simulation_row(row), tokenizer=tokenizer, now_epoch_s=0)
                    audit = projected['diagnostics']['token_audit']
                    token_audit['rows'] += 1
                    token_audit['maxSequenceTokens'] = max(token_audit['maxSequenceTokens'], audit['sequence_tokens'])
                    token_audit['maxOptionTokens'] = max(token_audit['maxOptionTokens'], audit['max_option_tokens'])
                    bucket = token_audit['byCandidateCount'].setdefault(str(count), {'rows': 0, 'maxSequenceTokens': 0})
                    bucket['rows'] += 1
                    bucket['maxSequenceTokens'] = max(bucket['maxSequenceTokens'], audit['sequence_tokens'])
                handle.write(canonical(row).decode('utf-8') + '\n')
                signatures.add(fingerprint)
                groups.add(group)
                kinds[str(count)] += 1
                winners[f'{count}/{expected}'] += 1
                for device in compiled:
                    feed = device['feed']
                    hardware[f"{device['model']}/{device['nozzle_mm']}/{feed['kind']}/{feed['units']}"] += 1
                cross_topology += len({(v['feed']['kind'], v['feed']['units']) for v in compiled}) > 1
                total += 1
        files[split] = {'rows': sizes[split], 'sha256': file_hash(path)}
        coverage[split] = {'candidateCounts': dict(kinds), 'candidateHardwareCombinations': dict(hardware),
                           'expectedLabelCounts': dict(winners)}
        print(json.dumps({'completedSplit': split, 'rows': sizes[split], 'totalRows': total}), flush=True)
    manifest = {'schemaVersion': 1, 'source': SOURCE, 'deployable': False, 'domainTrainingCompleted': False,
                'featureSchemaVersion': SCHEMA, 'projectionContract': CONTRACT, 'rawInputIsNotSdkReady': True,
                'onlineServiceSchemaCompatible': False, 'seed': seed, 'files': files, 'coverage': coverage,
                'independentEpisodes': len(groups), 'uniqueSemanticInputs': len(signatures),
                'rowsPerEpisode': 1, 'duplicateInputsSkipped': duplicates, 'ambiguousTargetsSkipped': ambiguous,
                'crossTopologyDecisionCount': cross_topology, 'modelQualityEvaluated': False,
                'hardwareMatrixSha256': file_hash(output / 'hardware_matrix.json'),
                'hardwareSources': matrix.get('sources', {}), 'tokenAudit': token_audit,
                'generatorSha256': file_hash(Path(__file__)),
                'decisionContractSha256': file_hash(Path(__file__).with_name('decision_contract.py')),
                'previousCorpusOrHoldoutRead': False,
                'limitations': ['Synthetic known-time ranking only; no operational quality or deployment claim.',
                    'Fresh seed/domain and episode identities are used; old corpus content was not scanned for semantic overlap.',
                    'Raw v3 evidence must be projected through decision_contract with fixed 2048/1024 budgets before SDK training.',
                    'Candidate counts are balanced; hardware and material coverage are recorded rather than assumed exhaustive.',
                    'Token preservation on the new reserved splits is not a model-quality evaluation or tuning pass.']}
    (output / 'experiment_manifest.json').write_bytes(canonical(manifest) + b'\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--matrix', type=Path, default=Path(__file__).with_name('hardware_matrix.json'))
    parser.add_argument('--seed', type=int, default=20261112)
    parser.add_argument('--tokenizer', type=Path)
    args = parser.parse_args()
    tok = None
    if args.tokenizer:
        os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1')
        from transformers import AutoTokenizer
        tok = AutoTokenizer.from_pretrained(str(args.tokenizer), local_files_only=True)
    result = prepare(args.out, args.matrix, seed=args.seed, tokenizer=tok)
    print(json.dumps({'files': result['files'], 'independentEpisodes': result['independentEpisodes'],
                      'tokenAudit': result['tokenAudit'], 'deployable': False}), flush=True)


if __name__ == '__main__':
    main()
