from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from hardware_challenges import HardwareChecks, generate, load_matrix, validate_bundle


class HardwareChallengeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.matrix = load_matrix()
        cls.checks = HardwareChecks(cls.matrix)

    def check(self, layer, label, **data):
        result = self.checks.evaluate(layer, data)
        self.assertEqual(label, result['label'], result)
        self.assertFalse(result['automatic_dispatch_authorized'])
        self.assertEqual('named_check_layer_only', result['scope'])
        return result

    def material(self, material='bambu_tpu_for_ams', ams='ams_2_pro', dry='dry', route='automatic_ams', identity=True):
        return dict(material_id=material, ams_type=ams, dry_state=dry,
                    route=route, product_identity_verified=identity)

    def test_tpu_product_identity_cannot_be_replaced_by_generic_tpu(self):
        self.check('feeder_material', 'allow', **self.material())
        self.check('feeder_material', 'blocked', **self.material('generic_TPU'))
        self.check('feeder_material', 'blocked', **self.material('bambu_tpu_95a_hf'))
        self.check('feeder_material', 'requires_verification', **self.material(identity=False))
        self.check('feeder_material', 'requires_verification', **self.material(identity=None))

    def test_all_current_ams_accept_exact_dry_tpu_for_ams_at_feeder_layer_only(self):
        for ams in ('ams', 'ams_2_pro', 'ams_ht', 'ams_lite'):
            self.check('feeder_material', 'allow', **self.material(ams=ams))
            self.check('feeder_material', 'blocked', **self.material(ams=ams, dry='wet'))
            self.check('feeder_material', 'requires_verification', **self.material(ams=ams, dry='unknown'))
        self.check('feeder_material', 'requires_verification', **self.material(ams='ams_3h'))

    def test_ht_bypass_is_never_automatic_loading(self):
        for material in ('generic_TPU', 'generic_TPE', 'generic_CF_GF'):
            self.check('feeder_material', 'blocked', **self.material(material, 'ams_ht'))
            self.check('feeder_material', 'requires_verification', **self.material(material, 'ams_ht', route='manual_bypass'))
        self.check('feeder_material', 'requires_verification', **self.material('generic_TPU', 'ams_2_pro', route='manual_bypass'))

    def test_abs_lite_differs_from_pro_and_soluble_material_needs_dry_evidence(self):
        self.check('feeder_material', 'blocked', **self.material('generic_ABS', 'ams_lite'))
        self.check('feeder_material', 'allow', **self.material('generic_ABS', 'ams_2_pro'))
        for ams in ('ams_2_pro', 'ams_ht', 'ams_lite'):
            self.check('feeder_material', 'allow', **self.material('generic_PVA', ams))
            self.check('feeder_material', 'blocked', **self.material('generic_PVA', ams, dry='wet'))
            self.check('feeder_material', 'requires_verification', **self.material('generic_PVA', ams, dry='unknown'))

    def test_petg_cf_is_product_specific_and_lite_is_excluded(self):
        self.check('feeder_material', 'allow', **self.material('bambu_petg_cf'))
        self.check('feeder_material', 'blocked', **self.material('bambu_petg_cf', 'ams_lite'))
        self.check('feeder_material', 'blocked', **self.material('generic_CF_GF', 'ams_2_pro'))

    def test_product_nozzle_boundaries_do_not_infer_hardened_default(self):
        base = dict(material_id='bambu_petg_cf', product_identity_verified=True)
        self.check('product_nozzle', 'blocked', **base, nozzle_diameter_mm=.2, nozzle_material='hardened_steel')
        self.check('product_nozzle', 'blocked', **base, nozzle_diameter_mm=.4, nozzle_material='stainless_steel')
        self.check('product_nozzle', 'requires_verification', **base, nozzle_diameter_mm=.4, nozzle_material='unknown')
        self.check('product_nozzle', 'allow', **base, nozzle_diameter_mm=.4, nozzle_material='hardened_steel')
        self.check('product_nozzle', 'allow', **base, nozzle_diameter_mm=.6, nozzle_material='hardened_steel')
        self.check('product_nozzle', 'requires_verification', **base, nozzle_diameter_mm=.8, nozzle_material='hardened_steel')
        self.check('product_nozzle', 'blocked', material_id='bambu_tpu_for_ams', product_identity_verified=True,
                   nozzle_diameter_mm=.2, nozzle_material='unknown')

    def test_four_slot_quota_is_shared_and_ht_total_depends_on_model(self):
        counts = dict(ams=2, ams_2_pro=2, ams_ht=4, ams_lite=0)
        self.check('connection_quota', 'allow', model_id='P2S', counts=counts)
        self.check('connection_quota', 'blocked', model_id='X1C', counts=counts)
        self.check('connection_quota', 'blocked', model_id='H2D', counts={**counts, 'ams': 3})
        self.check('connection_quota', 'allow', model_id='H2D', counts={**counts, 'ams_ht': 8})
        self.check('connection_quota', 'blocked', model_id='H2D', counts={**counts, 'ams_ht': 9})

    def test_a2l_lite_mix_differs_from_a1_and_unmapped_models_remain_unknown(self):
        counts = dict(ams=4, ams_2_pro=0, ams_ht=0, ams_lite=1)
        self.check('connection_quota', 'allow', model_id='A2L', counts=counts)
        self.check('connection_quota', 'blocked', model_id='A1', counts=counts)
        self.check('connection_quota', 'requires_verification', model_id='H3C', counts=counts)
        self.check('connection_quota', 'requires_verification', model_id='H2D', counts={'ams_3h': 1})
        self.check('connection_quota', 'requires_verification', model_id='H2D', counts={**counts, 'ams': True})

    def test_firmware_boundary_and_accessories_are_not_implied_by_capacity(self):
        base = dict(model_id='A1', ams_type='ams_2_pro', accessories_verified=True, firmware_support_verified=True)
        self.check('configuration', 'blocked', **base, firmware_version='01.06.99.99')
        self.check('configuration', 'allow', **base, firmware_version='01.07.00.00')
        self.check('configuration', 'requires_verification', **base, firmware_version=None)
        self.check('configuration', 'requires_verification', **{**base, 'accessories_verified': None}, firmware_version='01.07.00.00')
        self.check('configuration', 'blocked', **{**base, 'accessories_verified': False}, firmware_version='01.07.00.00')

    def test_pre_sliced_same_family_is_not_exact_compatibility(self):
        base = dict(installed_model_id='P1S', target_model_id='P1P', installed_nozzle_mm=.4, target_nozzle_mm=.4)
        self.check('artifact_match', 'blocked', **base)
        self.check('artifact_match', 'allow', **{**base, 'target_model_id': 'P1S'})
        self.check('artifact_match', 'blocked', **{**base, 'target_model_id': 'P1S', 'target_nozzle_mm': .6})
        self.check('artifact_match', 'requires_verification', **{**base, 'target_model_id': 'P1S', 'installed_nozzle_mm': None})
        self.check('artifact_match', 'requires_verification', **{**base, 'installed_model_id': 'H3C', 'target_model_id': 'H3C'})

    def test_dual_path_unknown_mapping_fts_and_same_path_cannot_pass(self):
        base = dict(model_id='H2D', uses_ams=True, uses_external=True, fts_present=False,
                    ams_presence_verified=True, ams_and_external_same_path=False,
                    selected_plate_mapping_verified=True, source_path=0, target_path=0)
        self.check('feed_route', 'allow', **base)
        self.check('feed_route', 'blocked', **{**base, 'ams_and_external_same_path': True})
        self.check('feed_route', 'blocked', **{**base, 'fts_present': True})
        self.check('feed_route', 'requires_verification', **{**base, 'source_path': None})
        self.check('feed_route', 'requires_verification', **{**base, 'selected_plate_mapping_verified': False})
        self.check('feed_route', 'blocked', **{**base, 'source_path': 1})
        self.check('feed_route', 'blocked', **{**base, 'model_id': 'P1S'})

    def test_mixed_lite_physical_four_slots_only_three_active(self):
        base = dict(model_id='A2L', uses_ams=True, uses_external=False, fts_present=False,
                    ams_presence_verified=True, regular_ams_present=True)
        self.check('feed_route', 'allow', **base, active_lite_slots=3)
        self.check('feed_route', 'blocked', **base, active_lite_slots=4)
        self.check('feed_route', 'requires_verification', **base, active_lite_slots=None)

    def test_fault_and_missing_observation_cannot_be_filled_by_capacity(self):
        base = dict(ams_type='ams_2_pro', slot_present=True, filament_present=True, slot_fault=False, slot_disabled=False)
        self.check('slot_readiness', 'allow', **base)
        self.check('slot_readiness', 'blocked', **{**base, 'slot_fault': True})
        self.check('slot_readiness', 'blocked', **{**base, 'filament_present': False})
        self.check('slot_readiness', 'requires_verification', **{**base, 'filament_present': None})
        self.check('slot_readiness', 'requires_verification', **{**base, 'ams_type': 'ams_3h'})

    def test_idle_hms_ack_and_high_score_cannot_clear_repair_contract(self):
        base = dict(idle_telemetry=True, historical_score=100, hms_acknowledged=True,
                    validation_matches_current_configuration=True)
        for state in ('repairing', 'waiting_parts', 'awaiting_acceptance', 'restricted_trial'):
            self.check('maintenance', 'blocked', **base, maintenance_state=state)
        self.check('maintenance', 'allow', **base, maintenance_state='accepted')
        self.check('maintenance', 'requires_verification', **{**base, 'validation_matches_current_configuration': None}, maintenance_state='accepted')

    def spool(self, remaining='100', reserved='0', runs=1, grams=('50',)):
        return {'runs': runs, 'spools': [{'physical_spool_id': 'roll-A', 'remaining_g': remaining, 'reserved_g': reserved}],
                'tools': [{'physical_spool_id': 'roll-A', 'channel_alias': str(i), 'grams_per_run': value} for i, value in enumerate(grams)]}

    def test_shared_physical_spool_sums_tools_and_reservations_once(self):
        self.check('shared_spool_budget', 'allow', **self.spool())
        result = self.check('shared_spool_budget', 'blocked', **self.spool(grams=('50', '50')))
        self.assertEqual('100', result['physical_spool_audit']['roll-A']['total_demand_g'])
        self.check('shared_spool_budget', 'blocked', **self.spool(reserved='50'))
        alias = self.spool(grams=('50', '50'))
        alias['spools'].append(dict(alias['spools'][0]))
        self.check('shared_spool_budget', 'blocked', **alias)
        alias['spools'][1]['remaining_g'] = '101'
        self.check('shared_spool_budget', 'requires_verification', **alias)

    def test_30g_rule_is_strict_at_each_run_and_invalid_balance_is_not_clamped(self):
        self.check('shared_spool_budget', 'blocked', **self.spool(remaining='30', grams=('1',)))
        self.check('shared_spool_budget', 'allow', **self.spool(remaining='30.001', grams=('1',)))
        self.check('shared_spool_budget', 'blocked', **self.spool(remaining='50', runs=2, grams=('20',)))
        self.check('shared_spool_budget', 'allow', **self.spool(remaining='50.001', runs=2, grams=('20',)))
        self.check('shared_spool_budget', 'requires_verification', **self.spool(remaining='1000.01'))
        self.check('shared_spool_budget', 'requires_verification', **self.spool(remaining=None))
        self.check('shared_spool_budget', 'requires_verification', **self.spool(reserved='101'))

    def test_bundle_reports_actual_coverage_without_training_or_dispatch_claims(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'first'
            manifest = generate(output)
            result = validate_bundle(output)
            self.assertGreater(result['records'], 20000)
            self.assertEqual(9, len(manifest['coverage_by_layer']))
            self.assertEqual(manifest['records'], manifest['unique_inputs'])
            self.assertEqual({'allow', 'blocked', 'requires_verification'}, set(manifest['labels']))
            self.assertFalse(manifest['training_performed'])
            self.assertFalse(manifest['production_dispatch_authorized'])
            self.assertIn('ams_3h', manifest['coverage_by_dimension']['ams_type'])
            self.assertIn('H3C', manifest['coverage_by_dimension']['model_id'])
            with self.assertRaises(FileExistsError):
                generate(output)
            second = generate(Path(temporary) / 'second')
            self.assertEqual(manifest['records_sha256'], second['records_sha256'])
            records = output / manifest['records_file']
            with records.open('ab') as handle:
                handle.write(b'{}\n')
            with self.assertRaises(ValueError):
                validate_bundle(output)


if __name__ == '__main__':
    unittest.main()
