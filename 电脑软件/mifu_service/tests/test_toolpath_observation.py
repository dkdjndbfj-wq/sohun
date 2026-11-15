import copy
import unittest

from test_validate_observation import fixture
from validate_observation import ObservationError, validate_observation


def evidence():
    return {'schema': 'slice-toolpath-geometry-v1', 'source': '3mf_selected_gcode',
        'artifact_sha256': 'a' * 64, 'plate_index': 1, 'gcode_entry': 'Metadata/plate_1.gcode',
        'gcode_sha256': 'b' * 64, 'status': 'parsed_centerline', 'coverage': 'full_selected_gcode',
        'coordinate_units': 'mm', 'coordinate_frame': 'gcode_program',
        'interpretation': 'explicit_marlin_modal_subset_v1', 'physical_fit': 'not_evaluated',
        'occupied_footprint': 'not_measured', 'line_width_mm': None,
        'centerline_bounds_mm': [10, 10, .2, 30, 40, 12],
        'tool_bounds': [{'tool_index': 0, 'bounds_mm': [10, 10, .2, 30, 40, 12], 'moves': 2}],
        'extruding_moves': 2, 'commands_scanned': 12, 'reasons': []}


class ToolpathObservationTests(unittest.TestCase):
    def validate(self, value):
        request, observation = fixture()
        observation['artifact_sha256'] = 'a' * 64
        observation['toolpath_geometry'] = value
        return validate_observation(observation, request)

    def test_complete_centerline_is_evidence_only(self):
        result = self.validate(evidence())['toolpath_geometry']
        self.assertEqual('not_measured', result['occupied_footprint'])
        self.assertEqual('not_evaluated', result['physical_fit'])
        self.assertIsNone(result['line_width_mm'])

    def test_wrong_artifact_plate_entry_or_permission_is_rejected(self):
        for key, replacement in [('artifact_sha256', 'c'*64), ('plate_index', 2),
                ('gcode_entry', 'Metadata/plate_2.gcode'), ('physical_fit', 'allow'),
                ('occupied_footprint', 'complete'), ('line_width_mm', .4)]:
            value = evidence()
            value[key] = replacement
            with self.subTest(key=key), self.assertRaises(ObservationError):
                self.validate(value)

    def test_partial_coverage_never_carries_passing_bounds(self):
        value = evidence()
        value.update(status='requires_verification', coverage='unknown',
                     centerline_bounds_mm=None, tool_bounds=[], reasons=['unsupported_command'])
        self.validate(value)
        value['centerline_bounds_mm'] = [0, 0, 0, 1, 1, 1]
        with self.assertRaises(ObservationError): self.validate(value)

    def test_nonfinite_inverted_and_mismatching_tool_bounds_reject(self):
        for replacement in ([0, 0, 0, float('nan'), 1, 1], [3, 0, 0, 2, 1, 1], [0, 0, 0, 1, 1, 1]):
            value = evidence()
            value['tool_bounds'][0]['bounds_mm'] = replacement
            with self.subTest(replacement=replacement), self.assertRaises(ObservationError): self.validate(value)
        value = evidence()
        value['tool_bounds'].append(copy.deepcopy(value['tool_bounds'][0]))
        with self.assertRaises(ObservationError): self.validate(value)

    def test_missing_file_and_bounded_budget_failure_preserve_unknown(self):
        value = evidence()
        value.update(status='not_present', coverage='unknown', gcode_sha256=None,
            coordinate_units=None, centerline_bounds_mm=None, tool_bounds=[], extruding_moves=0, commands_scanned=0)
        self.validate(value)
        value.update(status='requires_verification', gcode_sha256='b'*64, coordinate_units='mm',
            commands_scanned=300001, reasons=['command_budget_exceeded'])
        self.validate(value)
        value['commands_scanned'] = 300002
        with self.assertRaises(ObservationError): self.validate(value)
