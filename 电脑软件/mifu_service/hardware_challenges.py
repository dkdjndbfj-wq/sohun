"""Synthetic, layer-scoped hardware admission challenges; never a dispatch API.

This standard-library-only tool exports deterministic boundary cases for separate
constraint testing. Its labels are reference rules, not real print outcomes,
model preferences, reward labels or proof that the production app enforces every
design-contract rule. `allow` always means ONLY the named layer passed.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import itertools
import json
from pathlib import Path
from typing import Any, Iterator


DEFAULT_MATRIX = Path(__file__).with_name('hardware_matrix.json')
LABELS = ('allow', 'blocked', 'requires_verification')
ADDITIONAL_SOURCES = {
    'local_cluster_gate': {
        'path': '电脑软件/lib/core/services/cluster_planning_service.dart',
        'sha256': '0be0d03439922d35819e01f80ebc832ee05eb82960afca5ad292f8e47ecfb289',
        'scope': 'Existing telemetry, exact artifact and channel-based material gates.',
    },
    'local_spool_policy': {
        'path': '电脑软件/lib/core/constants/personal_spool_policy.dart',
        'sha256': '46ee002442dac541244a6998c234171fcf971404b1c730fd0297cdfd4ed8f75d',
        'scope': '1000 g physical spool; reuse requires remaining strictly above 30 g.',
    },
    'maintenance_design_contract': {
        'path': 'docs/mifu-printer-scoring-design.md',
        'sha256': '3d52c4d9ef3bc96d0e44013eb88ac6bf13bccd577d26fd053f82eb93f533bc4a',
        'scope': 'Future maintenance/slot-lock and physical-spool identity contract, not an implemented production claim.',
    },
}
LAYER_SOURCES = {
    'feeder_material': ['official_ams_notes', 'official_ams_2_pro', 'official_ams_ht', 'official_ams_lite', 'official_tpu_for_ams', 'official_tpu_95a_hf', 'official_petg_cf'],
    'product_nozzle': ['official_tpu_for_ams', 'official_tpu_95a_hf', 'official_petg_cf', 'local_nozzle_defaults'],
    'connection_quota': ['local_feed_presets', 'official_ams_guide'],
    'configuration': ['local_feed_presets', 'official_ams_guide'],
    'artifact_match': ['local_model_normalizer', 'local_cluster_gate', 'official_bambu_studio_catalog'],
    'feed_route': ['local_feed_gate', 'local_feed_routing'],
    'slot_readiness': ['local_feed_gate', 'maintenance_design_contract'],
    'maintenance': ['maintenance_design_contract'],
    'shared_spool_budget': ['local_spool_policy', 'local_cluster_gate', 'maintenance_design_contract'],
}


def encoded(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def load_matrix(path: Path = DEFAULT_MATRIX) -> dict:
    matrix = json.loads(path.read_text(encoding='utf-8'))
    ids = [model['id'] for model in matrix['models']]
    if matrix.get('schema_version') != 1 or not ids or len(set(ids)) != len(ids):
        raise ValueError('Unsupported or duplicate hardware matrix')
    return matrix


def number(value: Any) -> Decimal | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        result = Decimal(str(value))
        return result if result.is_finite() else None
    except (ValueError, InvalidOperation):
        return None


def verdict(label: str, reason: str, **details: Any) -> dict:
    if label not in LABELS:
        raise ValueError(label)
    return {'label': label, 'reason': reason, 'automatic_dispatch_authorized': False,
            'scope': 'named_check_layer_only', **details}


class HardwareChecks:
    def __init__(self, matrix: dict):
        self.matrix = matrix
        self.models = {item['id']: item for item in matrix['models']}
        facts = matrix['material_path_facts']
        self.products = {item['id']: item for item in facts['exact_products']}
        self.feeders = {item['ams_type']: item for item in facts['feeder_profiles']}

    def evaluate(self, layer: str, data: dict) -> dict:
        if layer not in LAYER_SOURCES:
            raise ValueError('Unknown check layer: ' + layer)
        return getattr(self, 'check_' + layer)(data)

    def check_feeder_material(self, data: dict) -> dict:
        ams = data.get('ams_type')
        profile = self.feeders.get(ams)
        if not profile:
            return verdict('requires_verification', 'unmapped_feeder')
        material = data.get('material_id')
        if not isinstance(material, str) or not material:
            return verdict('requires_verification', 'material_identity_missing')
        if material.startswith('bambu_') and data.get('product_identity_verified') is not True:
            return verdict('requires_verification', 'exact_product_identity_unverified')
        route = data.get('route')
        if route == 'manual_bypass':
            if ams != 'ams_ht':
                return verdict('requires_verification', 'bypass_capability_unverified')
            return verdict('requires_verification', 'manual_bypass_is_not_automatic_feed')
        if route != 'automatic_ams':
            return verdict('requires_verification', 'route_outside_automatic_feeder_scope')
        product = self.products.get(material)
        if product:
            if ams not in product.get('automatic_ams_types', []):
                return verdict('blocked', 'exact_product_disallows_automatic_feeder')
            if product.get('dry_before_use'):
                if data.get('dry_state') == 'wet':
                    return verdict('blocked', 'product_requires_drying')
                if data.get('dry_state') != 'dry':
                    return verdict('requires_verification', 'dry_state_unknown')
            return verdict('allow', 'exact_product_feeder_conditions_pass')
        family = material.removeprefix('generic_') if material.startswith('generic_') else None
        if family in ('PVA', 'BVOH') and data.get('dry_state') == 'wet':
            exclusions = profile.get('automatic_feed_exclusions', []) + profile.get('all_feed_exclusions', [])
            if 'damp_' + family in exclusions or (ams == 'ams' and family == 'PVA'):
                return verdict('blocked', 'damp_soluble_material_disallowed')
        # These fields intentionally distinguish recommendation from exclusion.
        if material in profile.get('automatic_feed_not_recommended', []):
            return verdict('requires_verification', 'official_not_recommended_requires_review')
        if material in profile.get('manual_bypass_only', []) or (family is not None and family in profile.get('manual_bypass_only', [])):
            return verdict('blocked', 'material_requires_manual_bypass')
        exclusions = profile.get('automatic_feed_exclusions', [])
        if material in exclusions or (family is not None and family in exclusions):
            return verdict('blocked', 'material_feeder_excluded')
        if ams == 'ams' and family in ('TPU', 'TPE', 'CF_GF'):
            return verdict('requires_verification', 'original_ams_official_avoid_guidance')
        if family == 'CF_GF':
            if 'other_CF_GF_without_product_exception' in exclusions or ams == 'ams_lite':
                return verdict('blocked', 'unverified_fiber_product_feeder_excluded')
            if 'other_CF_GF_without_product_exception' in profile.get('manual_bypass_only', []):
                return verdict('blocked', 'fiber_product_requires_manual_bypass')
        if family in profile.get('automatic_feed_requires_dry', []):
            if data.get('dry_state') != 'dry':
                return verdict('requires_verification', 'dry_state_unknown')
            return verdict('allow', 'dry_soluble_material_feeder_conditions_pass')
        if family in profile.get('automatic_feed_material_families', []):
            return verdict('allow', 'listed_family_feeder_only_pass')
        if material in profile.get('automatic_feed_verified_branded_products', []):
            return verdict('allow', 'listed_branded_product_feeder_only_pass')
        return verdict('requires_verification', 'material_feeder_fact_missing')

    def check_product_nozzle(self, data: dict) -> dict:
        product = self.products.get(data.get('material_id'))
        if not product:
            return verdict('requires_verification', 'product_nozzle_fact_missing')
        if data.get('product_identity_verified') is not True:
            return verdict('requires_verification', 'exact_product_identity_unverified')
        diameter = number(data.get('nozzle_diameter_mm'))
        if diameter is None or diameter <= 0:
            return verdict('requires_verification', 'installed_diameter_unknown_or_invalid')
        if diameter in [number(value) for value in product.get('excluded_nozzle_diameters_mm', [])]:
            return verdict('blocked', 'product_excludes_nozzle_diameter')
        nozzle = data.get('nozzle_material')
        for excluded in product.get('excluded_nozzle_configurations', []):
            if diameter == number(excluded['diameter_mm']):
                if nozzle == excluded['material']:
                    return verdict('blocked', 'product_excludes_nozzle_configuration')
                if nozzle not in ('hardened_steel', 'stainless_steel'):
                    return verdict('requires_verification', 'nozzle_material_unknown')
        required = product.get('required_nozzle_material')
        if required:
            if nozzle not in ('hardened_steel', 'stainless_steel'):
                return verdict('requires_verification', 'abrasive_nozzle_material_unknown')
            if nozzle != required:
                return verdict('blocked', 'abrasive_product_requires_hardened_nozzle')
        allowed = product.get('explicitly_documented_nozzle_diameters_mm')
        if allowed and diameter not in [number(value) for value in allowed]:
            return verdict('requires_verification', 'product_diameter_not_explicitly_documented')
        if diameter not in (Decimal('.2'), Decimal('.4'), Decimal('.6'), Decimal('.8')):
            return verdict('requires_verification', 'unlisted_diameter')
        return verdict('allow', 'documented_product_nozzle_restrictions_pass',
                       installed_model_nozzle_combination_verified=False)

    def check_connection_quota(self, data: dict) -> dict:
        model = self.models.get(data.get('model_id'))
        if not model:
            return verdict('requires_verification', 'unmapped_model')
        counts = data.get('counts')
        ids = [item['id'] for item in self.matrix['ams_types']]
        if not isinstance(counts, dict) or set(counts) != set(ids):
            return verdict('requires_verification', 'connection_counts_incomplete_or_unknown_type')
        if any(type(value) is not int or value < 0 for value in counts.values()):
            return verdict('requires_verification', 'connection_count_invalid')
        feed = model['feed']
        if any(counts[name] > 0 and name not in feed['allowed_ams_types'] for name in ids):
            return verdict('blocked', 'ams_type_not_supported_by_model')
        four = counts['ams'] + counts['ams_2_pro']
        ht, lite = counts['ams_ht'], counts['ams_lite']
        if four > feed['four_slot_combined_max']:
            return verdict('blocked', 'original_and_2pro_share_four_slot_quota')
        if ht > feed['ht_max']:
            return verdict('blocked', 'ht_quota_exceeded')
        if lite > feed['lite_max']:
            return verdict('blocked', 'lite_quota_exceeded')
        if four + ht > feed['regular_units_max']:
            return verdict('blocked', 'regular_combined_quota_exceeded')
        if lite and four + ht and not feed['lite_can_mix_with_regular']:
            return verdict('blocked', 'lite_cannot_mix_with_regular')
        return verdict('allow', 'connection_count_limits_pass',
                       firmware_accessories_presence_and_routes_verified=False)

    def check_configuration(self, data: dict) -> dict:
        model = self.models.get(data.get('model_id'))
        if not model:
            return verdict('requires_verification', 'unmapped_model')
        ams = data.get('ams_type')
        if ams not in self.feeders:
            return verdict('requires_verification', 'unmapped_feeder')
        if ams not in model['feed']['allowed_ams_types']:
            return verdict('blocked', 'ams_type_not_supported_by_model')
        if data.get('accessories_verified') is False:
            return verdict('blocked', 'required_accessories_missing')
        if data.get('accessories_verified') is not True:
            return verdict('requires_verification', 'required_accessories_unknown')
        if data.get('firmware_support_verified') is False:
            return verdict('blocked', 'firmware_known_incompatible')
        if data.get('firmware_support_verified') is not True:
            return verdict('requires_verification', 'firmware_support_unknown')
        if model['id'] in ('A1', 'A1mini') and ams != 'ams_lite':
            version = data.get('firmware_version')
            try:
                parts = tuple(int(value) for value in version.split('.'))
                if len(parts) != 4 or any(value < 0 for value in parts):
                    raise ValueError()
            except (AttributeError, ValueError):
                return verdict('requires_verification', 'a1_firmware_version_missing_or_invalid')
            if parts < (1, 7, 0, 0):
                return verdict('blocked', 'a1_regular_ams_requires_firmware_01070000')
        return verdict('allow', 'declared_configuration_prerequisites_pass')

    def check_artifact_match(self, data: dict) -> dict:
        actual = self.models.get(data.get('installed_model_id'))
        target = self.models.get(data.get('target_model_id'))
        if not actual or not target:
            return verdict('requires_verification', 'exact_model_identity_unknown')
        if actual['id'] != target['id']:
            return verdict('blocked', 'pre_sliced_exact_model_mismatch')
        observed = number(data.get('installed_nozzle_mm'))
        sliced = number(data.get('target_nozzle_mm'))
        if observed is None or sliced is None or observed <= 0 or sliced <= 0:
            return verdict('requires_verification', 'exact_nozzle_evidence_missing')
        supported = [number(value) for value in actual['nozzle_diameters_mm']]
        if observed not in supported or sliced not in supported:
            return verdict('requires_verification', 'nozzle_profile_not_in_snapshot')
        if abs(observed - sliced) >= Decimal('.001'):
            return verdict('blocked', 'pre_sliced_exact_nozzle_mismatch')
        return verdict('allow', 'exact_model_and_nozzle_match_only')

    def check_feed_route(self, data: dict) -> dict:
        model = self.models.get(data.get('model_id'))
        if not model:
            return verdict('requires_verification', 'unmapped_model')
        if any(type(data.get(key)) is not bool for key in ('uses_ams', 'uses_external')) or not (data['uses_ams'] or data['uses_external']):
            return verdict('requires_verification', 'selected_feed_sources_missing')
        feed = model['feed']
        if data.get('uses_external') is True and data.get('fts_present') is True:
            return verdict('blocked', 'external_feed_with_fts')
        if data.get('fts_present') is not False:
            return verdict('requires_verification', 'fts_route_unverified')
        if data.get('uses_ams') is True and data.get('ams_presence_verified') is not True:
            return verdict('requires_verification', 'live_ams_presence_missing')
        if data.get('uses_ams') is True and data.get('uses_external') is True:
            if not feed['ams_external_coexist']:
                return verdict('blocked', 'single_path_cannot_mix_ams_external')
            if data.get('ams_and_external_same_path') is True:
                return verdict('blocked', 'ams_external_same_physical_path')
            if data.get('ams_and_external_same_path') is not False:
                return verdict('requires_verification', 'mixed_path_assignment_unknown')
        if model['id'] == 'A2L' and data.get('regular_ams_present') is True:
            lite_slots = data.get('active_lite_slots')
            if type(lite_slots) is not int or lite_slots < 0:
                return verdict('requires_verification', 'mixed_lite_slot_count_unknown')
            if lite_slots > 3:
                return verdict('blocked', 'mixed_lite_at_most_three_active_slots')
        if feed['physical_external_paths'] == 2:
            if data.get('selected_plate_mapping_verified') is not True:
                return verdict('requires_verification', 'selected_plate_tool_map_missing')
            source, target = data.get('source_path'), data.get('target_path')
            if type(source) is not int or source not in (0, 1) or type(target) is not int or target not in (0, 1):
                return verdict('requires_verification', 'physical_extruder_route_unknown')
            if source != target:
                return verdict('blocked', 'physical_extruder_route_mismatch')
        elif data.get('external_channel') == 254:
            return verdict('blocked', 'left_external_path_not_present')
        return verdict('allow', 'specified_route_layer_pass')

    def check_slot_readiness(self, data: dict) -> dict:
        if data.get('slot_fault') is True or data.get('slot_disabled') is True:
            return verdict('blocked', 'selected_slot_fault_or_disabled')
        if data.get('slot_present') is False or data.get('filament_present') is False:
            return verdict('blocked', 'selected_slot_or_filament_absent')
        if data.get('ams_type') not in self.feeders:
            return verdict('requires_verification', 'unmapped_feeder')
        expected = {'slot_present': True, 'filament_present': True, 'slot_fault': False, 'slot_disabled': False}
        if any(data.get(key) is not value for key, value in expected.items()):
            return verdict('requires_verification', 'selected_slot_observation_incomplete')
        return verdict('allow', 'selected_slot_readiness_only')

    def check_maintenance(self, data: dict) -> dict:
        # Design contract: health score, idle telemetry and acknowledged HMS
        # deliberately cannot clear an independent repair/acceptance lock.
        state = data.get('maintenance_state')
        if state in ('repairing', 'waiting_parts', 'awaiting_acceptance', 'restricted_trial'):
            return verdict('blocked', 'maintenance_blocks_normal_production')
        if state not in ('clear', 'accepted'):
            return verdict('requires_verification', 'maintenance_state_unknown')
        if data.get('validation_matches_current_configuration') is not True:
            return verdict('requires_verification', 'post_repair_configuration_validation_missing')
        return verdict('allow', 'maintenance_contract_only_pass')

    def check_shared_spool_budget(self, data: dict) -> dict:
        runs = data.get('runs')
        if type(runs) is not int or runs <= 0:
            return verdict('requires_verification', 'run_count_invalid')
        spools, demands = {}, defaultdict(Decimal)
        records, tools = data.get('spools'), data.get('tools')
        if not isinstance(records, list) or not records or not isinstance(tools, list) or not tools:
            return verdict('requires_verification', 'physical_spool_evidence_missing')
        for spool in records:
            identity = spool.get('physical_spool_id')
            remaining, reserved = number(spool.get('remaining_g')), number(spool.get('reserved_g'))
            if not isinstance(identity, str) or not identity or remaining is None or reserved is None:
                return verdict('requires_verification', 'physical_spool_identity_or_balance_missing')
            if remaining < 0 or remaining > 1000 or reserved < 0 or reserved > remaining:
                return verdict('requires_verification', 'physical_spool_balance_invalid_not_clamped')
            observation = (remaining, reserved)
            if identity in spools and spools[identity] != observation:
                return verdict('requires_verification', 'same_physical_spool_conflicting_observations')
            spools[identity] = observation
        for tool in tools:
            identity, grams = tool.get('physical_spool_id'), number(tool.get('grams_per_run'))
            if identity not in spools or grams is None or grams <= Decimal('.01'):
                return verdict('requires_verification', 'tool_physical_spool_demand_invalid')
            demands[identity] += grams
        audit = {}
        for identity, per_run in demands.items():
            remaining, reserved = spools[identity]
            available = remaining - reserved
            total = per_run * runs
            buffer = max(Decimal(5), total * Decimal('.1'))
            audit[identity] = {'available_g': str(available), 'summed_grams_per_run': str(per_run),
                               'total_demand_g': str(total), 'safety_buffer_g': str(buffer)}
            if available - per_run * (runs - 1) <= 30:
                return verdict('blocked', 'every_run_start_must_exceed_30g', physical_spool_audit=audit)
            if total + buffer > available + Decimal('.001'):
                return verdict('blocked', 'shared_spool_demand_plus_buffer_exceeds_available', physical_spool_audit=audit)
        return verdict('allow', 'shared_physical_spool_budget_only_pass', physical_spool_audit=audit,
                       inventory_reservation_performed=False)


def challenge_inputs(matrix: dict) -> Iterator[tuple[str, dict]]:
    """No random repetition: each row is a distinct systematic input case."""
    models = [item['id'] for item in matrix['models']]
    ams_types = [item['id'] for item in matrix['ams_types']] + ['ams_3h', 'unknown']
    materials = ['generic_PLA', 'generic_PETG', 'generic_TPU', 'generic_TPE', 'generic_PVA', 'generic_BVOH',
                 'generic_ABS', 'generic_ASA', 'generic_PC', 'generic_CF_GF', 'bambu_pla_cf',
                 'bambu_tpu_for_ams', 'bambu_tpu_95a_hf', 'bambu_petg_cf', 'unknown']
    for ams, material, dry, route in itertools.product(ams_types, materials, ('dry', 'wet', 'unknown'), ('automatic_ams', 'manual_bypass', 'external')):
        for verified in ((True, False, None) if material.startswith('bambu_') else (None,)):
            yield 'feeder_material', {'ams_type': ams, 'material_id': material, 'dry_state': dry,
                                     'route': route, 'product_identity_verified': verified}
    for material, diameter, nozzle, identity in itertools.product(
            ['bambu_tpu_for_ams', 'bambu_tpu_95a_hf', 'bambu_petg_cf', 'generic_TPU', 'generic_CF_GF'],
            [None, 0.2, 0.4, 0.5, 0.6, 0.8], ['hardened_steel', 'stainless_steel', 'unknown'], [True, False, None]):
        yield 'product_nozzle', {'material_id': material, 'nozzle_diameter_mm': diameter,
                                'nozzle_material': nozzle, 'product_identity_verified': identity}
    for model in matrix['models']:
        feed = model['feed']
        for original, pro, ht, lite in itertools.product(range(feed['four_slot_combined_max'] + 2),
                range(feed['four_slot_combined_max'] + 2), range(feed['ht_max'] + 2), range(3)):
            yield 'connection_quota', {'model_id': model['id'], 'counts': {
                'ams': original, 'ams_2_pro': pro, 'ams_ht': ht, 'ams_lite': lite}}
    for model in ('H3C', 'unknown'):
        yield 'connection_quota', {'model_id': model, 'counts': {'ams': 0, 'ams_2_pro': 0, 'ams_ht': 0, 'ams_lite': 0}}
    for counts in ({'ams_3h': 1}, {'ams': None, 'ams_2_pro': 0, 'ams_ht': 0, 'ams_lite': 0},
                   {'ams': -1, 'ams_2_pro': 0, 'ams_ht': 0, 'ams_lite': 0}):
        yield 'connection_quota', {'model_id': 'H2D', 'counts': counts}
    for model, ams, accessories, firmware in itertools.product(models + ['H3C'], ams_types, (True, False, None), (True, False, None)):
        versions = (None, '01.06.99.99', '01.07.00.00', '01.08.00.00') if model in ('A1', 'A1mini') and ams != 'ams_lite' else (None,)
        for version in versions:
            yield 'configuration', {'model_id': model, 'ams_type': ams, 'accessories_verified': accessories,
                                   'firmware_support_verified': firmware, 'firmware_version': version}
    for installed, target, actual_nozzle, target_nozzle in itertools.product(
            models + ['H3C', None], models + ['H3C', None], (None, 0.2, 0.4, 0.5, 0.6, 0.8), (None, 0.2, 0.4, 0.5, 0.6, 0.8)):
        yield 'artifact_match', {'installed_model_id': installed, 'target_model_id': target,
                                'installed_nozzle_mm': actual_nozzle, 'target_nozzle_mm': target_nozzle}
    for model in matrix['models']:
        path_pairs = itertools.product((0, 1, None), repeat=2) if model['feed']['physical_external_paths'] == 2 else [(0, 0)]
        for (source, target), fts, mixed, same, present in itertools.product(list(path_pairs), (True, False, None), (False, True), (False, True, None), (True, None)):
            yield 'feed_route', {'model_id': model['id'], 'source_path': source, 'target_path': target,
                'uses_ams': True, 'uses_external': mixed, 'fts_present': fts,
                'ams_and_external_same_path': same, 'ams_presence_verified': present,
                'selected_plate_mapping_verified': True, 'regular_ams_present': True, 'active_lite_slots': 0}
        for channel in (254, 255):
            yield 'feed_route', {'model_id': model['id'], 'uses_ams': False, 'uses_external': True,
                'external_channel': channel, 'fts_present': False, 'source_path': 1 if channel == 254 else 0,
                'target_path': 1 if channel == 254 else 0, 'selected_plate_mapping_verified': True}
    for count in (None, 0, 1, 2, 3, 4):
        yield 'feed_route', {'model_id': 'A2L', 'uses_ams': True, 'uses_external': False, 'fts_present': False,
                            'ams_presence_verified': True, 'regular_ams_present': True, 'active_lite_slots': count}
    yield 'feed_route', {'model_id': 'H2D', 'uses_ams': True, 'uses_external': False, 'fts_present': False,
                        'ams_presence_verified': True, 'selected_plate_mapping_verified': False}
    for ams, present, filament, fault, disabled in itertools.product(ams_types, (True, False, None), (True, False, None), (True, False, None), (True, False, None)):
        yield 'slot_readiness', {'ams_type': ams, 'slot_present': present, 'filament_present': filament,
                                'slot_fault': fault, 'slot_disabled': disabled}
    for state, validation, idle, score, acknowledged in itertools.product(
            ('clear', 'repairing', 'waiting_parts', 'awaiting_acceptance', 'restricted_trial', 'accepted', 'unknown'),
            (True, False, None), (True, False), (0, 100), (True, False)):
        yield 'maintenance', {'maintenance_state': state, 'validation_matches_current_configuration': validation,
                              'idle_telemetry': idle, 'historical_score': score, 'hms_acknowledged': acknowledged}
    balances = (None, '-1', '0', '29.99', '30', '30.001', '35', '50', '100', '999.99', '1000', '1000.01')
    for remaining, reserved, runs, pattern in itertools.product(balances, (None, '0', '10', '30', '200'), (1, 2, 5),
            (('5',), ('10', '10'), ('15', '20'), ('50', '100'))):
        yield 'shared_spool_budget', {'runs': runs,
            'spools': [{'physical_spool_id': 'roll-A', 'remaining_g': remaining, 'reserved_g': reserved}],
            'tools': [{'physical_spool_id': 'roll-A', 'channel_alias': 'channel-' + str(i), 'grams_per_run': grams}
                      for i, grams in enumerate(pattern)]}
    for second_balance in ('100', '101'):
        yield 'shared_spool_budget', {'runs': 1, 'spools': [
            {'physical_spool_id': 'roll-A', 'remaining_g': '100', 'reserved_g': '0'},
            {'physical_spool_id': 'roll-A', 'remaining_g': second_balance, 'reserved_g': '0'}],
            'tools': [{'physical_spool_id': 'roll-A', 'grams_per_run': '50'},
                      {'physical_spool_id': 'roll-A', 'grams_per_run': '50'}]}
    yield 'shared_spool_budget', {'runs': 1, 'spools': [
        {'physical_spool_id': name, 'remaining_g': '100', 'reserved_g': '0'} for name in ('roll-A', 'roll-B')],
        'tools': [{'physical_spool_id': name, 'grams_per_run': '50'} for name in ('roll-A', 'roll-B')]}


def generate(output: Path, matrix_path: Path = DEFAULT_MATRIX) -> dict:
    matrix = load_matrix(matrix_path)
    checker = HardwareChecks(matrix)
    # Exclusive directory creation prevents accidental replacement of prior data.
    output.mkdir(parents=True, exist_ok=False)
    counts, by_layer, reasons = Counter(), defaultdict(Counter), Counter()
    dimensions: dict[str, Counter] = defaultdict(Counter)
    seen, digest = set(), hashlib.sha256()
    count = 0
    records = output / 'hardware-challenges.jsonl'
    with records.open('xb') as handle:
        for layer, data in challenge_inputs(matrix):
            identity = hashlib.sha256(encoded({'layer': layer, 'input': data})).hexdigest()
            if identity in seen:
                raise ValueError('Duplicate boundary case: ' + identity)
            seen.add(identity)
            expected = checker.evaluate(layer, data)
            row = {
                'schema_version': 1, 'id': 'hardware-' + identity[:24], 'check_layer': layer,
                'input': data, 'expected': expected, 'source_ids': LAYER_SOURCES[layer],
                'provenance': {'source': 'synthetic_hardware_constraint_challenge', 'real_print_outcome': False,
                    'decision_model_training_example': False, 'production_dispatch_example': False,
                    'rule_status': 'design_contract_includes_future_features' if layer in (
                        'maintenance', 'slot_readiness', 'shared_spool_budget') else 'documented_reference_rule'},
            }
            line = encoded(row) + b'\n'
            handle.write(line)
            digest.update(line)
            count += 1
            counts[expected['label']] += 1
            by_layer[layer][expected['label']] += 1
            reasons[expected['reason']] += 1
            for key in ('model_id', 'installed_model_id', 'target_model_id', 'ams_type', 'material_id',
                        'nozzle_diameter_mm', 'nozzle_material', 'dry_state', 'route'):
                if key in data:
                    dimensions[key][str(data[key])] += 1
    manifest = {
        'schema_version': 1, 'generated_at': datetime.now(timezone.utc).isoformat(),
        'kind': 'synthetic_hardware_constraint_challenge_bundle', 'records': count, 'unique_inputs': len(seen),
        'labels': dict(counts), 'coverage_by_layer': {key: dict(value) for key, value in sorted(by_layer.items())},
        'coverage_by_dimension': {key: dict(sorted(value.items())) for key, value in sorted(dimensions.items())},
        'reason_counts': dict(sorted(reasons.items())), 'records_file': records.name,
        'records_sha256': digest.hexdigest(), 'matrix_sha256': file_hash(matrix_path),
        'generator_sha256': file_hash(Path(__file__)), 'matrix_snapshot_date': matrix['snapshot_date'],
        'sources': {**matrix['sources'], **ADDITIONAL_SOURCES},
        'training_performed': False, 'production_dispatch_authorized': False,
        'allow_scope': 'Only the named check layer. All other required layers and real evidence remain unchecked.',
        'intended_use': 'Independent constraint regression fixtures; not Laya/Mifu choice training data.',
        'label_origin': 'Deterministic reference checks derived from cited specifications or explicitly labelled design contracts; no measured outcomes.',
        'coverage_gaps': matrix['coverage_gaps'] + [
            'No integrated end-to-end admission proof; a layer allow is never a runnable print job.',
            'Maintenance and slot faults include future design-contract checks, not claims that current production routes enforce them.',
            'Spool tests use shared physical identity; the existing planner primarily keys demand by channel.',
            'No hardware operation, inventory reservation, model training or printer command is performed.',
        ],
    }
    with (output / 'manifest.json').open('x', encoding='utf-8', newline='\n') as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write('\n')
    return manifest


def validate_bundle(output: Path) -> dict:
    manifest = json.loads((output / 'manifest.json').read_text(encoding='utf-8'))
    records = output / manifest['records_file']
    if records.parent.resolve() != output.resolve() or file_hash(records) != manifest['records_sha256']:
        raise ValueError('Challenge file path or hash mismatch')
    count, ids, labels = 0, set(), Counter()
    with records.open(encoding='utf-8') as handle:
        for line in handle:
            row = json.loads(line)
            if row['id'] in ids or row['expected']['label'] not in LABELS:
                raise ValueError('Duplicate ID or unknown label')
            if row['expected']['automatic_dispatch_authorized'] is not False:
                raise ValueError('Challenge wrongly authorizes dispatch')
            if row['provenance']['source'] != 'synthetic_hardware_constraint_challenge':
                raise ValueError('Challenge provenance missing')
            ids.add(row['id'])
            count += 1
            labels[row['expected']['label']] += 1
    if count != manifest['records'] or dict(labels) != manifest['labels']:
        raise ValueError('Manifest coverage count mismatch')
    return {'records': count, 'labels': dict(labels), 'hash_verified': True}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--matrix', type=Path, default=DEFAULT_MATRIX)
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args()
    if args.validate_only:
        result = validate_bundle(args.output)
    else:
        manifest = generate(args.output, args.matrix)
        result = validate_bundle(args.output)
        result['coverage_by_layer'] = manifest['coverage_by_layer']
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
