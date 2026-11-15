"""Validate recorded observations without treating them as eligibility or labels."""
from __future__ import annotations

from datetime import datetime
import math
import re
from validate_toolpath_observation import validate_toolpath

CAPACITIES = {'candidate_ids': 16, 'devices': 16, 'ams_units': 256, 'feed_slots': 1024}


class ObservationError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _check(condition, message='采集快照结构与原始决策不一致'):
    if not condition:
        raise ObservationError('invalid_observation', message)


def _timestamp(value, *, nullable=False):
    if value is None and nullable:
        return
    _check(isinstance(value, str) and 1 <= len(value) <= 64, '采集时间必须是带时区的时间文本，缺测应保留未知')
    try:
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError as exc:
        raise ObservationError('invalid_observation', '采集时间格式无效') from exc
    _check(parsed.tzinfo is not None and parsed.utcoffset() is not None, '采集时间缺少时区')


def _index(value):
    _check(type(value) is int and 0 <= value <= 65535, '采集的单元或槽位编号无效')


def _bounded_raw(value):
    """Accept the bounded raw scalar/list evidence emitted by the 3MF reader."""
    if isinstance(value, list):
        _check(len(value) <= 64 and not any(isinstance(item, (list, dict)) for item in value))
        for item in value:
            _bounded_raw(item)
    else:
        _check(value is None or type(value) is bool or
               isinstance(value, str) and len(value) <= 4096 or
               type(value) in (int, float) and abs(value) <= 1e308 and math.isfinite(value),
               '声明几何原文必须有界且不含非有限数值')


def _flat_polygon(value, *, allow_empty=False):
    _check(isinstance(value, list), '声明区域坐标必须是列表')
    _check(allow_empty and not value or 6 <= len(value) <= 64 and len(value) % 2 == 0,
           '声明区域坐标数量无效')
    _check(all(type(number) in (int, float) and abs(number) <= 1000000 and math.isfinite(number)
               for number in value), '声明区域坐标必须是有界有限数值')


def _declared_geometry(value, artifact, plate_index):
    """Check declaration provenance/shape only; this never measures fit or units.

    Client syntax claims remain unverified observations. No preset defaults,
    unit conversions, occupied footprint, installed-tool identity or admission
    verdict may enter through this optional evidence field.
    """
    if value is None:
        return
    _check(isinstance(value, dict), '声明几何证据格式无效')
    required = {'schema', 'source', 'artifact_sha256', 'plate_index', 'settings_entry', 'settings_scope',
                'settings_sha256', 'status', 'coordinate_units', 'unit_status', 'physical_fit', 'occupied_footprint'}
    _check(required <= set(value) and set(value) <= required | {'unit_raw', 'fields', 'reason'})
    _check(value['schema'] == 'slice-declared-geometry-v1' and value['source'] == '3mf_project_settings'
           and isinstance(artifact, str) and value['artifact_sha256'] == artifact.lower()
           and type(value['plate_index']) is int and value['plate_index'] == plate_index,
           '声明床面证据与切片摘要或盘号不一致')
    _check(value['settings_entry'] == 'Metadata/project_settings.config'
           and value['settings_scope'] == 'project_wide_declaration_not_installed_machine'
           and value['physical_fit'] == 'not_evaluated' and value['occupied_footprint'] == 'not_measured',
           '项目床面声明不能被记录为实测占用或设备准入结论')
    settings_hash = value['settings_sha256']
    _check(settings_hash is None or isinstance(settings_hash, str) and re.fullmatch('[0-9a-f]{64}', settings_hash))
    unit_status = value['unit_status']
    _check(isinstance(unit_status, str) and unit_status in {'not_declared', 'declared_mm', 'unsupported_or_conflicting'})
    _check(value['coordinate_units'] == ('mm' if unit_status == 'declared_mm' else None),
           '单位未知时不得把声明坐标当作毫米')
    if unit_status == 'not_declared':
        _check('unit_raw' not in value)
    else:
        _check(isinstance(value.get('unit_raw'), list) and 1 <= len(value['unit_raw']) <= 2)
        for declaration in value['unit_raw']:
            _bounded_raw(declaration)
    status = value['status']
    _check(isinstance(status, str))
    if status in {'not_present', 'unreadable'}:
        _check('fields' not in value and unit_status == 'not_declared')
        if status == 'not_present':
            _check(settings_hash is None and 'reason' not in value)
        else:
            _check(isinstance(value.get('reason'), str) and value['reason'] in {'ambiguous_or_oversized_settings',
                                          'expanded_settings_budget_exceeded', 'settings_not_strict_json'})
        return
    _check(status in {'declared_fields_parsed', 'partial_declaration', 'invalid_declared_field'}
           and settings_hash is not None and 'reason' not in value)
    fields = value.get('fields')
    _check(isinstance(fields, dict) and set(fields) ==
           {'printable_area', 'printable_height', 'bed_exclude_area', 'extruder_printable_area'})
    statuses = []
    for name, field in fields.items():
        _check(isinstance(field, dict))
        parsed_key = ('value' if name == 'printable_height' else
                      'xy_by_extruder' if name == 'extruder_printable_area' else 'xy')
        base_keys = {'status', 'raw', parsed_key}
        _check(base_keys <= set(field) and set(field) <= base_keys | ({'tool_mapping'} if name == 'extruder_printable_area' else set()))
        current = field['status']
        statuses.append(current)
        _check(isinstance(current, str) and current in {'missing', 'invalid', 'syntax_parsed', 'declared_empty'})
        _bounded_raw(field['raw'])
        if name == 'extruder_printable_area' and current != 'missing':
            _check(field.get('tool_mapping') == 'array_index_only_installed_tool_identity_unverified')
        if current in {'missing', 'invalid'}:
            _check(field[parsed_key] is None)
            if current == 'missing':
                _check(field['raw'] is None)
            continue
        if current == 'declared_empty':
            _check(name in {'bed_exclude_area', 'extruder_printable_area'} and field[parsed_key] == [])
        elif name == 'printable_height':
            number = field[parsed_key]
            _check(type(number) in (int, float) and 0 < number <= 1000000 and math.isfinite(number))
        elif name == 'extruder_printable_area':
            regions = field[parsed_key]
            _check(isinstance(regions, list) and 1 <= len(regions) <= 16)
            for region in regions:
                _flat_polygon(region)
        else:
            _flat_polygon(field[parsed_key])
    expected_status = ('invalid_declared_field' if 'invalid' in statuses else
                       'partial_declaration' if 'missing' in statuses or unit_status != 'declared_mm' else
                       'declared_fields_parsed')
    _check(status == expected_status, '声明几何总状态与缺失字段或单位状态不一致')


def validate_observation(observation: dict, request: dict):
    """Preserve missing measurements. Reject partial/foreign/oversized topology.

    Timestamps are archived as supplied, not replaced with the time of recording.
    Freshness and hardware admission are separate checks on the actual live
    decision path; saving an observation grants neither training eligibility nor
    printer execution authority.
    """
    _check(isinstance(observation, dict))
    _check(observation.get('schema') == 'mifu-observation-v1'
           and observation.get('source') == 'desktop_observation'
           and observation.get('requestId') == request['requestId']
           and observation.get('plate_id') == request['plate']['id']
           and observation.get('training_eligible') is False)
    arrays = {}
    for name, capacity in CAPACITIES.items():
        value = observation.get(name)
        _check(isinstance(value, list), '采集快照缺少完整的设备、单元或槽位列表')
        if len(value) > capacity:
            raise ObservationError('observation_capacity_exceeded',
                                   f'采集快照的{name}超过{capacity}条容量；本次没有截取或保存部分证据')
        arrays[name] = value
    candidate_ids = arrays['candidate_ids']
    _check(all(isinstance(value, str) and value for value in candidate_ids))
    expected = {candidate['id'] for candidate in request['candidates']}
    _check(len(candidate_ids) == len(set(candidate_ids)) and set(candidate_ids) == expected)
    _timestamp(observation.get('snapshot_at'))
    artifact = observation.get('artifact_sha256')
    _check(artifact is None or isinstance(artifact, str) and re.fullmatch('[0-9a-fA-F]{64}', artifact),
           '切片摘要无效，缺测应保留未知')
    plate_index = observation.get('plate_index')
    _index(plate_index)
    _check(plate_index >= 1, '打印盘编号从1开始')
    if 'plate_index' in request['plate']:
        _check(plate_index == request['plate']['plate_index'])
    if 'artifact_sha256' in request['plate']:
        _check(artifact == request['plate']['artifact_sha256'])
    _check(isinstance(observation.get('geometry'), dict))
    _declared_geometry(observation.get('declared_slice_geometry'), artifact, plate_index)
    try:
        validate_toolpath(observation.get('toolpath_geometry'), artifact, plate_index)
    except ValueError as exc:
        raise ObservationError('invalid_observation', str(exc)) from exc

    devices = {}
    for device in arrays['devices']:
        _check(isinstance(device, dict))
        identifier = device.get('candidate_id')
        _check(isinstance(identifier, str) and identifier in expected and identifier not in devices,
               '采集设备重复或不属于本次候选')
        _check(type(device.get('ams_observed')) is bool, '需要区分AMS未观测与已观测为空')
        _timestamp(device.get('telemetry_at'), nullable=True)
        _timestamp(device.get('ams_telemetry_at'), nullable=True)
        devices[identifier] = device
    _check(set(devices) == expected, '采集快照缺少候选设备证据，不能保存为完整快照')
    units = set()
    for unit in arrays['ams_units']:
        _check(isinstance(unit, dict))
        identifier, unit_index = unit.get('candidate_id'), unit.get('unit_index')
        _check(isinstance(identifier, str) and identifier in devices
               and devices[identifier]['ams_observed'], 'AMS单元没有对应的已观测设备')
        _index(unit_index)
        key = identifier, unit_index
        _check(key not in units, 'AMS单元重复')
        units.add(key)
        _check(isinstance(unit.get('type'), str) and bool(unit['type']))
        _check(unit.get('present') is None or type(unit.get('present')) is bool)
        _check(unit.get('uses_track_switch') is None or type(unit.get('uses_track_switch')) is bool)
        if unit.get('extruder_index') is not None:
            _index(unit['extruder_index'])
        _timestamp(unit.get('telemetry_at'), nullable=True)
    slots = set()
    for slot in arrays['feed_slots']:
        _check(isinstance(slot, dict))
        identifier, unit_index, slot_index = slot.get('candidate_id'), slot.get('unit_index'), slot.get('slot_index')
        _check(isinstance(identifier, str))
        _index(unit_index)
        _index(slot_index)
        _check((identifier, unit_index) in units, '槽位没有对应的已观测AMS单元')
        key = identifier, unit_index, slot_index
        _check(key not in slots, '采集槽位重复')
        slots.add(key)
        _check(slot.get('present') is None or type(slot.get('present')) is bool)
        _timestamp(slot.get('telemetry_at'), nullable=True)
    return observation
