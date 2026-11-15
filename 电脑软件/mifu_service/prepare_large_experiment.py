"""Extract a bounded, stratified experiment from the sharded synthetic corpus.

The existing Laya trainer loads its input into memory. This extraction is an
explicit first experiment, not streaming training of the complete corpus.
"""
from __future__ import annotations

import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import random

from large_dataset import SCHEMA, SOURCE, SPLITS, canonical, file_hash
from prepare_curriculum import validate_bundle


def stratum(row):
    # Keep anchor hardware represented; alternative candidate topologies remain
    # in each selected example. Choice position is never a stratum or a label.
    physical_first = row['audit']['candidate_order'].index(0)
    device = row['state']['candidates'][f'candidate_{physical_first:02d}']
    return '/'.join((device['model'], str(device['nozzle_mm']), device['feed']['kind']))


def prepare(source: Path, output: Path, train_per_stratum=36, eval_per_stratum=4, seed=4070):
    if not 1 <= train_per_stratum <= 100 or not 1 <= eval_per_stratum <= 20:
        raise ValueError('Bounded experiment requires train quota 1..100 and evaluation quota 1..20')
    if output.exists():
        raise FileExistsError(output)
    original = json.loads((source / 'manifest.json').read_text(encoding='utf-8'))
    if original.get('source') != SOURCE or original.get('featureSchemaVersion') != SCHEMA or original.get('deployable') is not False:
        raise ValueError('Expected non-deployable hardware simulation corpus')
    datasets, coverage = {}, {}
    selected_signatures = {}
    for split in SPLITS:
        rows, counts = [], Counter()
        quota = train_per_stratum if split == 'train' else eval_per_stratum
        scanned = 0
        for shard in original['splits'][split]['shards']:
            path = (source / shard['path']).resolve()
            if path.parent != source.resolve() or file_hash(path) != shard['sha256']:
                raise ValueError('Source shard path or hash mismatch')
            shard_rows = 0
            with gzip.open(path, 'rt', encoding='utf-8') as handle:
                for line in handle:
                    shard_rows += 1
                    row = json.loads(line)
                    meta = row['mifu_provenance']
                    if meta['source'] != SOURCE or meta['split'] != split or meta['variant'] != 0:
                        raise ValueError('Wrong source/split or permutation in primary corpus')
                    if row['state'].get('featureSchemaVersion') != SCHEMA or meta.get('hardware_schema') != SCHEMA:
                        raise ValueError('Row uses a different feature schema')
                    key = stratum(row)
                    if counts[key] >= quota:
                        continue
                    semantic_input = {'plate': row['state']['plate'],
                                      'candidates': sorted(row['state']['candidates'].values(), key=canonical)}
                    signature = hashlib.sha256(canonical(semantic_input)).hexdigest()
                    if signature != meta.get('independent_input_sha256'):
                        raise ValueError('Selected row semantic signature mismatch')
                    if selected_signatures.setdefault(signature, split) != split:
                        raise ValueError('Reordered semantic input leaks across selected splits')
                    counts[key] += 1
                    # Preserve origins without exposing oracle costs or audits
                    # to the encoder; SDK consumes only state and questions.
                    meta = {**meta, 'groupId': f"hardware-{original['seed']}-{meta['episode']}"}
                    rows.append({name: row[name] for name in ('state', 'questions', 'expected')}
                                | {'mifu_provenance': meta})
            if shard_rows != shard['rows']:
                raise ValueError('Source shard count mismatch')
            scanned += shard_rows
        if scanned != original['splits'][split]['rows'] or not rows:
            raise ValueError('Invalid source split count')
        random.Random(f'{seed}:{split}').shuffle(rows)
        datasets[split], coverage[split] = rows, dict(counts)
    manifest = {'schemaVersion': 1, 'source': SOURCE, 'deployable': False,
                'domainTrainingCompleted': False, 'featureSchemaVersion': SCHEMA,
                'onlineServiceSchemaCompatible': False,
                'sourceManifestSha256': file_hash(source / 'manifest.json'),
                'selection': 'first_quota_per_anchor_hardware_stratum_then_seeded_shuffle',
                'quotas': {'train': train_per_stratum, 'eachEvaluationSplit': eval_per_stratum},
                'seed': seed, 'coverage': coverage, 'files': {},
                'limitations': ['Synthetic timing-order experiment only; not real performance evidence.',
                               'This is a subset, not a full-corpus training implementation.',
                               'SDK internal random calibration remains unsuitable for claimed group-isolated production calibration.',
                               'Unknown hardware and incompatible material gates are tested separately, not learned as permissions.']}
    output.mkdir(parents=True, exist_ok=False)
    for split, rows in datasets.items():
        path = output / f'{split}.jsonl'
        with path.open('x', encoding='utf-8') as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n')
        manifest['files'][split] = {'rows': len(rows), 'sha256': file_hash(path)}
    (output / 'experiment_manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    validate_bundle(output)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--train-per-stratum', type=int, default=36)
    parser.add_argument('--eval-per-stratum', type=int, default=4)
    args = parser.parse_args()
    result = prepare(args.source, args.out, args.train_per_stratum, args.eval_per_stratum)
    print(json.dumps({'files': result['files'], 'strataPerSplit': {key: len(value) for key, value in result['coverage'].items()}, 'deployable': False}))


if __name__ == '__main__':
    main()
