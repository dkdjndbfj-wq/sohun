import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_observation import ObservationError, validate_observation
from test_validate_observation import fixture


def evidence():
    return {'schema': 'slice-declared-geometry-v1', 'source': '3mf_project_settings',
            'artifact_sha256': 'a' * 64, 'plate_index': 1,
            'settings_entry': 'Metadata/project_settings.config',
            'settings_scope': 'project_wide_declaration_not_installed_machine',
            'settings_sha256': 'b' * 64, 'status': 'declared_fields_parsed',
            'coordinate_units': 'mm', 'unit_status': 'declared_mm', 'unit_raw': ['mm'],
            'physical_fit': 'not_evaluated', 'occupied_footprint': 'not_measured',
            'fields': {
                'printable_area': {'status': 'syntax_parsed', 'raw': ['0x0', '100x0', '100x80', '0x80'],
                                   'xy': [0, 0, 100, 0, 100, 80, 0, 80]},
                'printable_height': {'status': 'syntax_parsed', 'raw': '120', 'value': 120},
                'bed_exclude_area': {'status': 'declared_empty', 'raw': [], 'xy': []},
                'extruder_printable_area': {'status': 'syntax_parsed', 'raw': ['0x0,100x0,100x80,0x80'],
                    'xy_by_extruder': [[0, 0, 100, 0, 100, 80, 0, 80]],
                    'tool_mapping': 'array_index_only_installed_tool_identity_unverified'}}}


def declaration_fixture():
    request, observation = fixture()
    request['plate']['artifact_sha256'] = observation['artifact_sha256'] = 'a' * 64
    observation['declared_slice_geometry'] = evidence()
    return request, observation


class DeclaredGeometryObservationTests(unittest.TestCase):
    def test_declared_evidence_preserved_and_fits_http_envelope(self):
        from mifu_server import validate_json
        request, observation = declaration_fixture()
        before = copy.deepcopy(observation)
        self.assertEqual(before, validate_observation(observation, request))
        validate_json(observation, list_limit=1024)
        self.assertEqual(before, observation)
        self.assertFalse(observation['training_eligible'])
        self.assertEqual('not_measured', observation['geometry']['status'])

    def test_absent_missing_unreadable_and_unknown_units_remain_unknown(self):
        for status in ('not_present', 'unreadable', 'partial_declaration'):
            request, observation = declaration_fixture()
            value = observation['declared_slice_geometry']
            value.update(status=status, unit_status='not_declared', coordinate_units=None)
            value.pop('unit_raw')
            if status != 'partial_declaration':
                value.pop('fields')
                value['settings_sha256'] = None
            if status == 'unreadable':
                value['reason'] = 'ambiguous_or_oversized_settings'
            self.assertEqual(value, validate_observation(observation, request)['declared_slice_geometry'])
        request, observation = declaration_fixture()
        observation['declared_slice_geometry'] = None
        validate_observation(observation, request)
        request, observation = declaration_fixture()
        observation['declared_slice_geometry'].update(status='partial_declaration', coordinate_units=None,
            unit_status='unsupported_or_conflicting', unit_raw=[['mm']])
        validate_observation(observation, request)

    def test_artifact_plate_and_unmeasured_scope_cannot_be_changed(self):
        for key, invalid in (('artifact_sha256', 'c' * 64), ('plate_index', 2), ('plate_index', True),
                             ('physical_fit', 'allow'), ('occupied_footprint', 'measured'),
                             ('source', 'printer_telemetry'), ('settings_scope', 'installed_machine')):
            request, observation = declaration_fixture()
            observation['declared_slice_geometry'][key] = invalid
            with self.subTest(key=key), self.assertRaises(ObservationError):
                validate_observation(observation, request)
        request, observation = declaration_fixture()
        observation['artifact_sha256'] = request['plate']['artifact_sha256'] = None
        with self.assertRaises(ObservationError):
            validate_observation(observation, request)

    def test_units_and_aggregate_status_must_match_missing_fields(self):
        for mutate in (
            lambda value: value.update(unit_status='not_declared'),
            lambda value: value.update(coordinate_units='inch'),
            lambda value: value.update(status='partial_declaration'),
            lambda value: value['fields']['printable_height'].update(status='missing', raw=None, value=None),
            lambda value: value.update(unit_status=[]),
            lambda value: value['fields']['printable_height'].update(status=[]),
        ):
            request, observation = declaration_fixture()
            mutate(observation['declared_slice_geometry'])
            with self.assertRaises(ObservationError):
                validate_observation(observation, request)

    def test_nonfinite_boolean_oversized_and_invalid_shapes_are_rejected(self):
        for invalid in (float('nan'), float('inf'), True, -1, 0, 1e309, 10 ** 400):
            request, observation = declaration_fixture()
            observation['declared_slice_geometry']['fields']['printable_height']['value'] = invalid
            with self.subTest(value=str(invalid)), self.assertRaises(ObservationError):
                validate_observation(observation, request)
        for invalid in ([0, 0], [0] * 66, [0, 0, 1, True, 1, 1], [0, 0, 1, float('nan'), 1, 1]):
            request, observation = declaration_fixture()
            observation['declared_slice_geometry']['fields']['printable_area']['xy'] = invalid
            with self.assertRaises(ObservationError):
                validate_observation(observation, request)
        request, observation = declaration_fixture()
        field = observation['declared_slice_geometry']['fields']['extruder_printable_area']
        field['xy_by_extruder'] *= 17
        with self.assertRaises(ObservationError):
            validate_observation(observation, request)

    def test_missing_and_invalid_fields_remain_evidence_not_repaired(self):
        request, observation = declaration_fixture()
        value = observation['declared_slice_geometry']
        value['status'] = 'invalid_declared_field'
        value['fields']['printable_height'].update(status='invalid', raw='NaN', value=None)
        value['fields']['bed_exclude_area'].update(status='missing', raw=None, xy=None)
        before = copy.deepcopy(observation)
        self.assertEqual(before, validate_observation(observation, request))
        self.assertEqual('NaN', value['fields']['printable_height']['raw'])
        self.assertIsNone(value['fields']['printable_height']['value'])


if __name__ == '__main__':
    unittest.main()
