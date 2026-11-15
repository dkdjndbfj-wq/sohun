from __future__ import annotations

import gzip
from contextlib import closing
import json
from pathlib import Path
import random
import sqlite3
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from large_dataset import GATES, SCHEMA, SOURCE, SPLITS, admission, episode_state, file_hash, gate_case, generate


class LargeDatasetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.matrix = self.root / 'matrix.json'
        self.matrix.write_text(json.dumps({'sources': [{'id': 'test_fixture', 'kind': 'unit_test_only'}],
            'ams_types': [{'id': 'ams', 'slots': 4, 'quota_group': 'four_slot'},
                          {'id': 'ams_lite', 'slots': 4, 'quota_group': 'lite'}],
            'models': [{'id': 'test-printer', 'verification': 'software_supported_snapshot',
                        'nozzle_diameters_mm': [.2, .4], 'feed': {'allowed_ams_types': ['ams'],
                        'four_slot_combined_max': 2, 'regular_units_max': 2, 'physical_external_paths': 1}},
                       {'id': 'test-printer-lite', 'verification': 'software_supported_snapshot',
                        'nozzle_diameters_mm': [.4], 'feed': {'allowed_ams_types': ['ams_lite'],
                        'lite_max': 1, 'physical_external_paths': 1}}]}), encoding='utf-8')

    def tearDown(self):
        self.temp.cleanup()

    def rows(self, root, manifest, split):
        for shard in manifest['splits'][split]['shards']:
            with gzip.open(root / shard['path'], 'rt', encoding='utf-8') as handle:
                yield from (json.loads(line) for line in handle)

    def test_streaming_shards_groups_and_neutral_head_labels(self):
        out = self.root / 'dataset'
        result = generate(out, self.matrix, rows=120, shard_rows=10)
        self.assertEqual(120, result['choiceRows'])
        self.assertEqual(120, result['independentDecisions'])
        self.assertEqual(1, result['permutationControlRows'])
        groups = {}
        for split in SPLITS:
            for shard in result['splits'][split]['shards']:
                self.assertLessEqual(shard['rows'], 10)
                self.assertEqual(shard['sha256'], file_hash(out / shard['path']))
            for row in self.rows(out, result, split):
                meta = row['mifu_provenance']
                self.assertEqual(SOURCE, meta['source'])
                self.assertEqual(split, groups.setdefault(meta['episode'], split))
                self.assertEqual(SCHEMA, row['state']['featureSchemaVersion'])
                self.assertEqual({key: key for key in row['state']['candidates']}, row['questions']['printer']['criteria'])
                self.assertLess(max(map(len, row['questions']['printer']['criteria'].values())), 48)
                selected = row['expected']['printer']
                features = row['state']['candidates']
                costs = {key: (value['wait_s'] + value['setup_s'] + value['run_s'], value['setup_s']) for key, value in features.items()}
                self.assertEqual(min(costs, key=costs.get), selected)
        self.assertFalse(result['deployable'])
        self.assertFalse(result['trainingLimits']['sdkIsStreaming'])
        with closing(sqlite3.connect(out / 'audit.sqlite')) as db:
            self.assertEqual(120, db.execute('SELECT count(*) FROM inputs').fetchone()[0])

    def test_odd_row_count_and_separate_permutation_controls(self):
        out = self.root / 'dataset'
        result = generate(out, self.matrix, rows=31, probe_every=5)
        records = [row for split in SPLITS for row in self.rows(out, result, split)]
        self.assertEqual(31, len(records))
        self.assertEqual(31, result['independentDecisions'])
        originals = {row['mifu_provenance']['independent_input_sha256']: row for row in records}
        controls = list(self.rows(out, result, 'permutation_probes'))
        self.assertEqual(6, len(controls))
        for row in controls:
            base = originals[row['mifu_provenance']['independent_input_sha256']]
            self.assertEqual(base['mifu_provenance']['split'], row['mifu_provenance']['split'])
            self.assertEqual(base['mifu_provenance']['episode'], row['mifu_provenance']['episode'])
            self.assertNotEqual(base['audit']['candidate_order'], row['audit']['candidate_order'])
            base_winner = base['state']['candidates'][base['expected']['printer']]
            self.assertEqual(base_winner, row['state']['candidates'][row['expected']['printer']])

    def test_gate_fixtures_never_enter_choice_and_all_have_reasons(self):
        out = self.root / 'dataset'
        result = generate(out, self.matrix, rows=132, shard_rows=12)
        fixtures = list(self.rows(out, result, 'gate_cases'))
        self.assertEqual(set(GATES), {row['scenario'] for row in fixtures})
        self.assertTrue(all(row['reasons'] for row in fixtures))
        for split in SPLITS:
            for row in self.rows(out, result, split):
                for device in row['audit']['state_before']:
                    task = dict(row['state']['plate'])
                    self.assertEqual([], admission(task, device))

    def test_candidates_use_distinct_supported_topologies_and_physical_mappings(self):
        out = self.root / 'dataset'
        result = generate(out, self.matrix, rows=300)
        self.assertGreater(result['crossTopologyDecisionCount'], 0)
        self.assertEqual(600, result['candidateObservations'])
        self.assertEqual(600, sum(result['coverage']['ams_types'].values()))
        distinct_topology = distinct_mapping = 0
        for split in SPLITS:
            for row in self.rows(out, result, split):
                task = row['state']['plate']
                devices = row['audit']['state_before']
                distinct_topology += len({(d['feed']['kind'], d['feed']['units']) for d in devices}) > 1
                distinct_mapping += len({tuple(d['resource_slots'].values()) for d in devices}) > 1
                for device in devices:
                    self.assertEqual([], admission(task, device))
                    self.assertEqual(task['target_model'], device['model'])
                    self.assertEqual(task['nozzle_mm'], device['nozzle_mm'])
                    if device['feed']['kind'] == 'external':
                        self.assertEqual(1, len(task['tools']))
        self.assertEqual(result['crossTopologyDecisionCount'], distinct_topology)
        self.assertGreater(distinct_mapping, 0)

    def test_reproducible_gzip_and_no_overwrite(self):
        first, second = self.root / 'a', self.root / 'b'
        a = generate(first, self.matrix, rows=60, shard_rows=8)
        b = generate(second, self.matrix, rows=60, shard_rows=8)
        self.assertEqual(a, b)
        with self.assertRaises(FileExistsError):
            generate(first, self.matrix, rows=60)

    def test_material_and_nozzle_unknowns_do_not_silently_pass(self):
        task, devices = episode_state(('test', .4, 'ams', 1, 4), random.Random(1), 2)
        self.assertEqual([], admission(task, devices[0]))
        for index in range(len(GATES)):
            case = gate_case(task, devices[0], index)
            self.assertTrue(case['reasons'])

    def test_state_updates_reserve_same_spool_and_advance_queue(self):
        out = self.root / 'dataset'
        result = generate(out, self.matrix, rows=60, shard_rows=20)
        records = [row for split in SPLITS for row in self.rows(out, result, split)]
        firsts = {(row['mifu_provenance']['episode'], row['mifu_provenance']['step']): row
                  for row in records if row['mifu_provenance']['variant'] == 0}
        checked = 0
        for (episode, step), row in firsts.items():
            next_row = firsts.get((episode, step + 1))
            if not next_row:
                continue
            chosen = row['audit']['selected_physical_candidate']
            before = row['audit']['state_before'][chosen]
            after = next_row['audit']['state_before'][chosen]
            self.assertGreater(after['wait_s'], before['wait_s'])
            self.assertGreater(sum(item['reserved_g'] for item in after['rolls'].values()),
                               sum(item['reserved_g'] for item in before['rolls'].values()))
            self.assertEqual(sum(item['remaining_g'] for item in before['rolls'].values()),
                             sum(item['remaining_g'] for item in after['rolls'].values()))
            checked += 1
        self.assertGreater(checked, 0)

    def test_bad_parameters_fail_before_output_creation(self):
        for kwargs in ({'rows': -1}, {'rows': 0}, {'rows': 2, 'candidates': 5}, {'rows': 2, 'shard_rows': 0}, {'probe_every': -1}):
            out = self.root / 'never_created'
            with self.assertRaises(ValueError):
                generate(out, self.matrix, **kwargs)
            self.assertFalse(out.exists())


if __name__ == '__main__':
    unittest.main()
