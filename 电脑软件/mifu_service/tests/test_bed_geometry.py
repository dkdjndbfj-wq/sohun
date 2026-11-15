from __future__ import annotations

import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bed_geometry import EPSILON_MM, evaluate_bed_geometry


def rect(x1, y1, x2, y2):
    return [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]


def fixtures():
    bed = {'units': 'mm', 'coordinate_frame': 'machine_bed_xy', 'model_id': 'fixture',
        'geometry_verified': True, 'profile_sha256': 'a' * 64, 'representation': 'exact_polygon',
        'printable_polygon': rect(0, 0, 100, 100), 'max_height_mm': 100,
        'exclusion_polygons': [], 'exclusions_complete': True, 'tool_regions_required': False, 'clearance_mm': 0}
    plate = {'units': 'mm', 'coordinate_frame': 'machine_bed_xy', 'target_model_id': 'fixture',
        'artifact_kind': 'pre_sliced', 'post_slice_transform': 'none', 'geometry_verified': True,
        'geometry_artifact_sha256': 'b' * 64, 'artifact_sha256': 'b' * 64,
        'bed_profile_sha256': 'a' * 64, 'plate_index': 1, 'selected_plate_index': 1,
        'min_z_mm': 0, 'max_z_mm': 20, 'print_sequence': 'by_layer',
        'footprint_coverage': 'all_layers', 'z_bounds_representation': 'exact',
        'components': {'object': 'included', 'support': 'verified_absent', 'brim': 'verified_absent',
                       'skirt': 'verified_absent', 'purge_tower': 'verified_absent'},
        'footprints': [{'kind': 'object', 'representation': 'exact_polygon', 'polygon': rect(10, 10, 30, 30)}]}
    return bed, plate


class BedGeometryTests(unittest.TestCase):
    def assert_status(self, expected, bed, plate):
        result = evaluate_bed_geometry(bed, plate)
        self.assertEqual(expected, result['status'], result)
        self.assertFalse(result['automatic_dispatch_authorized'])
        self.assertEqual('fixed_plate_geometry_only', result['scope'])
        return result

    def test_explicit_fixed_layout_passes_without_dispatch_permission(self):
        bed, plate = fixtures()
        result = self.assert_status('allow', bed, plate)
        self.assertFalse(result['reslice_required'])
        self.assertEqual(400, result['metrics']['footprint_polygon_area_sum_mm2'])
        self.assertFalse(result['metrics']['footprint_area_sum_is_union'])

    def test_equal_area_and_narrow_strips_do_not_imply_fit(self):
        bed, plate = fixtures()
        plate['footprints'][0]['polygon'] = rect(1, 1, 21, 91)
        a = self.assert_status('allow', bed, plate)
        plate['footprints'][0]['polygon'] = rect(1, 1, 3, 901)
        b = self.assert_status('blocked', bed, plate)
        self.assertEqual(a['metrics']['footprint_polygon_area_sum_mm2'], b['metrics']['footprint_polygon_area_sum_mm2'])
        plate['footprints'][0]['polygon'] = rect(-1, 49, 101, 51)
        self.assert_status('blocked', bed, plate)

    def test_wrong_location_cannot_be_fixed_by_silently_translating(self):
        bed, plate = fixtures()
        plate['footprints'][0]['polygon'] = rect(90, 90, 110, 110)
        self.assert_status('blocked', bed, plate)

    def test_any_presliced_transform_and_other_model_require_reslicing(self):
        bed, plate = fixtures()
        for operation in ('rotate_90', 'translate', 'scale', {'rotation': 90}):
            changed = copy.deepcopy(plate)
            changed['post_slice_transform'] = operation
            self.assertTrue(self.assert_status('blocked', bed, changed)['reslice_required'])
        plate['target_model_id'] = 'other-fixture'
        self.assertTrue(self.assert_status('blocked', bed, plate)['reslice_required'])

    def test_unsliced_arrangement_can_fit_but_still_requires_slicing(self):
        bed, plate = fixtures()
        plate['artifact_kind'] = 'arrangement_candidate'
        plate['target_model_id'] = 'other-source-model'
        self.assertTrue(self.assert_status('allow', bed, plate)['reslice_required'])

    def test_height_uses_absolute_maximum_z_and_checks_boundary(self):
        bed, plate = fixtures()
        plate['min_z_mm'], plate['max_z_mm'] = 50, 101
        self.assert_status('blocked', bed, plate)
        plate['max_z_mm'] = 100
        self.assert_status('requires_verification', bed, plate)
        plate['max_z_mm'] = 99
        self.assert_status('allow', bed, plate)
        plate['min_z_mm'] = -1
        self.assert_status('blocked', bed, plate)

    def test_exclusion_inside_object_is_detected_without_edge_crossings(self):
        bed, plate = fixtures()
        bed['exclusion_polygons'] = [rect(15, 15, 20, 20)]
        self.assert_status('blocked', bed, plate)

    def test_concave_exclusion_notch_is_distinguished_from_occupied_arms(self):
        bed, plate = fixtures()
        bed['exclusion_polygons'] = [[[40, 40], [70, 40], [70, 50], [50, 50], [50, 70], [40, 70]]]
        plate['footprints'][0]['polygon'] = rect(55, 55, 65, 65)
        self.assert_status('allow', bed, plate)
        plate['footprints'][0]['polygon'] = rect(45, 55, 55, 65)
        self.assert_status('blocked', bed, plate)

    def test_boundary_epsilon_is_unknown_and_clearly_outside_is_blocked(self):
        bed, plate = fixtures()
        for left in (0, -EPSILON_MM / 2, EPSILON_MM / 2):
            plate['footprints'][0]['polygon'] = rect(left, 10, 20, 30)
            self.assert_status('requires_verification', bed, plate)
        plate['footprints'][0]['polygon'] = rect(-2 * EPSILON_MM, 10, 20, 30)
        self.assert_status('blocked', bed, plate)
        plate['footprints'][0]['polygon'] = rect(2 * EPSILON_MM, 10, 20, 30)
        self.assert_status('allow', bed, plate)

    def test_verified_clearance_is_checked_against_edges_and_exclusions(self):
        bed, plate = fixtures()
        bed['clearance_mm'] = 2
        plate['footprints'][0]['polygon'] = rect(1, 10, 20, 30)
        self.assert_status('blocked', bed, plate)
        plate['footprints'][0]['polygon'] = rect(10, 10, 30, 30)
        bed['exclusion_polygons'] = [rect(31, 10, 40, 30)]
        self.assert_status('blocked', bed, plate)
        plate['footprints'][0]['representation'] = 'conservative_outer_bound'
        self.assert_status('requires_verification', bed, plate)

    def test_missing_support_or_tower_evidence_is_unknown(self):
        bed, plate = fixtures()
        for missing in ('support', 'purge_tower'):
            changed = copy.deepcopy(plate)
            del changed['components'][missing]
            self.assert_status('requires_verification', bed, changed)
        plate['components']['purge_tower'] = 'included'
        self.assert_status('requires_verification', bed, plate)
        plate['footprints'].append({'kind': 'purge_tower', 'representation': 'exact_polygon', 'polygon': rect(95, 30, 105, 40)})
        self.assert_status('blocked', bed, plate)

    def test_coarse_outer_bound_cannot_prove_a_collision_but_can_prove_fit(self):
        bed, plate = fixtures()
        plate['footprints'][0]['representation'] = 'conservative_outer_bound'
        self.assert_status('allow', bed, plate)
        plate['footprints'][0]['polygon'] = rect(90, 90, 110, 110)
        self.assert_status('requires_verification', bed, plate)
        plate['footprints'][0]['polygon'] = rect(10, 10, 30, 30)
        bed['exclusion_polygons'] = [rect(15, 15, 20, 20)]
        self.assert_status('requires_verification', bed, plate)

    def test_each_tool_reach_is_checked_and_mapping_must_be_explicit(self):
        bed, plate = fixtures()
        bed.update(tool_regions_required=True, tool_regions_verified=True,
                   tool_regions={'0': rect(0, 0, 60, 100), '1': rect(40, 0, 100, 100)})
        self.assert_status('requires_verification', bed, plate)
        plate['footprints'][0]['tool_id'] = 0
        self.assert_status('allow', bed, plate)
        plate['footprints'][0]['tool_id'] = 1
        self.assert_status('blocked', bed, plate)
        plate['footprints'][0]['tool_id'] = True
        self.assert_status('requires_verification', bed, plate)

    def test_artifact_profile_and_plate_selection_are_bound(self):
        bed, plate = fixtures()
        for key, value in (('geometry_artifact_sha256', 'c' * 64), ('artifact_sha256', None),
                           ('bed_profile_sha256', 'c' * 64), ('selected_plate_index', 2), ('plate_index', True)):
            changed = copy.deepcopy(plate)
            changed[key] = value
            self.assert_status('requires_verification', bed, changed)

    def test_non_mm_coordinate_frame_and_nonfinite_or_boolean_numbers_fail_closed(self):
        bed, plate = fixtures()
        for value in ('cm', 'inch', None):
            changed = dict(plate, units=value)
            self.assert_status('requires_verification', bed, changed)
        self.assert_status('requires_verification', bed, dict(plate, coordinate_frame='model_local'))
        for value in (float('nan'), float('inf'), True, '10', 10 ** 1000):
            changed = copy.deepcopy(plate)
            changed['footprints'][0]['polygon'][0][0] = value
            self.assert_status('requires_verification', bed, changed)

    def test_negative_coordinates_allowed_only_inside_verified_bed(self):
        bed, plate = fixtures()
        bed['printable_polygon'] = rect(-50, -50, 50, 50)
        plate['footprints'][0]['polygon'] = rect(-40, -40, -20, -20)
        self.assert_status('allow', bed, plate)
        bed['printable_polygon'] = rect(0, 0, 100, 100)
        self.assert_status('blocked', bed, plate)

    def test_holes_circle_approximation_and_concave_bed_are_not_flattened(self):
        bed, plate = fixtures()
        self.assert_status('requires_verification', dict(bed, holes=[rect(20, 20, 25, 25)]), plate)
        self.assert_status('requires_verification', dict(bed, representation='circle_polygon_approximation'), plate)
        concave = [[0, 0], [100, 0], [100, 40], [40, 40], [40, 100], [0, 100]]
        self.assert_status('requires_verification', dict(bed, printable_polygon=concave), plate)
        plate['footprints'][0]['holes'] = [rect(15, 15, 20, 20)]
        self.assert_status('requires_verification', bed, plate)

    def test_self_intersection_repeated_vertex_and_degenerate_polygons_are_unknown(self):
        bed, plate = fixtures()
        for invalid in ([[10, 10], [30, 30], [10, 30], [30, 10]],
                        [[10, 10], [20, 10], [20, 10], [10, 20]],
                        [[10, 10], [20, 10], [30, 10]]):
            changed = copy.deepcopy(plate)
            changed['footprints'][0]['polygon'] = invalid
            self.assert_status('requires_verification', bed, changed)

    def test_clockwise_and_closed_polygons_are_equivalent(self):
        bed, plate = fixtures()
        bed['printable_polygon'] = list(reversed(bed['printable_polygon']))
        plate['footprints'][0]['polygon'].append(plate['footprints'][0]['polygon'][0])
        self.assert_status('allow', bed, plate)

    def test_sequential_prints_need_independent_toolhead_clearance_evidence(self):
        bed, plate = fixtures()
        plate['print_sequence'] = 'by_object'
        self.assert_status('requires_verification', bed, plate)
        plate['sequential_clearance_verified'] = True
        self.assert_status('allow', bed, plate)

    def test_overlapping_component_areas_are_not_reported_as_union_area(self):
        bed, plate = fixtures()
        plate['components']['brim'] = 'included'
        plate['footprints'].append({'kind': 'brim', 'representation': 'exact_polygon', 'polygon': rect(8, 8, 32, 32)})
        result = self.assert_status('allow', bed, plate)
        self.assertEqual(976, result['metrics']['footprint_polygon_area_sum_mm2'])
        self.assertFalse(result['metrics']['footprint_area_sum_is_union'])

    def test_partial_or_first_layer_footprints_cannot_prove_all_layer_fit(self):
        bed, plate = fixtures()
        for coverage in (None, 'first_layer', 'partial', 'all_objects_first_layer'):
            self.assert_status('requires_verification', bed, dict(plate, footprint_coverage=coverage))

    def test_conservative_z_bounds_cannot_prove_height_failure(self):
        bed, plate = fixtures()
        self.assert_status('requires_verification', bed, dict(plate, z_bounds_representation=None))
        plate['z_bounds_representation'] = 'conservative_outer_bound'
        self.assert_status('allow', bed, plate)
        plate['max_z_mm'] = 101
        self.assert_status('requires_verification', bed, plate)
        plate['max_z_mm'], plate['min_z_mm'] = 20, -2
        self.assert_status('requires_verification', bed, plate)

    def test_complexity_budget_prevents_unbounded_edge_comparisons(self):
        bed, plate = fixtures()
        bed['exclusion_polygons'] = [rect(50, 50, 51, 51)] * 257
        self.assert_status('requires_verification', bed, plate)
        bed['exclusion_polygons'] = [rect(50, 50, 51, 51)] * 256
        plate['footprints'] = plate['footprints'] * 256
        verdict = self.assert_status('requires_verification', bed, plate)
        self.assertIn('edge_pairs_exceed_supported_complexity', verdict['reasons'])

    def test_large_offsets_preserve_small_shape_area(self):
        bed, plate = fixtures()
        bed['printable_polygon'] = rect(900000, 900000, 900100, 900100)
        plate['footprints'][0]['polygon'] = rect(900010, 900010, 900010.01, 900010.01)
        verdict = self.assert_status('allow', bed, plate)
        self.assertAlmostEqual(.0001, verdict['metrics']['footprint_polygon_area_sum_mm2'], places=8)

    def test_ambiguous_or_boolean_tool_region_identity_is_unknown(self):
        bed, plate = fixtures()
        bed.update(tool_regions_required=True, tool_regions_verified=True,
                   tool_regions={0: rect(0, 0, 100, 100), '0': rect(0, 0, 50, 50)})
        plate['footprints'][0]['tool_id'] = 0
        self.assert_status('requires_verification', bed, plate)
        bed['tool_regions'] = {True: rect(0, 0, 100, 100)}
        plate['footprints'][0]['tool_id'] = 'True'
        self.assert_status('requires_verification', bed, plate)


if __name__ == '__main__':
    unittest.main()
