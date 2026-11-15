import gzip
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from large_dataset import generate, SPLITS
from prepare_large_experiment import prepare
from prepare_curriculum import validate_bundle


class LargeExperimentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.matrix = self.root / 'matrix.json'
        self.matrix.write_text(json.dumps({'sources': {},
            'ams_types': [{'id': 'ams', 'slots': 4, 'quota_group': 'four_slot'}],
            'models': [{'id': 'fixture', 'verification': 'software_supported_snapshot',
                        'nozzle_diameters_mm': [.4], 'feed': {'allowed_ams_types': ['ams'],
                        'four_slot_combined_max': 2, 'regular_units_max': 2, 'physical_external_paths': 1}}]}))
        self.source = self.root / 'source'
        self.manifest = generate(self.source, self.matrix, rows=600, shard_rows=30)

    def tearDown(self):
        self.temp.cleanup()

    def test_subset_keeps_source_splits_and_never_selects_probes(self):
        output = self.root / 'subset'
        report = prepare(self.source, output, 5, 2)
        validate_bundle(output)
        source_groups = {}
        for split in SPLITS:
            for shard in self.manifest['splits'][split]['shards']:
                with gzip.open(self.source / shard['path'], 'rt', encoding='utf-8') as handle:
                    for line in handle:
                        row = json.loads(line)
                        source_groups[row['mifu_provenance']['episode']] = split
            rows = [json.loads(line) for line in (output / f'{split}.jsonl').read_text(encoding='utf-8').splitlines()]
            self.assertEqual((5 if split == 'train' else 2) * 2, len(rows))
            for row in rows:
                meta = row['mifu_provenance']
                self.assertEqual(split, source_groups[meta['episode']])
                self.assertEqual(0, meta['variant'])
                self.assertNotIn('audit', row)
                self.assertTrue(meta['groupId'])
        self.assertFalse(report['deployable'])
        self.assertFalse(report['onlineServiceSchemaCompatible'])

    def test_corrupted_shard_fails_without_creating_output(self):
        shard = self.source / self.manifest['splits']['train']['shards'][0]['path']
        with shard.open('ab') as handle:
            handle.write(b'corrupt')
        output = self.root / 'never'
        with self.assertRaises(ValueError):
            prepare(self.source, output)
        self.assertFalse(output.exists())

    def test_limits_and_existing_directory_are_rejected(self):
        output = self.root / 'subset'
        with self.assertRaises(ValueError):
            prepare(self.source, output, 101, 1)
        output.mkdir()
        with self.assertRaises(FileExistsError):
            prepare(self.source, output)


if __name__ == '__main__':
    unittest.main()
