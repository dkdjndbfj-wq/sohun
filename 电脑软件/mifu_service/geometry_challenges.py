"""Deterministic synthetic fixtures for the fixed-layout bed geometry gate.

Run: python geometry_challenges.py --output <new-directory>

These are executable software-contract checks, NOT observed print outcomes,
ranking-training rows, reward labels or a manufacturer geometry catalogue.
All bed dimensions and artifact hashes below are invented fixture data. The
expected status is specified by each construction before calling the gate; a
mismatch aborts export. Parameter sweeps share construction families and are
not statistically independent real-world samples. Export reports both exact
input uniqueness and geometry-layout uniqueness, without claiming either is
real training-data volume. No model, printer, network or production file is used.

Whole pre-sliced plates consume a printer/time reservation. Free surface area
does not permit merging separate G-code jobs. Object packing, scarce large-bed
reservation, inter-job scheduling and fresh slicing after rearrangement are
separate future work. This tool does not implement them or train a ranking model.
"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
from typing import Iterator

from bed_geometry import EPSILON_MM, evaluate_bed_geometry

STATUSES = ('allow', 'blocked', 'requires_verification')
BED_SHAPES_MM = ((80, 60), (100, 100), (150, 90), (90, 150),
                 (240, 180), (300, 100), (60, 240), (320, 320))
ORIGIN_MODES = ('zero', 'centered', 'offset')
FIXTURE_TYPE = 'synthetic_eligibility_fixture'


def encoded(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'),
                      allow_nan=False).encode('utf-8')


def sha256(value) -> str:
    return hashlib.sha256(encoded(value)).hexdigest()


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def rect(x1, y1, x2, y2) -> list:
    return [[x1, y1], [x2, y1], [x2, y2], [x1, y2]]


def base_fixture(width: int, depth: int, origin_mode: str) -> tuple[dict, dict]:
    if origin_mode == 'zero':
        x, y = 0, 0
    elif origin_mode == 'centered':
        x, y = -width / 2, -depth / 2
    elif origin_mode == 'offset':
        x, y = 1000, -500
    else:
        raise ValueError('Unknown fixture origin')
    bed = {'units': 'mm', 'coordinate_frame': 'machine_bed_xy', 'model_id': 'synthetic-test-bed',
           'geometry_verified': True, 'profile_sha256': 'a' * 64,
           'representation': 'exact_polygon', 'printable_polygon': rect(x, y, x + width, y + depth),
           'max_height_mm': (width + depth) / 2, 'exclusion_polygons': [],
           'exclusions_complete': True, 'tool_regions_required': False, 'clearance_mm': 0}
    plate = {'units': 'mm', 'coordinate_frame': 'machine_bed_xy', 'target_model_id': 'synthetic-test-bed',
             'artifact_kind': 'pre_sliced', 'post_slice_transform': 'none', 'geometry_verified': True,
             'geometry_artifact_sha256': 'b' * 64, 'artifact_sha256': 'b' * 64,
             'bed_profile_sha256': 'a' * 64, 'plate_index': 1, 'selected_plate_index': 1,
             'min_z_mm': 0, 'max_z_mm': 20, 'z_bounds_representation': 'exact',
             'footprint_coverage': 'all_layers', 'print_sequence': 'by_layer',
             'components': {'object': 'included', 'support': 'verified_absent',
                            'brim': 'verified_absent', 'skirt': 'verified_absent',
                            'purge_tower': 'verified_absent'},
             'footprints': [{'kind': 'object', 'representation': 'exact_polygon',
                             'polygon': rect(x + width * .1, y + depth * .1,
                                             x + width * .3, y + depth * .3)}]}
    return bed, plate


def layout_signature(bed: dict, plate: dict) -> str:
    """Geometry/configuration only; ignore IDs, hashes, verification flags and units."""
    return sha256({'bed': {key: bed.get(key) for key in
                          ('printable_polygon', 'max_height_mm', 'exclusion_polygons',
                           'tool_regions', 'clearance_mm', 'holes')},
                   'plate': {key: plate.get(key) for key in
                             ('footprints', 'min_z_mm', 'max_z_mm', 'holes')}})


def iter_cases() -> Iterator[dict]:
    seen = set()
    for width, depth in BED_SHAPES_MM:
        for origin_mode in ORIGIN_MODES:
            bed, plate = base_fixture(width, depth, origin_mode)
            x, y = bed['printable_polygon'][0]
            context = {'width_mm': width, 'depth_mm': depth, 'origin_mode': origin_mode,
                       'dimensions_source': 'invented_test_fixture_not_manufacturer'}
            group = f'{width}x{depth}:{origin_mode}'

            def case(family, variant, expected, rationale, candidate_bed=None, candidate_plate=None):
                b, p = copy.deepcopy(candidate_bed or bed), copy.deepcopy(candidate_plate or plate)
                identity = sha256({'bed': b, 'plate': p})
                if identity in seen:
                    raise ValueError('Duplicate complete fixture input: ' + family + '/' + variant)
                seen.add(identity)
                return {'type': FIXTURE_TYPE, 'case_id': identity, 'family': family,
                        'variant': variant, 'construction_group': group, 'context': context,
                        'geometry_layout_id': layout_signature(b, p),
                        'input': {'bed': b, 'plate': p},
                        'expected': {'status': expected, 'scope': 'fixed_plate_geometry_only',
                                     'automatic_dispatch_authorized': False,
                                     'label_origin': 'synthetic_contract_expectation',
                                     'rationale': rationale}}

            def changed_plate(**changes):
                p = copy.deepcopy(plate)
                p.update(changes)
                return p

            def occupied(shape, **changes):
                p = changed_plate(**changes)
                p['footprints'][0]['polygon'] = shape
                return p

            yield case('interior', 'verified_fixed_layout', 'allow', 'Complete interior fixed-layout fixture.')
            inside = occupied(rect(x + width * .1, y + depth * .1,
                                   x + width * .5, y + depth * .7))
            narrow = occupied(rect(x + width * .1, y + depth * .1,
                                   x + width * .22, y + depth * 2.1))
            yield case('equal_area', 'short_wide_fits', 'allow', 'Same area as long-narrow partner, but every vertex fits.', candidate_plate=inside)
            yield case('equal_area', 'long_narrow_exceeds', 'blocked', 'Same area as short-wide partner, but extends above the bed.', candidate_plate=narrow)
            yield case('fixed_position', 'thin_strip_crosses_both_sides', 'blocked', 'Small area cannot excuse off-bed coordinates.',
                       candidate_plate=occupied(rect(x - 1, y + depth * .49, x + width + 1, y + depth * .51)))
            yield case('fixed_position', 'small_object_wrong_location', 'blocked', 'Would need translation and fresh slicing.',
                       candidate_plate=occupied(rect(x + width - 5, y + depth - 5, x + width + 5, y + depth + 5)))

            for side in ('left', 'right', 'bottom', 'top'):
                for multiple in (-2, -.5, 0, .5, 2):
                    delta = EPSILON_MM * multiple
                    if side == 'left':
                        shape = rect(x + delta, y + depth * .2, x + width * .2, y + depth * .4)
                    elif side == 'right':
                        shape = rect(x + width * .8, y + depth * .2, x + width - delta, y + depth * .4)
                    elif side == 'bottom':
                        shape = rect(x + width * .2, y + delta, x + width * .4, y + depth * .2)
                    else:
                        shape = rect(x + width * .2, y + depth * .8, x + width * .4, y + depth - delta)
                    status = 'blocked' if multiple == -2 else 'allow' if multiple == 2 else 'requires_verification'
                    yield case('boundary_epsilon', f'{side}:{multiple}', status,
                               'Signed distance from one bed edge; epsilon band is uncertain.', candidate_plate=occupied(shape))

            ceiling = bed['max_height_mm']
            for name, z_min, z_max, representation, expected in (
                ('exact_inside', 1, ceiling - 1, 'exact', 'allow'),
                ('exact_at_ceiling', 0, ceiling, 'exact', 'requires_verification'),
                ('exact_above', 0, ceiling + 1, 'exact', 'blocked'),
                ('exact_below_floor', -1, 20, 'exact', 'blocked'),
                ('coarse_above', 0, ceiling + 1, 'conservative_outer_bound', 'requires_verification'),
                ('coarse_below_floor', -1, 20, 'conservative_outer_bound', 'requires_verification'),
                ('coarse_inside', 1, ceiling - 1, 'conservative_outer_bound', 'allow'),
            ):
                yield case('height', name, expected, 'Absolute all-layer Z envelope with explicit exactness.',
                           candidate_plate=changed_plate(min_z_mm=z_min, max_z_mm=z_max,
                                                         z_bounds_representation=representation))

            for kind in ('support', 'brim', 'skirt', 'purge_tower'):
                p = changed_plate()
                del p['components'][kind]
                yield case('auxiliary_evidence', kind + ':missing_declaration', 'requires_verification',
                           'Missing auxiliary geometry/absence evidence cannot mean absent.', candidate_plate=p)
                p['components'][kind] = 'included'
                yield case('auxiliary_evidence', kind + ':missing_footprint', 'requires_verification',
                           'Included component must have a complete footprint.', candidate_plate=p)
                p['footprints'].append({'kind': kind, 'representation': 'exact_polygon',
                                        'polygon': rect(x + width * .6, y + depth * .6, x + width * .7, y + depth * .7)})
                yield case('auxiliary_geometry', kind + ':inside', 'allow', 'Auxiliary component also fits.', candidate_plate=p)
                p['footprints'][-1]['polygon'] = rect(x + width - 2, y + depth * .6, x + width + 2, y + depth * .7)
                yield case('auxiliary_geometry', kind + ':outside', 'blocked', 'Auxiliary footprint extends beyond the bed.', candidate_plate=p)

            b = copy.deepcopy(bed)
            b['exclusion_polygons'] = [rect(x + width * .15, y + depth * .15, x + width * .2, y + depth * .2)]
            yield case('exclusion', 'excluded_island_inside_object', 'blocked', 'Containment collision exists without edge crossings.', candidate_bed=b)
            p = changed_plate()
            p['footprints'][0]['representation'] = 'conservative_outer_bound'
            yield case('outer_bound', 'island_may_collide', 'requires_verification', 'Coarse XY box cannot prove occupied collision.', candidate_bed=b, candidate_plate=p)
            b['exclusion_polygons'] = [rect(x + width * .25, y + depth * .2, x + width * .4, y + depth * .4)]
            yield case('exclusion', 'edges_cross', 'blocked', 'Exact occupied and excluded polygons intersect.', candidate_bed=b)
            b['exclusion_polygons'] = [[[x + width * .4, y + depth * .4], [x + width * .8, y + depth * .4],
                                       [x + width * .8, y + depth * .5], [x + width * .5, y + depth * .5],
                                       [x + width * .5, y + depth * .8], [x + width * .4, y + depth * .8]]]
            yield case('concave_exclusion', 'notch_fits', 'allow', 'Notch is clear even though its bounding rectangle is excluded in part.',
                       candidate_bed=b, candidate_plate=occupied(rect(x + width * .6, y + depth * .6, x + width * .7, y + depth * .7)))
            yield case('concave_exclusion', 'arm_collision', 'blocked', 'A footprint crosses the concave exclusion arm.',
                       candidate_bed=b, candidate_plate=occupied(rect(x + width * .45, y + depth * .6, x + width * .55, y + depth * .7)))
            for distance, expected in ((1, 'blocked'), (2, 'requires_verification'), (3, 'allow')):
                b = copy.deepcopy(bed)
                b['clearance_mm'] = 2
                yield case('clearance', f'bed:{distance}', expected, 'Explicit 2 mm fixture clearance; no manufacturer assertion.',
                           candidate_bed=b, candidate_plate=occupied(rect(x + distance, y + 10, x + 10, y + 20)))
                b['exclusion_polygons'] = [rect(x + width * .3 + distance, y + depth * .1,
                                               x + width * .3 + distance + 4, y + depth * .3)]
                yield case('clearance', f'exclusion:{distance}', expected, 'Exact footprint must respect supplied exclusion clearance.', candidate_bed=b)

            b = copy.deepcopy(bed)
            b.update(tool_regions_required=True, tool_regions_verified=True,
                     tool_regions={'0': rect(x, y, x + width * .65, y + depth),
                                   '1': rect(x + width * .35, y, x + width, y + depth)})
            for location, shape in (('left', rect(x + width * .1, y + depth * .4, x + width * .2, y + depth * .5)),
                                    ('right', rect(x + width * .8, y + depth * .4, x + width * .9, y + depth * .5))):
                for tool in (0, 1):
                    p = occupied(shape)
                    p['footprints'][0]['tool_id'] = tool
                    expected = 'allow' if (location, tool) in (('left', 0), ('right', 1)) else 'blocked'
                    yield case('tool_reach', f'{location}:tool{tool}', expected, 'Each assigned tool must reach this exact footprint.', candidate_bed=b, candidate_plate=p)
            p = changed_plate()
            p['footprints'][0]['tool_id'] = 0
            p['footprints'].append({'kind': 'object', 'representation': 'exact_polygon', 'tool_id': 1,
                                    'polygon': rect(x + width * .8, y + depth * .6, x + width * .9, y + depth * .7)})
            yield case('tool_reach', 'two_tools_both_fit', 'allow', 'Two occupied regions individually fit their assigned tools.', candidate_bed=b, candidate_plate=p)
            p['components']['support'] = 'included'
            p['footprints'].append({'kind': 'support', 'representation': 'exact_polygon', 'tool_id': 1,
                                    'polygon': rect(x + width * .1, y + depth * .6, x + width * .2, y + depth * .7)})
            yield case('tool_reach', 'support_wrong_tool', 'blocked', 'Support tool coverage is checked as well as object tools.', candidate_bed=b, candidate_plate=p)
            for value in (None, True, 7):
                p = changed_plate()
                p['footprints'][0]['tool_id'] = value
                yield case('tool_evidence', f'unknown_tool:{value}', 'requires_verification', 'Missing, boolean or unmapped tool cannot be presumed reachable.', candidate_bed=b, candidate_plate=p)
            p = changed_plate()
            p['footprints'][0]['tool_id'] = 0
            b['tool_regions_verified'] = False
            yield case('tool_evidence', 'unverified_regions', 'requires_verification', 'Tool polygons need verified configuration evidence.', candidate_bed=b, candidate_plate=p)

            for key, value in (
                ('geometry_artifact_sha256', 'c' * 64), ('artifact_sha256', None),
                ('bed_profile_sha256', 'c' * 64), ('selected_plate_index', 2), ('plate_index', True),
                ('footprint_coverage', 'first_layer'), ('footprint_coverage', 'partial'),
                ('footprint_coverage', None), ('z_bounds_representation', None),
                ('geometry_verified', False), ('units', 'cm'), ('units', None),
                ('coordinate_frame', 'model_local'), ('max_z_mm', None), ('min_z_mm', True),
                ('post_slice_transform', None), ('print_sequence', 'unknown'),
            ):
                yield case('missing_or_mismatched_evidence', f'{key}:{value}', 'requires_verification',
                           'Evidence must identify all layers, exact artifact, plate, units and current configuration.',
                           candidate_plate=changed_plate(**{key: value}))
            for key, value in (('exclusions_complete', False), ('tool_regions_required', None),
                               ('profile_sha256', None), ('units', 'inch'), ('geometry_verified', False)):
                b = copy.deepcopy(bed)
                b[key] = value
                yield case('bed_evidence', f'{key}:{value}', 'requires_verification', 'Bed settings must be complete and verified.', candidate_bed=b)

            for operation in ('rotate_90', 'translate', 'scale_0.5'):
                yield case('presliced_integrity', operation, 'blocked', 'Existing G-code must not be transformed by admission.',
                           candidate_plate=changed_plate(post_slice_transform=operation))
            yield case('presliced_integrity', 'different_target_model', 'blocked', 'Cross-model execution requires fresh compatible slicing.',
                       candidate_plate=changed_plate(target_model_id='another-synthetic-bed'))
            yield case('arrangement_candidate', 'geometry_only', 'allow', 'Prospective layout still requires slicing even when geometric checks pass.',
                       candidate_plate=changed_plate(artifact_kind='arrangement_candidate', target_model_id='source-synthetic-bed'))
            yield case('sequential', 'clearance_unverified', 'requires_verification', 'Object-by-object motion needs separate toolhead clearance evidence.',
                       candidate_plate=changed_plate(print_sequence='by_object'))
            yield case('sequential', 'clearance_supplied', 'allow', 'Only fixed-layout gate passes; external sequential clearance is an input assertion.',
                       candidate_plate=changed_plate(print_sequence='by_object', sequential_clearance_verified=True))

            b = copy.deepcopy(bed)
            b['holes'] = [rect(x + width * .5, y + depth * .5, x + width * .6, y + depth * .6)]
            yield case('unsupported_topology', 'bed_hole', 'requires_verification', 'Hole topology is not flattened into a solid bed.', candidate_bed=b)
            b = copy.deepcopy(bed)
            b['representation'] = 'circle_polygon_approximation'
            yield case('unsupported_topology', 'circle_approximation', 'requires_verification', 'Polygon approximation is not exact circular-bed evidence.', candidate_bed=b)
            b = copy.deepcopy(bed)
            b['printable_polygon'] = [[x, y], [x + width, y], [x + width, y + depth * .4],
                                      [x + width * .4, y + depth * .4], [x + width * .4, y + depth], [x, y + depth]]
            yield case('unsupported_topology', 'concave_bed', 'requires_verification', 'This gate supports convex printable regions only.', candidate_bed=b)
            p = changed_plate()
            p['footprints'][0]['holes'] = [rect(x + width * .15, y + depth * .15, x + width * .2, y + depth * .2)]
            yield case('unsupported_topology', 'footprint_hole', 'requires_verification', 'Unsupported holes cannot be assumed filled or empty.', candidate_plate=p)
            for name, shape in (
                ('self_intersection', [[x + 10, y + 10], [x + 30, y + 30], [x + 10, y + 30], [x + 30, y + 10]]),
                ('repeated_vertex', [[x + 10, y + 10], [x + 20, y + 10], [x + 20, y + 10], [x + 10, y + 20]]),
                ('collinear', [[x + 10, y + 10], [x + 20, y + 10], [x + 30, y + 10]]),
            ):
                yield case('invalid_polygon', name, 'requires_verification', 'Invalid or ambiguous occupied polygon cannot pass.', candidate_plate=occupied(shape))
            for value in (True, '10', None):
                p = changed_plate()
                p['footprints'][0]['polygon'][0][0] = value
                yield case('invalid_coordinate', str(value), 'requires_verification', 'Coordinates require finite numeric mm values, not coercion.', candidate_plate=p)
            p = changed_plate()
            p['footprints'][0]['representation'] = 'conservative_outer_bound'
            yield case('outer_bound', 'inside', 'allow', 'Complete outer bound inside all constraints proves containment.', candidate_plate=p)
            p['footprints'][0]['polygon'] = rect(x + width - 2, y + depth * .4, x + width + 2, y + depth * .5)
            yield case('outer_bound', 'outside', 'requires_verification', 'Outside coarse box alone does not prove actual geometry is outside.', candidate_plate=p)
            p = changed_plate()
            p['components']['brim'] = 'included'
            p['footprints'].append({'kind': 'brim', 'representation': 'exact_polygon',
                                    'polygon': rect(x + width * .08, y + depth * .08, x + width * .32, y + depth * .32)})
            yield case('area_diagnostic', 'overlapping_brim_and_object', 'allow', 'Summed polygon areas are not occupied union area or packing capacity.', candidate_plate=p)
            p = occupied([[x + width * .2, y + depth * .2], [x + width * .6, y + depth * .2],
                          [x + width * .4, y + depth * .6]])
            yield case('nonrectangular', 'triangle_inside', 'allow', 'Simple exact nonrectangular occupied footprint can be checked.', candidate_plate=p)


def check_case(row: dict) -> dict:
    if row.get('type') != FIXTURE_TYPE or row['expected'].get('label_origin') != 'synthetic_contract_expectation':
        raise ValueError('Missing synthetic fixture declaration')
    if sha256(row['input']) != row['case_id']:
        raise ValueError('Fixture identity mismatch')
    if layout_signature(**row['input']) != row['geometry_layout_id']:
        raise ValueError('Fixture layout identity mismatch')
    expected = row['expected']
    if expected['status'] not in STATUSES or expected.get('automatic_dispatch_authorized') is not False:
        raise ValueError('Invalid expected geometry-only verdict')
    actual = evaluate_bed_geometry(**row['input'])
    if actual['status'] != expected['status'] or actual['scope'] != expected['scope'] or actual['automatic_dispatch_authorized']:
        raise AssertionError(f"{row['family']}/{row['variant']}: expected {expected['status']}, got {actual}")
    if row['input']['plate']['artifact_kind'] == 'arrangement_candidate' and not actual['reslice_required']:
        raise AssertionError('Prospective arrangement was allowed without fresh slicing')
    if actual['metrics'] and actual['metrics'].get('footprint_area_sum_is_union') is not False:
        raise AssertionError('Area sum was misrepresented as occupied union')
    return actual


def generate_bundle(output: Path) -> dict:
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    path = output / 'geometry-challenges.jsonl'
    labels, families, variants, layouts, seen, groups = Counter(), Counter(), set(), set(), set(), set()
    with path.open('wb') as handle:
        for row in iter_cases():
            check_case(row)
            if row['case_id'] in seen:
                raise AssertionError('Duplicate fixture input')
            seen.add(row['case_id'])
            layouts.add(row['geometry_layout_id'])
            variants.add((row['family'], row['variant']))
            groups.add(row['construction_group'])
            labels[row['expected']['status']] += 1
            families[row['family']] += 1
            handle.write(encoded(row) + b'\n')
    if not 1000 <= len(seen) <= 10000:
        raise AssertionError('Unexpected fixture count')
    sources = {name: {'path': name, 'sha256': file_hash(Path(__file__).with_name(name))}
               for name in ('bed_geometry.py', 'geometry_challenges.py')}
    manifest = {'schema_version': 1, 'type': FIXTURE_TYPE, 'created_at_utc': datetime.now(timezone.utc).isoformat(),
                'deployable': False, 'ranking_training_data': False, 'real_observations': 0,
                'expected_label_origin': 'synthetic_contract_expectation',
                'automatic_dispatch_authorized': False, 'scope': 'fixed_plate_geometry_only',
                'count': len(seen), 'unique_complete_inputs': len(seen),
                'unique_geometry_layouts': len(layouts), 'construction_groups': len(groups),
                'construction_variants': len(variants), 'status_counts': dict(sorted(labels.items())),
                'family_counts': dict(sorted(families.items())),
                'bed_shapes_mm': BED_SHAPES_MM, 'origin_modes': ORIGIN_MODES,
                'dimensions_source': 'invented_test_fixture_not_manufacturer', 'sources': sources,
                'file': {'name': path.name, 'sha256': file_hash(path), 'bytes': path.stat().st_size},
                'verification': {'all_rows_executed': True, 'all_expected_statuses_match': True},
                'limitations': ['Parameter sweeps are related constructions, not independent real print samples.',
                                'Geometry/layout uniqueness does not establish statistical independence or real training-data volume.',
                                'Exact artifact hashes and verification flags are synthetic test assertions only.',
                                'No manufacturer dimensions, packing, ranking, capacity reservation or production dispatch are inferred.',
                                'The gate trusts its parser evidence contract; this corpus does not validate any real 3MF parser.',
                                'Complex holes/circular beds/nonconvex printable regions remain unsupported and uncertain.']}
    (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (output / 'README.md').write_text(
        '# Synthetic geometry eligibility fixtures\n\n'
        f'{len(seen)} complete inputs; {len(layouts)} geometric layouts; {len(variants)} construction variants '
        f'across {len(groups)} contexts. These counts do not represent real print records or statistically independent samples.\n\n'
        'Every record is `synthetic_eligibility_fixture`. Expected results are software-contract expectations '
        'specified by construction and verified against the fixed-layout gate, never human/print-outcome labels. '
        '`allow` covers only the supplied geometry layer and never authorizes execution.\n\n'
        'All bed dimensions and hashes are invented. This corpus does not train printer ranking, infer manufacturer '
        'specifications, reserve capacity, pack objects or combine G-code. Prospective arrangements still require '
        'slicing; pre-sliced jobs may not be rotated, translated, scaled or sent across models by this check.\n\n'
        'See manifest.json for actual coverage, unknown cases, source hashes and file checksum.\n', encoding='utf-8')
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='New output directory; existing content is never overwritten.')
    args = parser.parse_args()
    manifest = generate_bundle(args.output)
    print(json.dumps({'output': str(args.output.resolve()), 'count': manifest['count'],
                      'unique_geometry_layouts': manifest['unique_geometry_layouts'],
                      'status_counts': manifest['status_counts'], 'deployable': False}, ensure_ascii=False))


if __name__ == '__main__':
    main()
