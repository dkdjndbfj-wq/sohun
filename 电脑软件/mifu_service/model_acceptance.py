"""Evidence required before an experimental checkpoint can be called ready.

Thresholds apply to advisory selection, never authorize printer execution.
They are deliberately separate from whether an optimizer finished running.
"""
from __future__ import annotations

import math
import hashlib
from pathlib import Path
import re
from runtime_profile import validate_runtime_profile

ACCEPTANCE_SCHEMA = 'mifu-advisory-acceptance-v2'


def checkpoint_artifact_hashes(checkpoint: Path) -> dict:
    """Bind tokenizer contents/inventory and both model configuration files."""
    paths = [checkpoint / 'rl_agent_config.json', checkpoint / 'encoder/config.json']
    tokenizer = checkpoint / 'tokenizer'
    if not (tokenizer / 'tokenizer.json').is_file():
        raise ValueError('Missing tokenizer integrity evidence')
    paths += sorted(path for path in tokenizer.rglob('*') if path.is_file())
    result = {}
    for path in paths:
        if not path.is_file():
            raise ValueError('Missing checkpoint configuration integrity evidence')
        digest = hashlib.sha256()
        with path.open('rb') as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                digest.update(chunk)
        result[path.relative_to(checkpoint).as_posix()] = digest.hexdigest()
    return result


def validate_acceptance(report: dict, *, weights_sha256: str, input_contract: str,
                        artifact_sha256: dict):
    if not isinstance(report, dict) or report.get('schema') != ACCEPTANCE_SCHEMA:
        raise ValueError('A runtime-bound v2 model acceptance report is required; previous reports need reevaluation')
    validate_runtime_profile(report.get('runtimeProfile'))
    if report.get('weightsSha256') != weights_sha256 or report.get('inputContract') != input_contract:
        raise ValueError('Acceptance evidence belongs to a different checkpoint or input contract')
    if input_contract == 'mifu-decision-v4' and report.get('supportedObjectives') != ['earliest_known_finish']:
        raise ValueError('The v4 acceptance must explicitly cover the supported earliest-finish objective')
    if (not isinstance(artifact_sha256, dict) or not artifact_sha256
            or any(not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value)
                   for value in artifact_sha256.values())
            or report.get('artifactsSha256') != artifact_sha256):
        raise ValueError('Acceptance configuration/tokenizer integrity evidence does not match')
    overlap = report.get('episodeOverlapCount')
    if report.get('heldOutUsedForTuning') is not False or type(overlap) is not int or overlap != 0:
        raise ValueError('Acceptance requires an untouched, disjoint held-out split')
    if report.get('evaluationSource') != 'reviewed_operational_records':
        raise ValueError('Synthetic validation does not establish operational quality')
    if report.get('automaticExecutionAuthorized') is not False:
        raise ValueError('Acceptance must remain advisory only')
    buckets = report.get('candidateBuckets')
    if not isinstance(buckets, dict) or not buckets or set(buckets) - {'2', '4', '8', '16'}:
        raise ValueError('Declare the supported candidate-count buckets')
    for key, metrics in buckets.items():
        if not isinstance(metrics, dict):
            raise ValueError('Invalid candidate bucket')
        count = metrics.get('independentEpisodes')
        if isinstance(count, bool) or not isinstance(count, int) or count < 100:
            raise ValueError('Each supported bucket needs at least 100 independent episodes')
        for name, minimum, maximum in (
            ('accuracy', 0.95, 1.0),
            ('optionPermutationConsistency', 0.99, 1.0),
            ('physicalRenameConsistency', 0.99, 1.0),
            ('meanRegretSeconds', 0.0, 30.0),
            ('maxRegretSeconds', 0.0, 300.0),
        ):
            value = metrics.get(name)
            if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or not minimum <= value <= maximum:
                raise ValueError(f'Acceptance threshold failed: bucket {key}, {name}')
    checks = report.get('checks')
    if not isinstance(checks, dict):
        raise ValueError('Acceptance checks must be an object')
    for scope in ('geometry', 'unknown_hardware', 'stale_telemetry', 'token_preservation'):
        evidence = checks.get(scope, {})
        if not isinstance(evidence, dict):
            raise ValueError('Invalid acceptance check: ' + scope)
        total, failures = evidence.get('cases'), evidence.get('failures')
        if type(total) is not int or total < 1 or type(failures) is not int or failures != 0:
            raise ValueError('Missing or failed acceptance checks: ' + scope)
    return report
