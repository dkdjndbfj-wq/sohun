"""Bounded-memory hardware-conditioned synthetic corpus; never deployable.

Hardware eligibility is relative to a versioned software capability snapshot and
explicit simulated installation/material declarations, not physical validation.
"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
import gzip
import hashlib
import json
from pathlib import Path
import random
import shutil
import sqlite3

SOURCE = 'synthetic_pipeline_only'
SCHEMA = 'mifu-hardware-sim-v3'
ORACLE = 'known_finish_then_preparation_v1'
SPLITS = ('train', 'validation', 'calibration', 'holdout')
MATERIALS = ('PLA', 'PETG')
GATES = ('maintenance', 'nozzle_mismatch', 'model_mismatch', 'empty_roll',
         'faulted_slot', 'unknown_material', 'unverified_connection', 'unknown_fts',
         'unmapped_model', 'unknown_nozzle_material', 'unknown_mixed_ams')


def canonical(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')


def file_hash(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def read_matrix(path: Path) -> tuple[dict, list[tuple]]:
    matrix = json.loads(path.read_text(encoding='utf-8'))
    ams = {item['id']: item for item in matrix['ams_types']}
    combinations = []
    for model in matrix['models']:
        if model.get('verification') != 'software_supported_snapshot':
            continue
        feed = model['feed']
        kinds = list(feed.get('allowed_ams_types', []))
        if feed.get('physical_external_paths', 0) > 0:
            kinds.append('external')
        for diameter in model['nozzle_diameters_mm']:
            for kind in kinds:
                if kind == 'external':
                    limit, slots = 1, 1
                elif kind in ams:
                    group = ams[kind]['quota_group']
                    limit = feed.get({'four_slot': 'four_slot_combined_max', 'ht': 'ht_max', 'lite': 'lite_max'}[group], 0)
                    limit = min(limit, feed.get('regular_units_max', limit)) if group != 'lite' else limit
                    slots = ams[kind]['slots']
                else:
                    continue
                if isinstance(limit, int) and limit > 0:
                    combinations.append((model['id'], diameter, kind, limit, slots))
    if not combinations:
        raise ValueError('No explicitly supported hardware combinations')
    return matrix, combinations


def group_split(seed: int, episode: int) -> str:
    # All snapshots and permutations of an episode share this assignment.
    bucket = int.from_bytes(hashlib.sha256(f'{seed}:{episode}'.encode()).digest()[:8], 'big') % 100
    return 'train' if bucket < 70 else SPLITS[1 + (bucket - 70) // 10]


def material_demand(task: dict, device: dict) -> Counter:
    demand = Counter()
    for item in task['tools']:
        demand[device['resource_slots'][item['resource']]] += item['grams']
    return demand


def admission(task: dict, device: dict) -> list[str]:
    reasons = []
    if device['model'] != task['target_model'] or device.get('unmapped_model'):
        reasons.append('exact_model_mismatch_or_unmapped')
    if device['nozzle_mm'] != task['nozzle_mm']:
        reasons.append('exact_nozzle_mismatch')
    if device['nozzle_material'] not in ('stainless_steel', 'hardened_steel'):
        reasons.append('nozzle_material_unverified')
    if device.get('maintenance'):
        reasons.append('maintenance_lock')
    if not device['feed']['connection_confirmed']:
        reasons.append('connection_or_firmware_unverified')
    if device['feed'].get('fts') or device['feed'].get('mixed_unverified'):
        reasons.append('feed_topology_unverified')
    if task['material'] not in MATERIALS or device['material_declaration'] != 'synthetic_declared_material_compatibility':
        reasons.append('requires_verified_material_path')
    demand = material_demand(task, device)
    if device['feed']['kind'] == 'external' and len(task['tools']) != 1:
        reasons.append('external_single_tool_only')
    for slot in demand:
        if slot < 0 or slot >= device['feed']['slots'] or slot in device['faulted_slots']:
            reasons.append('feed_slot_unavailable')
    for slot, grams in demand.items():
        roll = device['rolls'].get(str(slot))
        if roll is None:
            reasons.append('feed_slot_unavailable')
            continue
        free = roll['remaining_g'] - roll['reserved_g']
        if free <= 30 or grams + max(5, grams * .1) > free + .001:
            reasons.append('insufficient_unreserved_material')
    return sorted(set(reasons))


def max_runs(task: dict, device: dict) -> int:
    demand = material_demand(task, device)
    for runs in range(task['remaining_runs'], 0, -1):
        if all(str(slot) in device['rolls'] and grams * runs + max(5, grams * runs * .1) <= device['rolls'][str(slot)]['remaining_g'] - device['rolls'][str(slot)]['reserved_g'] + .001
               and device['rolls'][str(slot)]['remaining_g'] - device['rolls'][str(slot)]['reserved_g'] - grams * (runs - 1) > 30
               for slot, grams in demand.items()):
            return runs
    return 0


def episode_state(combo: tuple, rng: random.Random, candidates: int,
                  alternatives: tuple | list = ()) -> tuple[dict, list[dict]]:
    model, nozzle, kind, limit, per_unit_slots = combo
    units = rng.randint(1, limit)
    slots = units * per_unit_slots
    tool_count = 1 if kind == 'external' else rng.randint(1, min(2, slots))
    # Some two-tool tasks intentionally share one physical roll; demands aggregate.
    resource_count = 1 if tool_count == 1 or rng.random() < .25 else 2
    task = {'target_model': model, 'nozzle_mm': nozzle, 'material': rng.choice(MATERIALS),
            'color': rng.choice(('#000000', '#FFFFFF', '#FF0000', '#0066CC')),
            'estimated_seconds': rng.randint(600, 14400), 'remaining_runs': rng.randint(3, 9),
            'tools': [{'tool': index, 'resource': f'resource_{index % resource_count}',
                       'grams': rng.randint(10, 45)} for index in range(tool_count)]}
    supported = [item for item in alternatives if item[:2] == combo[:2]
                 and (item[2] != 'external' or tool_count == 1)
                 and item[3] * item[4] >= resource_count]
    if not supported:
        supported = [combo]
    devices = []
    for index in range(candidates):
        if index:
            different = [item for item in supported if item[2] != devices[0]['feed']['kind']]
            candidate_combo = rng.choice(different if different and rng.random() < .8 else supported)
            _, _, kind, limit, per_unit_slots = candidate_combo
            minimum_units = (resource_count + per_unit_slots - 1) // per_unit_slots
            units = rng.randint(minimum_units, limit)
            slots = units * per_unit_slots
        selected_slots = rng.sample(range(slots), resource_count)
        unused = [slot for slot in range(slots) if slot not in selected_slots]
        faulted = rng.sample(unused, min(len(unused), rng.randint(0, 2)))
        devices.append({'model': model, 'nozzle_mm': nozzle,
                        'nozzle_material': rng.choice(('stainless_steel', 'hardened_steel')),
                        'feed': {'kind': kind, 'units': units, 'slots': slots,
                                 'connection_confirmed': True, 'fts': False, 'mixed_unverified': False},
                        'material_declaration': 'synthetic_declared_material_compatibility',
                        'maintenance': False, 'faulted_slots': faulted,
                        'resource_slots': {f'resource_{i}': slot for i, slot in enumerate(selected_slots)},
                        'wait_s': rng.randint(0, 30000), 'setup_s': rng.randint(0, 1800),
                        'rolls': {str(slot): {'capacity_g': 1000, 'remaining_g': rng.randint(400, 1000),
                                         'reserved_g': rng.randint(0, 100)} for slot in set(selected_slots)}})
    return task, devices


def features(task: dict, device: dict) -> dict:
    materials = []
    for item in task['tools']:
        slot = device['resource_slots'][item['resource']]
        roll = device['rolls'][str(slot)]
        materials.append({'tool': item['tool'], 'slot': slot, 'resource': item['resource'],
                          'grams': item['grams'], 'free_g': roll['remaining_g'] - roll['reserved_g']})
    return {'model': device['model'], 'nozzle_mm': device['nozzle_mm'],
            'nozzle_material': device['nozzle_material'],
            'feed': {'kind': device['feed']['kind'], 'units': device['feed']['units'],
                     'slots': device['feed']['slots'], 'usable_slots': device['feed']['slots'] - len(device['faulted_slots'])},
            'wait_s': device['wait_s'], 'setup_s': device['setup_s'],
            'run_s': task['estimated_seconds'], 'max_runs': max_runs(task, device), 'materials': materials}


def gate_case(task: dict, device: dict, index: int) -> dict:
    kind = GATES[index % len(GATES)]
    changed_task, changed = copy.deepcopy(task), copy.deepcopy(device)
    first_slot = changed['resource_slots'][task['tools'][0]['resource']]
    if kind == 'maintenance': changed['maintenance'] = True
    elif kind == 'nozzle_mismatch': changed['nozzle_mm'] = .4 if task['nozzle_mm'] != .4 else .6
    elif kind == 'model_mismatch': changed['model'] = 'different_slice_target'
    elif kind == 'empty_roll': changed['rolls'][str(first_slot)].update(remaining_g=30, reserved_g=0)
    elif kind == 'faulted_slot': changed['faulted_slots'].append(first_slot)
    elif kind == 'unknown_material': changed_task['material'] = ('TPU', 'PA-CF', 'support_material')[index % 3]
    elif kind == 'unverified_connection': changed['feed']['connection_confirmed'] = False
    elif kind == 'unknown_fts': changed['feed']['fts'] = True
    elif kind == 'unmapped_model': changed['model'], changed['unmapped_model'] = 'H3C', True
    elif kind == 'unknown_nozzle_material': changed['nozzle_material'] = 'unknown'
    elif kind == 'unknown_mixed_ams': changed['feed']['mixed_unverified'] = True
    return {'scenario': kind, 'task': changed_task, 'device': changed,
            'expected_admission': 'blocked_or_unverified', 'reasons': admission(changed_task, changed)}


class Shards:
    def __init__(self, root: Path, name: str, shard_rows: int):
        self.root, self.name, self.limit = root, name, shard_rows
        self.records, self.rows, self.count = [], 0, 0
        self.raw = self.zip = self.path = None

    def write(self, row: dict):
        if self.zip is None:
            self.path = self.root / f'{self.name}-{len(self.records):05d}.jsonl.gz'
            self.raw = self.path.open('xb')
            self.zip = gzip.GzipFile(filename='', mode='wb', fileobj=self.raw, compresslevel=1, mtime=0)
        self.zip.write(canonical(row) + b'\n')
        self.rows += 1
        self.count += 1
        if self.rows >= self.limit:
            self.close()

    def close(self):
        if self.zip is not None:
            self.zip.close()
            self.raw.close()
            self.records.append({'path': self.path.name, 'rows': self.rows,
                                 'bytes': self.path.stat().st_size, 'sha256': file_hash(self.path)})
            self.raw = self.zip = self.path = None
            self.rows = 0


def generate(output: Path, matrix_path: Path, rows: int = 1_000_000, seed: int = 4070,
             shard_rows: int = 20_000, candidates: int = 2, probe_every: int = 100) -> dict:
    if rows < 1 or shard_rows < 2 or not 2 <= candidates <= 4 or probe_every < 0:
        raise ValueError('rows must be positive; shard_rows >= 2; candidates must be 2..4; probe_every >= 0')
    matrix, combos = read_matrix(matrix_path)
    output.mkdir(parents=True, exist_ok=False)
    shutil.copyfile(matrix_path, output / 'hardware_matrix.json')
    writers = {name: Shards(output, name, shard_rows) for name in (*SPLITS, 'gate_cases', 'permutation_probes')}
    db = sqlite3.connect(output / 'audit.sqlite')
    db.execute('PRAGMA cache_size=-4096')
    db.execute('CREATE TABLE inputs(signature TEXT PRIMARY KEY, episode INTEGER, split TEXT)')
    written = episode = unique = duplicates = max_bytes = cross_topology = candidate_observations = 0
    coverage = {key: Counter() for key in ('models', 'nozzles', 'ams_types', 'ams_units', 'materials', 'slot_counts',
                                          'candidate_hardware_combinations', 'gate_reasons')}
    by_slice = {}
    for combo in combos:
        by_slice.setdefault(combo[:2], []).append(combo)
    try:
        while written < rows:
            rng = random.Random((seed << 32) + episode)
            combo = combos[episode % len(combos)]
            task, devices = episode_state(combo, rng, candidates, by_slice[combo[:2]])
            split = group_split(seed, episode)
            gate = gate_case(task, devices[0], episode)
            if not gate['reasons']:
                raise AssertionError('Negative gate fixture unexpectedly passed admission')
            gate['mifu_provenance'] = {'source': SOURCE, 'episode': episode, 'split': split,
                                       'dataset_kind': 'admission_test', 'hardware_schema': SCHEMA}
            writers['gate_cases'].write(gate)
            coverage['gate_reasons'].update(gate['reasons'])
            for step in range(3):
                eligible = [device for device in devices if not admission(task, device) and max_runs(task, device) > 0]
                if len(eligible) < 2:
                    break
                costs = [(device['wait_s'] + device['setup_s'] + task['estimated_seconds'], device['setup_s']) for device in eligible]
                best = min(costs)
                if costs.count(best) != 1:
                    break  # Ambiguous labels are not forced into a unique winner.
                winner = costs.index(best)
                compiled = [features(task, device) for device in eligible]
                plate = {key: value for key, value in task.items() if key != 'tools'}
                plate['tools'] = task['tools']
                signature = hashlib.sha256(canonical({'plate': plate, 'candidates': sorted(compiled, key=canonical)})).hexdigest()
                inserted = db.execute('INSERT OR IGNORE INTO inputs VALUES (?,?,?)', (signature, episode, split)).rowcount
                if inserted:
                    unique += 1
                    base_order = list(range(len(eligible)))
                    rng.shuffle(base_order)
                    orders = [base_order]
                    if probe_every and unique % probe_every == 0:
                        orders.append(base_order[1:] + base_order[:1])
                    for variant, order in enumerate(orders):
                        state = {'featureSchemaVersion': SCHEMA, 'objective': ORACLE,
                                 'plate': plate, 'candidates': {f'candidate_{i:02d}': compiled[j] for i, j in enumerate(order)}}
                        criteria = {key: key for key in state['candidates']}
                        row = {'state': state, 'questions': {'printer': {'type': 'choice',
                               'instructions': '选择已合格候选中预计完成时间最早者；完成时间相同时优先准备时间更短者。', 'criteria': criteria}},
                               'expected': {'printer': f'candidate_{order.index(winner):02d}'},
                               'mifu_provenance': {'source': SOURCE, 'dataset_kind': 'hardware_scheduling_simulation',
                                   'hardware_schema': SCHEMA, 'episode': episode, 'step': step, 'variant': variant,
                                   'split': split, 'oracle': ORACLE, 'independent_input_sha256': signature,
                                   'material_evidence': 'synthetic_declared_material_compatibility'},
                               'audit': {'selected_physical_candidate': winner, 'candidate_order': order,
                                         'costs_in_physical_order': costs, 'state_before': eligible}}
                        max_bytes = max(max_bytes, len(canonical(state)))
                        writers[split if variant == 0 else 'permutation_probes'].write(row)
                        if variant == 0:
                            written += 1
                    for device in eligible:
                        feed = device['feed']
                        hardware_key = f"{device['model']}|{device['nozzle_mm']}|{feed['kind']}|{feed['units']}|{feed['slots']}"
                        for key, value in (('models', device['model']), ('nozzles', str(device['nozzle_mm'])),
                                           ('ams_types', feed['kind']), ('ams_units', str(feed['units'])),
                                           ('slot_counts', str(feed['slots'])), ('candidate_hardware_combinations', hardware_key)):
                            coverage[key][value] += 1  # Every candidate in main decisions, excluding probes.
                    candidate_observations += len(eligible)
                    cross_topology += len({(device['feed']['kind'], device['feed']['units']) for device in eligible}) > 1
                    coverage['materials'][task['material']] += 1
                else:
                    duplicates += 1
                # Reserve exact simulated demand; buffer remains a gate, not consumption.
                selected = eligible[winner]
                for slot, grams in material_demand(task, selected).items():
                    selected['rolls'][str(slot)]['reserved_g'] += grams
                selected['wait_s'] = best[0]
                selected['setup_s'] = 0
                task['remaining_runs'] -= 1
                if written >= rows:
                    break
            episode += 1
            if episode % 1000 == 0:
                db.commit()
            if written and written % 10000 == 0:
                print(json.dumps({'rows': written, 'episodes': episode, 'unique_decisions': unique}), flush=True)
        db.commit()
    finally:
        for writer in writers.values():
            writer.close()
        db.close()
    manifest = {'schemaVersion': 1, 'source': SOURCE, 'datasetKind': 'hardware_scheduling_simulation',
                'featureSchemaVersion': SCHEMA, 'deployable': False, 'domainTrainingCompleted': False,
                'seed': seed, 'choiceRows': written, 'independentDecisions': unique,
                'permutationControlRows': writers['permutation_probes'].count,
                'probeEverySemanticDecisions': probe_every, 'episodeGroups': episode,
                'crossTopologyDecisionCount': cross_topology, 'candidateObservations': candidate_observations,
                'coverageCountUnits': {'hardware': 'candidate_observations_in_main_decisions',
                                       'materials': 'main_decisions', 'gate_reasons': 'gate_cases'},
                'rawCases': unique + writers['gate_cases'].count, 'hardGateCases': writers['gate_cases'].count,
                'duplicateIndependentInputsSkipped': duplicates,
                'hardwareMatrixSha256': file_hash(output / 'hardware_matrix.json'), 'hardwareSources': matrix.get('sources', []),
                'auditIndex': {'path': 'audit.sqlite', 'sha256': file_hash(output / 'audit.sqlite')},
                'hardwareCombinationsAvailable': len(combos), 'coverage': {key: dict(value) for key, value in coverage.items()},
                'splits': {name: {'rows': writer.count, 'shards': writer.records} for name, writer in writers.items()},
                'oracle': {'version': ORACLE, 'scope': 'one_known_step_finish_then_setup', 'globalOptimalityProven': False},
                'tokenBudget': {'status': 'pending_actual_sdk_tokenization', 'maxStateBytes': max_bytes,
                                'candidateText': 'short_neutral_labels_only', 'maxCandidates': candidates},
                'trainingLimits': {'sdkIsStreaming': False, 'recommendedFirstStratifiedSubsetRows': 10000,
                                   'fullCorpusTrainingReady': False, 'onlineServiceSchemaCompatible': False},
                'limitations': ['All records are synthetic; no real throughput or failure-rate improvement is established.',
                                'PLA/PETG compatibility, installed parts, connection and firmware are explicitly declared simulation conditions.',
                                'Other materials, unknown nozzle material, FTS, H3C and unverified mixed AMS topologies are gate fixtures, not supported choice coverage.',
                                'Current online service requires a separate feature-layout migration before these inputs can be used.',
                                'Compared devices share exact slice-model and nozzle diameter, but may use different declared legal single-kind AMS topologies and slot mappings.',
                                'Labels teach known finish/setup ranking; topology variation does not establish learned hardware eligibility or hardware-specific speed.',
                                'One million distinct numeric snapshots do not represent one million independent real-world operating conditions.',
                                'Detailed scenario coverage does not prove global multi-task scheduling optimality or real maintenance/quality predictions.']}
    (output / 'manifest.json').write_bytes(canonical(manifest) + b'\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description='Stream a hardware-conditioned synthetic Mifu corpus; does not train.')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--matrix', type=Path, default=Path(__file__).with_name('hardware_matrix.json'))
    parser.add_argument('--rows', type=int, default=1_000_000)
    parser.add_argument('--seed', type=int, default=4070)
    parser.add_argument('--shard-rows', type=int, default=20000)
    parser.add_argument('--candidates', type=int, default=2)
    parser.add_argument('--probe-every', type=int, default=100, help='Separate reorder control every N semantic rows; 0 disables')
    args = parser.parse_args()
    result = generate(args.out, args.matrix, args.rows, args.seed, args.shard_rows, args.candidates, args.probe_every)
    print(json.dumps({key: result[key] for key in ('choiceRows', 'independentDecisions', 'episodeGroups', 'hardGateCases', 'deployable')}, indent=2))


if __name__ == '__main__':
    main()
