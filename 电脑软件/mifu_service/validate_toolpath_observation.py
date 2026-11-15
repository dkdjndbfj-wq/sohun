"""Validate bounded commanded-centerline evidence; never authorize physical fit."""
import math
import re


def validate_toolpath(value, artifact, plate_index):
    if value is None:
        return
    def require(condition):
        if not condition:
            raise ValueError('刀路证据与切片绑定、解析范围或数值不一致')
    def count(number, maximum):
        require(type(number) is int and 0 <= number <= maximum)
    def bounds(numbers):
        require(isinstance(numbers, list) and len(numbers) == 6)
        require(all(type(n) in (int, float) and abs(n) <= 1000000 and math.isfinite(n) for n in numbers))
        require(all(numbers[i] <= numbers[i + 3] for i in range(3)))

    keys = {'schema', 'source', 'artifact_sha256', 'plate_index', 'gcode_entry', 'gcode_sha256',
            'status', 'coverage', 'coordinate_units', 'coordinate_frame', 'interpretation',
            'physical_fit', 'occupied_footprint', 'line_width_mm', 'centerline_bounds_mm',
            'tool_bounds', 'extruding_moves', 'commands_scanned', 'reasons'}
    require(isinstance(value, dict) and set(value) == keys)
    require(value['schema'] == 'slice-toolpath-geometry-v1' and value['source'] == '3mf_selected_gcode')
    require(isinstance(artifact, str) and re.fullmatch('[0-9a-fA-F]{64}', artifact) is not None
            and value['artifact_sha256'] == artifact.lower() and type(value['plate_index']) is int
            and value['plate_index'] == plate_index and value['gcode_entry'] == f'Metadata/plate_{plate_index}.gcode')
    require(value['coordinate_frame'] == 'gcode_program' and value['interpretation'] == 'explicit_marlin_modal_subset_v1'
            and value['physical_fit'] == 'not_evaluated' and value['occupied_footprint'] == 'not_measured'
            and value['line_width_mm'] is None)
    code_hash = value['gcode_sha256']
    require(code_hash is None or isinstance(code_hash, str) and re.fullmatch('[0-9a-f]{64}', code_hash) is not None)
    require(isinstance(value['reasons'], list) and len(value['reasons']) <= 8 and
            all(isinstance(r, str) and re.fullmatch('[a-z0-9_]{1,128}', r) for r in value['reasons']))
    require(isinstance(value['status'], str) and value['status'] in
            {'not_present', 'parsed_centerline', 'requires_verification', 'unreadable'})
    count(value['commands_scanned'], 300001)
    count(value['extruding_moves'], 300000)
    require(value['extruding_moves'] <= value['commands_scanned'])
    require(isinstance(value['tool_bounds'], list) and len(value['tool_bounds']) <= 16)
    if value['status'] != 'parsed_centerline':
        require(value['coverage'] == 'unknown' and value['centerline_bounds_mm'] is None and value['tool_bounds'] == [])
        require(value['coordinate_units'] is None or value['status'] == 'requires_verification' and value['coordinate_units'] == 'mm')
        if value['status'] == 'not_present':
            require(code_hash is None and value['reasons'] == [] and value['commands_scanned'] == value['extruding_moves'] == 0)
        else:
            require(bool(value['reasons']))
        return
    require(value['coverage'] == 'full_selected_gcode' and value['coordinate_units'] == 'mm'
            and code_hash is not None and value['reasons'] == [] and value['extruding_moves'] > 0
            and value['commands_scanned'] <= 300000 and bool(value['tool_bounds']))
    outer = value['centerline_bounds_mm']
    bounds(outer)
    identities, total = set(), 0
    for tool in value['tool_bounds']:
        require(isinstance(tool, dict) and set(tool) == {'tool_index', 'bounds_mm', 'moves'})
        count(tool['tool_index'], 255)
        require(tool['tool_index'] not in identities)
        identities.add(tool['tool_index'])
        count(tool['moves'], 300000)
        require(tool['moves'] > 0)
        total += tool['moves']
        bounds(tool['bounds_mm'])
        require(all(outer[i] <= tool['bounds_mm'][i] and tool['bounds_mm'][i + 3] <= outer[i + 3] for i in range(3)))
    require(total == value['extruding_moves'])
    require(all(outer[i] == min(t['bounds_mm'][i] for t in value['tool_bounds']) and
                outer[i + 3] == max(t['bounds_mm'][i + 3] for t in value['tool_bounds']) for i in range(3)))
