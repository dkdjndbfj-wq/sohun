"""Prepare an explicit scenario plan and synthetic pipeline-only data, offline.

No training, download, review approval, printer access or deployable manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import random

from mifu_server import build_question, validate_request

SPLITS = ('train', 'validation', 'calibration', 'holdout')
FAMILIES = ('single_plate_wait', 'queue_count_decoy', 'multi_plate_snapshot')
SOURCE = 'synthetic_pipeline_only'


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def read_catalog(path: Path) -> dict:
    catalog = json.loads(path.read_text(encoding='utf-8'))
    scenarios = catalog['scenarios']
    if len(scenarios) != 46 or {item['id'] for item in scenarios} != {f'S{i:02d}' for i in range(1, 47)}:
        raise ValueError('The catalog must cover S01 through S46 exactly once')
    tracks = {item['id'] for item in catalog['tracks']}
    for item in scenarios:
        if not item['checks'] or not item['evidenceNeeded'] or not set(item['trackIds']) <= tracks:
            raise ValueError(f'Incomplete scenario: {item["id"]}')
    return catalog


def make_rows(seed: int, groups_per_family: int) -> dict[str, list[dict]]:
    if not 20 <= groups_per_family <= 1000:
        raise ValueError('groups_per_family must be between 20 and 1000')
    rng = random.Random(seed)
    result = {split: [] for split in SPLITS}
    serial = 0
    for family in FAMILIES:
        groups = list(range(groups_per_family))
        rng.shuffle(groups)
        held_count = max(1, groups_per_family * 15 // 100)
        split_by_group = {}
        for index, group in enumerate(groups):
            split_by_group[group] = (SPLITS[1 + index // held_count] if index < held_count * 3 else 'train')
        for group in range(groups_per_family):
            serial += 1
            group_id = f'synthetic-{family}-{group:04d}'
            duration = 600 + serial * 13
            short_wait = rng.randrange(0, 7200, 60)
            long_wait = short_wait + rng.randrange(300, 7200, 60)
            # Counts deliberately do not determine the earliest available device.
            queue_counts = (rng.randint(2, 8), 1) if family == 'queue_count_decoy' else (rng.randint(1, 5), rng.randint(1, 5))
            if family == 'multi_plate_snapshot':
                # A later single-plate snapshot; not a global multi-plate optimizer.
                short_wait += duration * 2
                long_wait += duration * 2
            features = [
                {'max_runs': 1, 'queued_runs': queue_counts[0], 'available_after_seconds': short_wait},
                {'max_runs': 1, 'queued_runs': queue_counts[1], 'available_after_seconds': long_wait},
            ]
            for permutation in (False, True):
                candidates = [{'id': f'sim-device-{index}', 'features': item} for index, item in enumerate(features)]
                if permutation:
                    candidates.reverse()
                request = validate_request({
                    'requestId': f'{group_id}-{int(permutation)}',
                    'plate': {'id': f'sim-plate-{serial}', 'taskId': group_id,
                              'remaining_runs': 9 if family == 'multi_plate_snapshot' else 1,
                              'assigned_runs': 2 if family == 'multi_plate_snapshot' else 0,
                              'completed_runs': 0, 'estimated_seconds': duration,
                              'estimated_grams': 45, 'due_at': None},
                    'candidates': candidates,
                })
                state, questions, mapping = build_question(request)
                selected = next(key for key, value in mapping.items() if value == 'sim-device-0')
                result[split_by_group[group]].append({
                    'state': state, 'questions': questions, 'expected': {'printer': selected},
                    'mifu_provenance': {'source': SOURCE, 'groupId': group_id, 'family': family,
                                        'oracle': 'minimum_known_available_after_seconds_v1'},
                })
    return result


def validate_bundle(root: Path) -> dict:
    manifest = json.loads((root / 'experiment_manifest.json').read_text(encoding='utf-8'))
    if manifest.get('source') != SOURCE or manifest.get('deployable') is not False:
        raise ValueError('Not a pipeline-only experiment bundle')
    group_splits: dict[str, str] = {}
    state_splits: dict[str, str] = {}
    for split in SPLITS:
        path = root / f'{split}.jsonl'
        if digest(path) != manifest['files'][split]['sha256']:
            raise ValueError(f'Dataset hash mismatch: {split}')
        rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
        if not rows or len(rows) != manifest['files'][split]['rows']:
            raise ValueError(f'Invalid row count: {split}')
        for row in rows:
            origin = row.get('mifu_provenance', {})
            if origin.get('source') != SOURCE or not origin.get('groupId'):
                raise ValueError('Missing explicit synthetic provenance')
            group_id = origin['groupId']
            if group_splits.setdefault(group_id, split) != split:
                raise ValueError('Related task/permutation group leaks across splits')
            state_key = json.dumps({'state': row['state'], 'questions': row['questions']}, sort_keys=True)
            if state_splits.setdefault(state_key, split) != split:
                raise ValueError('Identical model input leaks across splits')
            criteria = row['questions']['printer']['criteria']
            if row['expected']['printer'] not in criteria:
                raise ValueError('Expected choice is not one of the provided candidates')
    return manifest


def prepare(output: Path, catalog_path: Path, seed: int = 4070, groups_per_family: int = 40) -> dict:
    catalog = read_catalog(catalog_path)
    datasets = make_rows(seed, groups_per_family)
    output.mkdir(parents=True, exist_ok=False)
    manifest = {'schemaVersion': 1, 'source': SOURCE, 'deployable': False,
                'domainTrainingCompleted': False, 'seed': seed, 'files': {},
                'limitations': ['Only tests known waiting-time comparisons using current input fields.',
                                'Does not teach maintenance, quality, deadlines, or global scheduling.',
                                'Numerical synthetic holdout is not evidence of real factory performance.',
                                'SDK internal calibration is not validated as a production grouped calibration procedure.']}
    for split, rows in datasets.items():
        path = output / f'{split}.jsonl'
        with path.open('x', encoding='utf-8') as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n')
        manifest['files'][split] = {'rows': len(rows), 'sha256': digest(path)}
    (output / 'experiment_manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    (output / 'training_curriculum.json').write_text(json.dumps(catalog, ensure_ascii=False, indent=2), encoding='utf-8')
    coverage = []
    for item in catalog['scenarios']:
        coverage.append({**item, 'status': 'planned_not_verified', 'realReviewedExamples': 0,
                         'trainingRuns': 0, 'evaluationPassed': False})
    (output / 'coverage.json').write_text(json.dumps(coverage, ensure_ascii=False, indent=2), encoding='utf-8')
    lines = ['# Mifu 场景训练与验收准备', '',
             '这是覆盖计划，不是训练完成报告。真实复核样本为0；模拟数据只检查当前单盘等待时间比较的训练管线。', '',
             '| 场景 | 路径 | 输入能力 | 当前状态 |', '| --- | --- | --- | --- |']
    for item in coverage:
        lines.append(f'| {item["id"]} {item["title"]} | {", ".join(item["routes"])} | {item["capability"]} | 待数据/待实现/待验收 |')
    (output / 'coverage.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    review = {'recordId': None, 'scenarioIds': [], 'reviewStatus': 'pending',
              'selectedCandidateId': None, 'acceptableCandidateIds': [],
              'reviewer': None, 'rationale': None, 'evidenceReferences': [],
              'decisionObservedAt': None, 'outcomeObservedAt': None,
              'notice': '模板不是标签。难以判断或多方案均可的样本不强行导出唯一赢家。'}
    (output / 'review_template.json').write_text(json.dumps(review, ensure_ascii=False, indent=2), encoding='utf-8')
    validate_bundle(output)
    return {'output': str(output), 'scenarios': len(coverage), 'tracks': len(catalog['tracks']),
            'syntheticRows': sum(len(rows) for rows in datasets.values()),
            'splitRows': {split: len(rows) for split, rows in datasets.items()},
            'realReviewedRows': 0, 'deployable': False}


def main():
    parser = argparse.ArgumentParser(description='Mifu 离线训练准备；不训练、不下载、不生成正式模型')
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).with_name('training_curriculum.json'))
    parser.add_argument('--seed', type=int, default=4070)
    parser.add_argument('--groups-per-family', type=int, default=40)
    args = parser.parse_args()
    print(json.dumps(prepare(args.out, args.catalog, args.seed, args.groups_per_family), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
