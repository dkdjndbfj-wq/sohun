from __future__ import annotations

from collections import Counter, defaultdict
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bed_geometry import polygon, signed_area
from geometry_challenges import (FIXTURE_TYPE, check_case, encoded, file_hash,
                                 generate_bundle, iter_cases)


class GeometryChallengeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = list(iter_cases())

    def test_all_constructed_expectations_match_geometry_gate(self):
        for row in self.rows:
            with self.subTest(family=row['family'], variant=row['variant'], context=row['construction_group']):
                check_case(row)

    def test_unique_inputs_geometry_coverage_and_determinism(self):
        self.assertTrue(1000 <= len(self.rows) <= 10000)
        self.assertEqual(len(self.rows), len({row['case_id'] for row in self.rows}))
        self.assertGreaterEqual(len({row['geometry_layout_id'] for row in self.rows}), 1000)
        self.assertEqual([encoded(row) for row in self.rows], [encoded(row) for row in iter_cases()])

    def test_expected_labels_are_synthetic_layer_only_and_not_rankings(self):
        for row in self.rows:
            self.assertEqual(FIXTURE_TYPE, row['type'])
            self.assertEqual('synthetic_contract_expectation', row['expected']['label_origin'])
            self.assertFalse(row['expected']['automatic_dispatch_authorized'])
            self.assertEqual('fixed_plate_geometry_only', row['expected']['scope'])
            self.assertEqual('invented_test_fixture_not_manufacturer', row['context']['dimensions_source'])
            self.assertNotIn('state', row)
            self.assertNotIn('options', row)

    def test_equal_area_partners_have_different_fit_outcomes(self):
        grouped = defaultdict(list)
        for row in self.rows:
            if row['family'] == 'equal_area':
                grouped[row['construction_group']].append(row)
        self.assertEqual(24, len(grouped))
        for pair in grouped.values():
            self.assertEqual({'allow', 'blocked'}, {row['expected']['status'] for row in pair})
            areas = [abs(signed_area(polygon(row['input']['plate']['footprints'][0]['polygon']))) for row in pair]
            self.assertAlmostEqual(areas[0], areas[1], places=7)

    def test_unknowns_cover_all_requested_missing_evidence(self):
        required = {'missing_or_mismatched_evidence', 'auxiliary_evidence', 'unsupported_topology',
                    'tool_evidence', 'invalid_polygon', 'invalid_coordinate'}
        families = {row['family'] for row in self.rows if row['expected']['status'] == 'requires_verification'}
        self.assertTrue(required <= families)
        statuses = Counter(row['expected']['status'] for row in self.rows)
        self.assertEqual({'allow', 'blocked', 'requires_verification'}, set(statuses))

    def test_tampered_identity_or_expectation_is_rejected(self):
        changed = copy.deepcopy(self.rows[0])
        changed['input']['plate']['selected_plate_index'] = 2
        with self.assertRaises(ValueError):
            check_case(changed)
        changed = copy.deepcopy(self.rows[0])
        changed['expected']['status'] = 'blocked'
        with self.assertRaises(AssertionError):
            check_case(changed)

    def test_bundle_reports_actual_counts_hashes_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'bundle'
            manifest = generate_bundle(destination)
            actual_rows = [json.loads(line) for line in (destination / 'geometry-challenges.jsonl').read_text(encoding='utf-8').splitlines()]
            self.assertEqual(len(actual_rows), manifest['count'])
            self.assertEqual(dict(Counter(row['expected']['status'] for row in actual_rows)), manifest['status_counts'])
            self.assertEqual(file_hash(destination / manifest['file']['name']), manifest['file']['sha256'])
            self.assertFalse(manifest['deployable'])
            self.assertFalse(manifest['ranking_training_data'])
            self.assertEqual(0, manifest['real_observations'])
            self.assertTrue(manifest['verification']['all_rows_executed'])
            with self.assertRaises(FileExistsError):
                generate_bundle(destination)


if __name__ == '__main__':
    unittest.main()
