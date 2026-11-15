import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from model_acceptance import ACCEPTANCE_SCHEMA, validate_acceptance
from runtime_profile import RUNTIME_SCHEMA


ARTIFACTS = {'rl_agent_config.json': 'b' * 64, 'encoder/config.json': 'c' * 64,
             'tokenizer/tokenizer.json': 'd' * 64}


def accepted_runtime(device='cpu', precision='float32'):
    """Explicit fixture policy only; this is not measured model acceptance."""
    return {'schema': RUNTIME_SCHEMA, 'deviceType': device, 'questionRows': 1,
            'computePrecision': precision, 'autocastEnabled': precision != 'float32',
            'parameterDtype': 'float32', 'backend': 'eager', 'fastEnabled': False,
            'compiled': False, 'referenceCompile': False, 'attentionImplementation': 'sdpa',
            'evaluationMode': True, 'cpuFallbackCount': 0, 'autocastFailureCount': 0}


def accepted_report(weights='a' * 64, contract='legacy_v1', artifacts=None, runtime=None):
    return {
        'schema': ACCEPTANCE_SCHEMA, 'weightsSha256': weights, 'inputContract': contract,
        'artifactsSha256': dict(ARTIFACTS if artifacts is None else artifacts),
        'runtimeProfile': accepted_runtime() if runtime is None else runtime,
        'heldOutUsedForTuning': False, 'episodeOverlapCount': 0,
        'evaluationSource': 'reviewed_operational_records',
        'automaticExecutionAuthorized': False,
        'candidateBuckets': {'2': {'independentEpisodes': 100, 'accuracy': 0.98,
                                 'optionPermutationConsistency': 1.0, 'physicalRenameConsistency': 1.0,
                                 'meanRegretSeconds': 1.0, 'maxRegretSeconds': 50.0}},
        'checks': {key: {'cases': 100, 'failures': 0} for key in
                   ('geometry', 'unknown_hardware', 'stale_telemetry', 'token_preservation')},
    }


class AcceptanceTests(unittest.TestCase):
    def test_success_only_for_declared_scope(self):
        report = accepted_report()
        self.assertEqual(validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS), report)
        self.assertNotIn('16', report['candidateBuckets'])

    def test_completed_but_chance_level_model_is_not_ready(self):
        report = accepted_report()
        report['candidateBuckets']['2']['accuracy'] = 0.4629
        with self.assertRaisesRegex(ValueError, 'accuracy'):
            validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)

    def test_counterfactual_and_unsafe_failures_cannot_hide_in_accuracy(self):
        for field in ('optionPermutationConsistency', 'physicalRenameConsistency'):
            report = accepted_report()
            report['candidateBuckets']['2'][field] = 0.5
            with self.assertRaises(ValueError):
                validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)
        for scope in accepted_report()['checks']:
            report = accepted_report()
            report['checks'][scope]['failures'] = 1
            with self.assertRaises(ValueError):
                validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)

    def test_mismatched_weights_and_input_contract_fail(self):
        for weights, contract in [('b' * 64, 'legacy_v1'), ('a' * 64, 'new_v2')]:
            with self.assertRaises(ValueError):
                validate_acceptance(accepted_report(), weights_sha256=weights, input_contract=contract, artifact_sha256=ARTIFACTS)

    def test_synthetic_or_tuned_holdout_is_not_operational_evidence(self):
        for key, value in [('evaluationSource', 'synthetic_pipeline_only'),
                           ('heldOutUsedForTuning', True), ('episodeOverlapCount', 1),
                           ('automaticExecutionAuthorized', True)]:
            report = accepted_report()
            report[key] = value
            with self.assertRaises(ValueError):
                validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)

    def test_malformed_nonfinite_and_small_samples_fail(self):
        for key, value in [('independentEpisodes', 99), ('independentEpisodes', True),
                           ('accuracy', float('nan')), ('accuracy', True),
                           ('maxRegretSeconds', float('inf'))]:
            report = copy.deepcopy(accepted_report())
            report['candidateBuckets']['2'][key] = value
            with self.assertRaises(ValueError):
                validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)

    def test_boolean_float_counts_and_malformed_check_objects_fail(self):
        for value in (False, 0.0):
            report = accepted_report()
            report['episodeOverlapCount'] = value
            with self.assertRaises(ValueError):
                validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)
            report = accepted_report()
            report['checks']['geometry']['failures'] = value
            with self.assertRaises(ValueError):
                validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)
        for value in ([], None):
            report = accepted_report()
            report['checks'] = value
            with self.assertRaises(ValueError):
                validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)

    def test_artifact_binding_rejects_changed_configuration(self):
        changed = dict(ARTIFACTS, **{'tokenizer/tokenizer.json': 'e' * 64})
        with self.assertRaisesRegex(ValueError, 'integrity'):
            validate_acceptance(accepted_report(), weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=changed)

    def test_missing_precision_and_previous_schema_require_new_acceptance(self):
        for mode in ('missing_profile', 'missing_precision', 'old_schema'):
            report = accepted_report()
            if mode == 'missing_profile':
                del report['runtimeProfile']
            elif mode == 'missing_precision':
                del report['runtimeProfile']['computePrecision']
            else:
                report['schema'] = 'mifu-advisory-acceptance-v1'
            with self.subTest(mode=mode), self.assertRaisesRegex(ValueError, 'runtime|Runtime'):
                validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)

    def test_invalid_precision_backends_and_fallback_counters_are_not_qualified(self):
        for key, value in (('computePrecision', 'bfloat16'), ('autocastEnabled', 0),
                           ('parameterDtype', 'bfloat16'), ('backend', 'compile'), ('compiled', True),
                           ('referenceCompile', 'auto'), ('fastEnabled', True), ('questionRows', True),
                           ('cpuFallbackCount', 1), ('cpuFallbackCount', False), ('autocastFailureCount', 1),
                           ('evaluationMode', False), ('attentionImplementation', None)):
            report = accepted_report()
            report['runtimeProfile'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_acceptance(report, weights_sha256='a' * 64, input_contract='legacy_v1', artifact_sha256=ARTIFACTS)


if __name__ == '__main__':
    unittest.main()
