"""Conservative, fixed-layout geometry check; never arrange or dispatch a print.

`evaluate_bed_geometry(bed, plate)` returns allow / blocked /
requires_verification. An allow covers only the supplied fabrication footprints,
height and tool reach. It is not full printer eligibility, collision simulation,
packing, volume utilization or a statement that a pre-sliced job can be moved.

Example input (the 100 mm bed below is a test example, not a printer preset)::

    bed = {
        "units": "mm", "coordinate_frame": "machine_bed_xy", "model_id": "example",
        "geometry_verified": True, "profile_sha256": "a" * 64,
        "representation": "exact_polygon",
        "printable_polygon": [[0, 0], [100, 0], [100, 100], [0, 100]],
        "max_height_mm": 100, "exclusion_polygons": [], "exclusions_complete": True,
        "tool_regions_required": False, "clearance_mm": 0,
    }
    plate = {
        "units": "mm", "coordinate_frame": "machine_bed_xy", "target_model_id": "example",
        "artifact_kind": "pre_sliced", "post_slice_transform": "none",
        "geometry_verified": True, "geometry_artifact_sha256": "b" * 64,
        "artifact_sha256": "b" * 64, "plate_index": 1, "selected_plate_index": 1,
        "bed_profile_sha256": "a" * 64, "min_z_mm": 0, "max_z_mm": 20,
        "footprint_coverage": "all_layers", "z_bounds_representation": "exact",
        "print_sequence": "by_layer",
        "components": {"object": "included", "support": "verified_absent",
            "brim": "verified_absent", "skirt": "verified_absent",
            "purge_tower": "verified_absent"},
        "footprints": [{"kind": "object", "representation": "exact_polygon",
            "polygon": [[10, 10], [30, 10], [30, 30], [10, 30]]}],
    }

Caller responsibilities: resolve inherited machine settings, measure geometry
in the selected plate's MACHINE coordinates (including object transforms), bind
it to the actual artifact hash and plate index, verify all auxiliary footprints
or their absence, and supply the current bed profile hash. `obj_bbox`, a mesh's
untransformed bounds, thumbnails and nominal platform dimensions alone do not
satisfy these responsibilities. Footprints must cover the projection of ALL
fabrication layers, not only the first layer. Z bounds must explicitly identify
whether they are exact or conservative outer bounds. A verified OUTER bound
may prove containment, but a collision of that bound is only uncertain.

Only exact convex printable/tool polygons and simple exclusion/footprint polygons
are supported. Holes, circular approximations, non-simple polygons, unsupported
units or missing evidence return unknown. Coordinates may be negative when the
verified bed coordinate system permits them. Near-boundary distances within
EPSILON_MM are uncertain, never silently accepted.
Complexity limits below are implementation limits, not printer restrictions.
"""
from __future__ import annotations

import math
import re
from typing import Any

EPSILON_MM = 1e-6
MAX_VERTICES = 256
MAX_FOOTPRINTS = 256
MAX_EXCLUSIONS = 256
MAX_TOOL_REGIONS = 16
MAX_TOTAL_VERTICES = 4096
MAX_EDGE_PAIR_CHECKS = 250_000
MAX_ABS_MM = 1_000_000
COMPONENTS = ('object', 'support', 'brim', 'skirt', 'purge_tower')
Point = tuple[float, float]
Polygon = tuple[Point, ...]


class GeometryUnknown(ValueError):
    pass


def numeric(value: Any) -> float:
    if type(value) not in (int, float) or abs(value) > MAX_ABS_MM or not math.isfinite(value):
        raise GeometryUnknown('geometry_number_invalid_or_out_of_supported_range')
    return float(value)


def cross(a: Point, b: Point, c: Point) -> float:
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def edges(polygon: Polygon):
    return zip(polygon, polygon[1:] + polygon[:1])


def signed_area(polygon: Polygon) -> float:
    # A local origin avoids cancellation for small shapes at large offsets.
    return math.fsum(cross(polygon[0], a, b) for a, b in edges(polygon)) / 2


def point_segment_distance(point: Point, a: Point, b: Point) -> float:
    dx, dy = b[0] - a[0], b[1] - a[1]
    length2 = dx * dx + dy * dy
    if not length2:
        return math.dist(point, a)
    t = max(0.0, min(1.0, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length2))
    return math.hypot(point[0] - a[0] - t * dx, point[1] - a[1] - t * dy)


def segment_relation(a: Point, b: Point, c: Point, d: Point) -> str:
    """cross / near / separate; normalized distances avoid area-unit epsilon."""
    ab, cd = math.dist(a, b), math.dist(c, d)
    if ab <= EPSILON_MM or cd <= EPSILON_MM:
        return 'near'
    ac, ad = cross(a, b, c) / ab, cross(a, b, d) / ab
    ca, cb = cross(c, d, a) / cd, cross(c, d, b) / cd
    if ((ac > EPSILON_MM and ad < -EPSILON_MM) or (ad > EPSILON_MM and ac < -EPSILON_MM)) and \
            ((ca > EPSILON_MM and cb < -EPSILON_MM) or (cb > EPSILON_MM and ca < -EPSILON_MM)):
        return 'cross'
    if min(point_segment_distance(a, c, d), point_segment_distance(b, c, d),
           point_segment_distance(c, a, b), point_segment_distance(d, a, b)) <= EPSILON_MM:
        return 'near'
    return 'separate'


def polygon(value: Any, *, convex: bool = False) -> Polygon:
    if not isinstance(value, (list, tuple)) or not 3 <= len(value) <= MAX_VERTICES + 1:
        raise GeometryUnknown('polygon_missing_or_vertex_count_unsupported')
    points = []
    for point in value:
        if not isinstance(point, (list, tuple)) or len(point) != 2:
            raise GeometryUnknown('polygon_point_invalid')
        points.append((numeric(point[0]), numeric(point[1])))
    if points[0] == points[-1]:
        points.pop()
    if not 3 <= len(points) <= MAX_VERTICES:
        raise GeometryUnknown('polygon_missing_or_vertex_count_unsupported')
    poly = tuple(points)
    if any(math.dist(a, b) <= EPSILON_MM for a, b in edges(poly)):
        raise GeometryUnknown('polygon_has_degenerate_edge')
    segments = list(edges(poly))
    for i, (a, b) in enumerate(segments):
        for j in range(i + 1, len(segments)):
            if j == i + 1 or (i == 0 and j == len(segments) - 1):
                continue
            if segment_relation(a, b, *segments[j]) != 'separate':
                raise GeometryUnknown('polygon_self_intersection_or_near_self_touch')
    area = signed_area(poly)
    if abs(area) <= EPSILON_MM * EPSILON_MM:
        raise GeometryUnknown('polygon_area_degenerate')
    if area < 0:
        poly = tuple(reversed(poly))
    if convex:
        # Collinear vertices are acceptable; a definite reflex angle is not.
        for i, point in enumerate(poly):
            a, b = poly[i - 2], poly[i - 1]
            if cross(a, b, point) / math.dist(a, b) < -EPSILON_MM:
                raise GeometryUnknown('nonconvex_printable_or_tool_region_unsupported')
    return poly


def point_location(point: Point, boundary: Polygon) -> str:
    if any(point_segment_distance(point, a, b) <= EPSILON_MM for a, b in edges(boundary)):
        return 'near'
    inside = False
    x, y = point
    for a, b in edges(boundary):
        if (a[1] > y) != (b[1] > y):
            at_x = a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1])
            if x < at_x:
                inside = not inside
    return 'inside' if inside else 'outside'


def containment(inner: Polygon, convex_outer: Polygon, clearance: float) -> str:
    near = False
    for point in inner:
        for a, b in edges(convex_outer):
            distance = cross(a, b, point) / math.dist(a, b)
            if distance < clearance - EPSILON_MM:
                return 'outside'
            if distance <= clearance + EPSILON_MM:
                near = True
    return 'near' if near else 'inside'


def exclusion_relation(occupied: Polygon, excluded: Polygon, clearance: float) -> str:
    near = False
    for a, b in edges(occupied):
        for c, d in edges(excluded):
            relation = segment_relation(a, b, c, d)
            if relation == 'cross':
                return 'overlap'
            distance = min(point_segment_distance(a, c, d), point_segment_distance(b, c, d),
                           point_segment_distance(c, a, b), point_segment_distance(d, a, b))
            if distance < clearance - EPSILON_MM:
                return 'clearance_violation'
            if relation == 'near' or distance <= clearance + EPSILON_MM:
                near = True
    # The exclusion may lie entirely inside a footprint, with no crossing edges.
    locations = [point_location(point, excluded) for point in occupied] + \
                [point_location(point, occupied) for point in excluded]
    if 'inside' in locations:
        return 'overlap'
    return 'near' if near or 'near' in locations else 'separate'


def result(status: str, reasons: list[str], *, reslice_required=False, metrics=None) -> dict:
    return {'status': status, 'reasons': sorted(set(reasons)), 'scope': 'fixed_plate_geometry_only',
            'reslice_required': reslice_required, 'automatic_dispatch_authorized': False,
            'metrics': metrics or {}, 'epsilon_mm': EPSILON_MM,
            'limitations': ['Does not pack, rotate, scale, split objects or authorize G-code execution.',
                            'Area statistics are descriptive; they are never a fit or packing test.',
                            'Full motion/collision, material, nozzle, firmware and feed checks remain separate.']}


def valid_hash(value) -> bool:
    return isinstance(value, str) and re.fullmatch('[0-9a-fA-F]{64}', value) is not None


def check_complexity(bed: dict, footprints: list) -> None:
    """Bound work before polygon validation (which itself compares edge pairs)."""
    exclusions = bed['exclusion_polygons']
    if len(exclusions) > MAX_EXCLUSIONS:
        raise GeometryUnknown('exclusion_count_exceeds_supported_complexity')
    raw_tools = bed.get('tool_regions', {}) if bed['tool_regions_required'] else {}
    if not isinstance(raw_tools, dict) or len(raw_tools) > MAX_TOOL_REGIONS:
        raise GeometryUnknown('tool_regions_missing_or_exceed_supported_complexity')
    all_shapes = [bed.get('printable_polygon'), *exclusions, *raw_tools.values(),
                  *(item.get('polygon') for item in footprints)]
    if any(not isinstance(shape, (list, tuple)) for shape in all_shapes):
        raise GeometryUnknown('polygon_missing_or_vertex_count_unsupported')
    if sum(len(shape) for shape in all_shapes) > MAX_TOTAL_VERTICES:
        raise GeometryUnknown('total_vertices_exceed_supported_complexity')
    occupied_edges = sum(len(item.get('polygon')) for item in footprints)
    # Deliberately upper-bounds all tool-region comparisons and polygon self checks.
    other_edges = len(bed['printable_polygon']) + sum(len(shape) for shape in exclusions) + \
                  sum(len(shape) for shape in raw_tools.values())
    edge_pairs = sum(len(shape) ** 2 for shape in all_shapes) + occupied_edges * other_edges
    if edge_pairs > MAX_EDGE_PAIR_CHECKS:
        raise GeometryUnknown('edge_pairs_exceed_supported_complexity')


def evaluate_bed_geometry(bed: dict, plate: dict) -> dict:
    if not isinstance(bed, dict) or not isinstance(plate, dict):
        return result('requires_verification', ['geometry_input_not_object'])
    if plate.get('artifact_kind') not in ('pre_sliced', 'arrangement_candidate'):
        return result('requires_verification', ['artifact_kind_unknown'])
    pre_sliced = plate['artifact_kind'] == 'pre_sliced'
    bed_model, target_model = bed.get('model_id'), plate.get('target_model_id')
    if not all(isinstance(value, str) and value.strip() for value in (bed_model, target_model)):
        return result('requires_verification', ['exact_model_identity_missing'])
    if pre_sliced and target_model != bed_model:
        return result('blocked', ['pre_sliced_target_model_mismatch'], reslice_required=True)
    if pre_sliced:
        transform = plate.get('post_slice_transform')
        if transform is None:
            return result('requires_verification', ['post_slice_transform_not_verified'])
        if transform != 'none':
            return result('blocked', ['pre_sliced_layout_change_requires_reslicing'], reslice_required=True)
    missing = []
    for item in (bed, plate):
        if item.get('units') != 'mm':
            missing.append('units_must_be_explicit_mm')
        if item.get('coordinate_frame') != 'machine_bed_xy':
            missing.append('machine_coordinate_frame_unverified')
        if item.get('geometry_verified') is not True:
            missing.append('geometry_source_unverified')
        if item.get('holes'):
            missing.append('polygon_holes_unsupported')
    if bed.get('representation') != 'exact_polygon':
        missing.append('bed_polygon_approximation_or_representation_unverified')
    if plate.get('footprint_coverage') != 'all_layers':
        missing.append('all_layer_fabrication_footprint_missing')
    if plate.get('z_bounds_representation') not in ('exact', 'conservative_outer_bound'):
        missing.append('z_bounds_representation_unverified')
    if bed.get('exclusions_complete') is not True or not isinstance(bed.get('exclusion_polygons'), list):
        missing.append('complete_exclusion_geometry_missing')
    if type(bed.get('tool_regions_required')) is not bool:
        missing.append('tool_region_requirement_unknown')
    for key in ('artifact_sha256', 'geometry_artifact_sha256', 'bed_profile_sha256'):
        if not valid_hash(plate.get(key)):
            missing.append('geometry_artifact_or_profile_hash_missing')
    if not valid_hash(bed.get('profile_sha256')):
        missing.append('current_bed_profile_hash_missing')
    if valid_hash(plate.get('artifact_sha256')) and valid_hash(plate.get('geometry_artifact_sha256')) and \
            plate['artifact_sha256'].lower() != plate['geometry_artifact_sha256'].lower():
        missing.append('geometry_artifact_hash_mismatch')
    if valid_hash(bed.get('profile_sha256')) and valid_hash(plate.get('bed_profile_sha256')) and \
            bed['profile_sha256'].lower() != plate['bed_profile_sha256'].lower():
        missing.append('bed_profile_hash_mismatch')
    if any(type(plate.get(key)) is not int or plate[key] < 1 for key in ('plate_index', 'selected_plate_index')):
        missing.append('selected_plate_index_missing')
    elif plate['plate_index'] != plate['selected_plate_index']:
        missing.append('selected_plate_index_mismatch')
    if plate.get('print_sequence') == 'by_object':
        if plate.get('sequential_clearance_verified') is not True:
            missing.append('sequential_toolhead_clearance_unverified')
    elif plate.get('print_sequence') != 'by_layer':
        missing.append('print_sequence_unknown')
    footprints = plate.get('footprints')
    components = plate.get('components')
    if not isinstance(footprints, list) or not 1 <= len(footprints) <= MAX_FOOTPRINTS:
        missing.append('complete_footprint_set_missing_or_too_large')
    if not isinstance(components, dict) or set(components) != set(COMPONENTS):
        missing.append('object_support_brim_skirt_tower_evidence_incomplete')
    if missing:
        return result('requires_verification', missing, reslice_required=not pre_sliced)
    kinds = [item.get('kind') for item in footprints if isinstance(item, dict)]
    if len(kinds) != len(footprints) or any(kind not in COMPONENTS for kind in kinds):
        return result('requires_verification', ['footprint_component_kind_unknown'])
    for kind in COMPONENTS:
        if components[kind] not in ('included', 'verified_absent') or \
                (components[kind] == 'included') != (kind in kinds):
            return result('requires_verification', ['component_evidence_and_footprints_disagree:' + kind])
    if components['object'] != 'included':
        return result('requires_verification', ['object_footprint_missing'])
    try:
        check_complexity(bed, footprints)
        boundary = polygon(bed.get('printable_polygon'), convex=True)
        exclusions = [polygon(value) for value in bed['exclusion_polygons']]
        height = numeric(bed.get('max_height_mm'))
        clearance = numeric(bed.get('clearance_mm'))
        min_z, max_z = numeric(plate.get('min_z_mm')), numeric(plate.get('max_z_mm'))
        if height <= 0 or clearance < 0 or max_z < min_z:
            raise GeometryUnknown('height_or_clearance_invalid')
        tool_regions = {}
        if bed['tool_regions_required']:
            if bed.get('tool_regions_verified') is not True or not isinstance(bed.get('tool_regions'), dict):
                raise GeometryUnknown('tool_reachable_geometry_unverified')
            keys = list(bed['tool_regions'])
            if any(type(key) not in (str, int) or not str(key).strip() for key in keys) or \
                    len({str(key) for key in keys}) != len(keys):
                raise GeometryUnknown('tool_region_identity_invalid_or_ambiguous')
            tool_regions = {str(key): polygon(value, convex=True) for key, value in bed['tool_regions'].items()}
            if not tool_regions:
                raise GeometryUnknown('tool_reachable_geometry_missing')
        parsed = []
        for item in footprints:
            if item.get('holes'):
                raise GeometryUnknown('footprint_holes_unsupported')
            if item.get('representation') not in ('exact_polygon', 'conservative_outer_bound'):
                raise GeometryUnknown('footprint_representation_unverified')
            shape = polygon(item.get('polygon'))
            tool = item.get('tool_id')
            if bed['tool_regions_required'] and (type(tool) not in (int, str) or str(tool) not in tool_regions):
                raise GeometryUnknown('footprint_tool_mapping_unverified')
            parsed.append((item, shape, str(tool)))
    except GeometryUnknown as error:
        return result('requires_verification', [str(error)], reslice_required=not pre_sliced)
    blocked, unknown = [], []
    if min_z < -EPSILON_MM or max_z > height + EPSILON_MM:
        if plate['z_bounds_representation'] == 'exact':
            blocked.append('occupied_z_outside_printable_height')
        else:
            unknown.append('outer_z_bound_may_exceed_printable_height')
    elif min_z < 0 or abs(max_z - height) <= EPSILON_MM:
        unknown.append('occupied_z_near_height_boundary')
    for index, (item, occupied, tool) in enumerate(parsed):
        exact = item['representation'] == 'exact_polygon'
        regions = [('bed', boundary)]
        if bed['tool_regions_required']:
            regions.append(('tool_' + tool, tool_regions[tool]))
        for name, region in regions:
            relation = containment(occupied, region, clearance)
            if relation == 'outside':
                (blocked if exact else unknown).append(f'footprint_{index}_outside_{name}' if exact else f'footprint_{index}_outer_bound_may_exceed_{name}')
            elif relation == 'near':
                unknown.append(f'footprint_{index}_near_{name}_boundary')
        for excluded_index, excluded in enumerate(exclusions):
            relation = exclusion_relation(occupied, excluded, clearance)
            if relation == 'overlap':
                (blocked if exact else unknown).append(f'footprint_{index}_intersects_exclusion_{excluded_index}' if exact else f'footprint_{index}_outer_bound_may_intersect_exclusion_{excluded_index}')
            elif relation == 'clearance_violation':
                (blocked if exact else unknown).append(f'footprint_{index}_violates_exclusion_clearance_{excluded_index}' if exact else f'footprint_{index}_outer_bound_may_violate_exclusion_clearance_{excluded_index}')
            elif relation == 'near':
                unknown.append(f'footprint_{index}_near_exclusion_{excluded_index}')
    all_points = [point for _, shape, _ in parsed for point in shape]
    metrics = {'printable_polygon_area_mm2': abs(signed_area(boundary)),
               'footprint_polygon_area_sum_mm2': sum(abs(signed_area(shape)) for _, shape, _ in parsed),
               'footprint_area_sum_is_union': False,
               'occupied_bounds_mm': [min(p[0] for p in all_points), min(p[1] for p in all_points),
                                      max(p[0] for p in all_points), max(p[1] for p in all_points)],
               'max_z_mm': max_z, 'footprint_count': len(parsed)}
    if blocked:
        return result('blocked', blocked + unknown, reslice_required=True, metrics=metrics)
    if unknown:
        return result('requires_verification', unknown, reslice_required=not pre_sliced, metrics=metrics)
    return result('allow', ['fixed_layout_geometry_fits_verified_regions'], reslice_required=not pre_sliced, metrics=metrics)
