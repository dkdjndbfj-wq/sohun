import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from decision_contract import from_simulation_row, normalize_request
from large_dataset import file_hash
from prepare_compact_experiment import COUNTS, prepare, validate_row


class CompactExperimentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.matrix = self.root / 'matrix.json'
        self.matrix.write_text(json.dumps({'ams_types': [{'id': 'ams', 'slots': 4, 'quota_group': 'four_slot'}],
            'models': [{'id': 'fixture', 'verification': 'software_supported_snapshot', 'nozzle_diameters_mm': [.4],
                        'feed': {'allowed_ams_types': ['ams'], 'four_slot_combined_max': 2,
                                 'regular_units_max': 2, 'physical_external_paths': 1}}]}), encoding='utf-8')
        self.sizes = {'train': 40, 'validation': 16, 'calibration': 8, 'holdout': 8}

    def tearDown(self):
        self.temp.cleanup()

    def test_balanced_counts_unique_episodes_labels_and_projection(self):
        out = self.root / 'bundle'
        manifest = prepare(out, self.matrix, sizes=self.sizes)
        groups, signatures = set(), set()
        for split, size in self.sizes.items():
            self.assertEqual({str(c): size // 4 for c in COUNTS}, manifest['coverage'][split]['candidateCounts'])
            path = out / f'{split}.jsonl'
            self.assertEqual(file_hash(path), manifest['files'][split]['sha256'])
            rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
            self.assertEqual(size, len(rows))
            for row in rows:
                validate_row(row)
                meta = row['mifu_provenance']
                self.assertEqual(split, meta['split'])
                self.assertTrue(meta['groupId'].startswith('compact-20261112-'))
                self.assertNotIn(meta['groupId'], groups)
                self.assertNotIn(meta['independent_input_sha256'], signatures)
                groups.add(meta['groupId'])
                signatures.add(meta['independent_input_sha256'])
                projected = normalize_request(from_simulation_row(row), now_epoch_s=0)
                self.assertNotIn('expected', json.dumps(projected['state']))
        self.assertEqual(sum(self.sizes.values()), len(groups))
        self.assertFalse(manifest['previousCorpusOrHoldoutRead'])
        self.assertFalse(manifest['deployable'])
        self.assertTrue(manifest['rawInputIsNotSdkReady'])

    def test_reproducible_and_no_overwrite(self):
        first = prepare(self.root / 'a', self.matrix, sizes=self.sizes)
        second = prepare(self.root / 'b', self.matrix, sizes=self.sizes)
        self.assertEqual(first, second)
        with self.assertRaises(FileExistsError):
            prepare(self.root / 'a', self.matrix, sizes=self.sizes)

    def test_bad_counts_rejected_before_creation(self):
        for count in (0, 3, 5, True):
            sizes = dict(self.sizes, train=count)
            with self.assertRaises(ValueError):
                prepare(self.root / 'absent', self.matrix, sizes=sizes)
            self.assertFalse((self.root / 'absent').exists())

    def test_changed_target_is_rejected(self):
        prepare(self.root / 'a', self.matrix, sizes=self.sizes)
        row = json.loads((self.root / 'a/train.jsonl').read_text(encoding='utf-8').splitlines()[0])
        other = next(key for key in row['state']['candidates'] if key != row['expected']['printer'])
        row['expected']['printer'] = other
        with self.assertRaisesRegex(ValueError, 'target'):
            validate_row(row)


if __name__ == '__main__':
    unittest.main()
