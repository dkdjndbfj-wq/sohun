"""Mifu Core: a standalone learned numeric model, not a renamed base model.

Only PyTorch and the two bundled Mifu modules are required for native inference.
Historical experiment provenance is retained under technical/, not executed.
Packages are advisory experiments: exporting one never grants production readiness.
Hashes detect changes; publisher authenticity additionally needs a trusted externally
pinned manifest hash. No tokenizer, language model, network or GPU is loaded here.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import sys
import time

# An exported package is immutable. Its normal CLI must not add import caches
# that evade the file inventory or make a second load fail.
sys.dont_write_bytecode = True

PACKAGE_SCHEMA = 'mifu-core-package-v1'
PROVENANCE_SCHEMA = 'mifu-core-provenance-v1'
BRAND = 'Mifu Core'
SOURCE = 'synthetic_pipeline_only'
SOURCE_FILES = ('plan.json', 'prepared.json', 'cache_report.json', 'training_report.json')
RUNTIME_FILES = ('mifu_native.py', 'mifu_numeric_ranker.py', 'decision_contract.py', 'requirements-native.txt')
UPSTREAM_PIPELINE = {'train_numeric_adapter.py', 'mifu_numeric_ranker.py', 'decision_contract.py',
                     'audit_token_budget.py', 'evaluate_compact_model.py', 'diagnose_learning.py'}
TECHNICAL_FILES = tuple('technical/' + name for name in ('selection_lock.json',) + SOURCE_FILES)
PACKAGE_FILES = {'model.pt', 'model_config.json', 'provenance.json', *RUNTIME_FILES, *TECHNICAL_FILES}
IDENTITY = {'schema': PACKAGE_SCHEMA, 'brand': BRAND, 'architecture': 'shared_antisymmetric_pairwise_mlp',
            'inputContract': 'mifu-decision-v4', 'featureSchema': 'mifu-numeric-pairs-v1',
            'trainingSource': SOURCE, 'operationalTrainingRecords': 0,
            'baseCheckpointUsed': False, 'runtimeDependencies': ['torch'],
            'requiresTokenizer': False, 'requiresTransformerRuntime': False,
            'device': 'cpu', 'dtype': 'float64', 'advisoryOnly': True,
            'acceptedForProduction': False, 'automaticExecutionAuthorized': False,
            'scoresMeaning': 'sum of learned pairwise preference scores; not print success probability or calibrated confidence'}


def _sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def _digest(value):
    if not isinstance(value, str) or not re.fullmatch('[0-9a-f]{64}', value):
        raise ValueError('Expected a SHA-256 digest')
    return value


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def _read(path, maximum=4 * 1024 * 1024):
    path = Path(path)
    if not path.is_file() or path.stat().st_size > maximum:
        raise ValueError('Missing or oversized JSON artifact: ' + path.name)
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=_pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError('Nonfinite JSON: ' + value)))


def _write(path, value):
    with Path(path).open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write('\n')


def _path(root, name):
    base = Path(root).resolve()
    if not isinstance(name, str) or '\\' in name or Path(name).is_absolute() or '..' in Path(name).parts:
        raise ValueError('Invalid relative artifact path')
    target = (base / name).resolve()
    if target == base or not target.is_relative_to(base):
        raise ValueError('Artifact escapes the package directory')
    return target


def _verify(root, specs, *, expected_names=None):
    if not isinstance(specs, dict) or not specs or (expected_names is not None and set(specs) != set(expected_names)):
        raise ValueError('Unexpected artifact inventory')
    for name, digest in specs.items():
        if _sha(_path(root, name)) != _digest(digest):
            raise ValueError('Artifact hash mismatch: ' + name)


def _source_flag(value):
    if not isinstance(value, dict) or value.get('source') != SOURCE or value.get('deployable') is not False:
        raise ValueError('Expected explicitly synthetic, non-deployable provenance')


def _positive_integer(value):
    if type(value) is not int or value <= 0:
        raise ValueError('Expected a positive integer training count')
    return value


def _tensor_hashes(state):
    """Match the original selection audit without adding a NumPy dependency."""
    import torch
    return {name: hashlib.sha256(str((tuple(value.shape), str(value.dtype))).encode()
                                + bytes(value.detach().cpu().contiguous().view(torch.uint8).flatten().tolist())).hexdigest()
            for name, value in state.items()}


def _load_head(config, weights):
    import torch
    import mifu_numeric_ranker as numeric
    if not isinstance(config, dict) or config.get('hybrid') is not False:
        raise ValueError('Mifu Core only accepts its native numeric head; hybrid heads require another runtime')
    if config.get('hiddenSizes') != [32, 16] or config.get('activation') != 'tanh':
        raise ValueError('Unsupported Mifu Core v1 architecture')
    weights = Path(weights)
    if not weights.is_file() or not 0 < weights.stat().st_size <= 1024 * 1024:
        raise ValueError('Expected the small native state dictionary, not a base model checkpoint')
    state = torch.load(weights, map_location='cpu', weights_only=True)
    model = numeric.load_ranker(config, state, device='cpu').eval()
    if json.dumps(config, sort_keys=True) != json.dumps(model.artifact_config(), sort_keys=True):
        raise ValueError('Native configuration requires exact field types and values')
    model.requires_grad_(False)
    return model


def _validate_source(root, *, bundled=False):
    """Read only metadata and numeric weights; never a cache or old holdout."""
    root = Path(root).resolve()
    metadata = root / 'technical' if bundled else root
    lock = _read(metadata / 'selection_lock.json')
    _source_flag(lock)
    if lock.get('heldoutNotGenerated') is not True:
        raise ValueError('Expected weights selected before holdout generation')
    _verify(metadata, lock.get('files'), expected_names=SOURCE_FILES)
    pipeline = lock.get('pipelineSha256')
    if not isinstance(pipeline, dict) or set(pipeline) != UPSTREAM_PIPELINE:
        raise ValueError('Missing upstream pipeline provenance')
    for digest in pipeline.values():
        _digest(digest)
    specs = lock.get('adapters', {}).get('numeric_only')
    if not isinstance(specs, dict) or set(specs) != {'numeric_only.pt', 'numeric_only.json'}:
        raise ValueError('Missing selected numeric head hashes')
    weight_path = root / 'model.pt' if bundled else root / 'adapters' / 'numeric_only.pt'
    config_path = root / 'model_config.json' if bundled else root / 'adapters' / 'numeric_only.json'
    if _sha(weight_path) != _digest(specs['numeric_only.pt']) or _sha(config_path) != _digest(specs['numeric_only.json']):
        raise ValueError('Selected native head/config differs from its source lock')
    documents = {name: _read(metadata / name) for name in SOURCE_FILES}
    for document in documents.values():
        _source_flag(document)
    plan, prepared, cached, training = (documents[name] for name in SOURCE_FILES)
    if plan.get('schema') != 'mifu-numeric-adapter-experiment-v1' or not isinstance(plan.get('experimentId'), str) or not plan['experimentId']:
        raise ValueError('Unsupported source experiment schema')
    if prepared.get('operationalRecords') != 0 or type(prepared.get('operationalRecords')) is not int:
        raise ValueError('Native source must not relabel synthetic examples as operational records')
    if (training.get('precision') != 'float64' or training.get('holdoutRead') is not False
            or training.get('planSha256') != lock['files']['plan.json']
            or training.get('cacheReportSha256') != lock['files']['cache_report.json']
            or cached.get('preparedSha256') != lock['files']['prepared.json']):
        raise ValueError('Source selection metadata is inconsistent')
    if any(document.get('pipelineSha256') != pipeline for document in (prepared, cached, training)):
        raise ValueError('Source pipeline metadata is inconsistent')
    head = training.get('models', {}).get('numeric_only', {})
    if head.get('files') != specs or head.get('selectedAlpha') is not None:
        raise ValueError('Native head source does not match the selected numeric-only model')
    updates = _positive_integer(head.get('optimizerUpdates'))
    selected_update = _positive_integer(head.get('bestValidationUpdate'))
    _positive_integer(head.get('pairDraws'))
    if selected_update > updates:
        raise ValueError('Invalid validation-selected training step')
    model = _load_head(_read(config_path), weight_path)
    selected = _tensor_hashes(model.state_dict())
    initial = head.get('initialTensorSha256')
    if selected != head.get('selectedTensorSha256') or not isinstance(initial, dict) or set(initial) != set(selected):
        raise ValueError('Selected weights do not match their actual training audit')
    for digest in initial.values():
        _digest(digest)
    changed = {name for name in selected if selected[name] != initial[name]}
    if not changed or changed != set(head.get('changedSelectedTensors', [])):
        raise ValueError('Missing or inconsistent evidence of learned native weights')
    return model, lock, documents


def _provenance(lock, documents, lock_hash):
    plan, training = documents['plan.json'], documents['training_report.json']
    head = training['models']['numeric_only']
    return {'schema': PROVENANCE_SCHEMA, 'brand': BRAND, 'trainingSource': SOURCE,
            'operationalTrainingRecords': 0, 'baseCheckpointUsed': False,
            'weightsOrigin': 'randomly initialized native pairwise MLP trained on synthetic numeric labels',
            'sourceExperimentId': plan['experimentId'], 'selectionLockSha256': lock_hash,
            'selectedNumericHeadSha256': lock['adapters']['numeric_only'],
            'optimizerUpdates': head['optimizerUpdates'], 'selectedValidationUpdate': head['bestValidationUpdate'],
            'nativeInferenceDependencies': ['torch'], 'acceptedForProduction': False,
            'upstreamBenchmark': {'name': 'Laya', 'baseCheckpointSha256': _digest(plan.get('baseWeightsSha256')),
                'role': 'historical comparator and separate hybrid experiment; not Mifu Core initialization, input, or runtime',
                'evidenceLocation': 'technical/', 'qualityClaim': 'no production accuracy or real print success claim'},
            'provenanceBoundary': 'technical metadata preserves the historical experiment; caches, tokenizer and base weights are not bundled'}


def export_package(experiment, out):
    source, destination = Path(experiment).resolve(), Path(out).resolve()
    if destination.exists():
        raise FileExistsError(destination)
    if destination.is_relative_to(source):
        raise ValueError('Export to a new directory outside the frozen experiment')
    _, lock, documents = _validate_source(source)
    service = Path(__file__).resolve().parent
    # Reuse the exact shared numeric representation and input contract associated
    # with the selection; do not import the upstream experiment runner or SDK.
    for name in ('mifu_numeric_ranker.py', 'decision_contract.py'):
        if _sha(service / name) != lock['pipelineSha256'][name]:
            raise ValueError('The shared native source no longer matches the selected weights')
    selection_hash = _sha(source / 'selection_lock.json')
    provenance = _provenance(lock, documents, selection_hash)
    for name in RUNTIME_FILES:
        if not (service / name).is_file():
            raise ValueError('Missing native runtime file: ' + name)
    destination.mkdir(parents=True, exist_ok=False)
    (destination / 'technical').mkdir()
    try:
        # The source weight and architecture bytes are preserved, not retrained
        # or converted to another precision during export.
        copies = {'model.pt': source / 'adapters' / 'numeric_only.pt',
                  'model_config.json': source / 'adapters' / 'numeric_only.json',
                  **{name: service / name for name in RUNTIME_FILES},
                  **{'technical/' + name: source / name for name in ('selection_lock.json',) + SOURCE_FILES}}
        for name, path in copies.items():
            with Path(path).open('rb') as incoming, _path(destination, name).open('xb') as outgoing:
                shutil.copyfileobj(incoming, outgoing)
        _write(destination / 'provenance.json', provenance)
        if _sha(source / 'selection_lock.json') != selection_hash:
            raise ValueError('Selection lock changed during export')
        _validate_source(destination, bundled=True)
        manifest = {**IDENTITY, 'files': {name: _sha(destination / name) for name in sorted(PACKAGE_FILES)}}
        _write(destination / 'manifest.json', manifest)
        load_package(destination)
        return manifest
    except Exception as exc:
        _write(destination / 'export_failed.json', {'completed': False, 'exception': type(exc).__name__,
               'message': str(exc), 'partialArtifactsPreserved': True, 'acceptedForProduction': False})
        raise


class NativeCore:
    def __init__(self, package, model, manifest, manifest_sha256):
        self.package, self._model = Path(package), model
        self.manifest, self.manifest_sha256 = manifest, manifest_sha256
        self._tensor_sha256 = _tensor_hashes(model.state_dict())

    def _verify_frozen(self):
        if _sha(self.package / 'manifest.json') != self.manifest_sha256:
            raise ValueError('Package manifest changed after loading')
        actual = {p.relative_to(self.package).as_posix() for p in self.package.rglob('*') if p.is_file()}
        if actual != PACKAGE_FILES | {'manifest.json'}:
            raise ValueError('Package file inventory changed after loading')
        _verify(self.package, self.manifest['files'], expected_names=PACKAGE_FILES)
        if _tensor_hashes(self._model.state_dict()) != self._tensor_sha256:
            raise ValueError('Native model weights changed in memory')

    def predict(self, request, *, now_epoch_s=None):
        import torch
        import mifu_numeric_ranker as numeric
        self._verify_frozen()
        now = time.time() if now_epoch_s is None else now_epoch_s
        if isinstance(now, bool) or not isinstance(now, (int, float)) or not math.isfinite(now):
            raise ValueError('Expected a finite observation time')
        prepared = numeric.prepare_numeric_request(request, now_epoch_s=now)
        with torch.no_grad(), torch.autocast(device_type='cpu', enabled=False):
            values = numeric.pair_features(prepared, device='cpu')
            scores = numeric.candidate_scores(self._model(values))
        if scores.device.type != 'cpu' or scores.dtype != torch.float64 or not bool(torch.isfinite(scores).all()):
            raise ValueError('Mifu Core requires finite CPU float64 scores')
        identifiers = list(prepared['mapping'].values())
        choice = identifiers[int(scores.argmax())]
        self._verify_frozen()
        return {'schema': 'mifu-core-prediction-v1', 'brand': BRAND, 'requestId': request['requestId'],
                'choice': choice, 'scores': {name: float(scores[i]) for i, name in enumerate(identifiers)},
                'scoresMeaning': IDENTITY['scoresMeaning'], 'source': prepared['diagnostics']['source'],
                'device': 'cpu', 'dtype': 'float64', 'baseCheckpointUsed': False,
                'advisoryOnly': True, 'acceptedForProduction': False, 'automaticExecutionAuthorized': False,
                'packageManifestSha256': self.manifest_sha256}


def load_package(package, *, expected_manifest_sha256=None):
    root = Path(package).resolve()
    digest = _sha(root / 'manifest.json')
    if expected_manifest_sha256 is not None and digest != _digest(expected_manifest_sha256):
        raise ValueError('Package does not match the externally pinned manifest hash')
    manifest = _read(root / 'manifest.json')
    if not isinstance(manifest, dict) or set(manifest) != set(IDENTITY) | {'files'}:
        raise ValueError('Unsupported native package schema')
    # Equality alone would accept bool==0/1; compare canonical JSON as well.
    header = {name: manifest[name] for name in IDENTITY}
    if json.dumps(header, sort_keys=True) != json.dumps(IDENTITY, sort_keys=True):
        raise ValueError('Native identity, source or advisory boundary was altered')
    actual_files = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file()}
    if actual_files != PACKAGE_FILES | {'manifest.json'}:
        raise ValueError('Unexpected/missing package files; no base models or caches are allowed')
    _verify(root, manifest['files'], expected_names=PACKAGE_FILES)
    for name in RUNTIME_FILES:
        if _sha(Path(__file__).resolve().parent / name) != manifest['files'][name]:
            raise ValueError('Running native sources differ from this package; run its bundled entry point')
    import decision_contract
    import mifu_numeric_ranker
    for module in (decision_contract, mifu_numeric_ranker):
        if _sha(module.__file__) != manifest['files'][Path(module.__file__).name]:
            raise ValueError('Imported native module differs from the frozen package')
    model, lock, documents = _validate_source(root, bundled=True)
    expected_provenance = _provenance(lock, documents, _sha(root / 'technical' / 'selection_lock.json'))
    if json.dumps(_read(root / 'provenance.json'), sort_keys=True) != json.dumps(expected_provenance, sort_keys=True):
        raise ValueError('Native model provenance was altered')
    return NativeCore(root, model, manifest, digest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    export = commands.add_parser('export')
    export.add_argument('--experiment', required=True, type=Path)
    export.add_argument('--out', required=True, type=Path)
    infer = commands.add_parser('infer')
    infer.add_argument('--package', required=True, type=Path)
    infer.add_argument('--request', '--input', dest='request_file', required=True, type=Path)
    infer.add_argument('--out', type=Path)
    infer.add_argument('--now-epoch', type=float)
    infer.add_argument('--expected-manifest-sha256')
    args = parser.parse_args()
    if args.command == 'export':
        export_package(args.experiment, args.out)
        print(json.dumps({'brand': BRAND, 'exported': True, 'out': str(args.out),
                          'manifestSha256': _sha(args.out / 'manifest.json'), 'acceptedForProduction': False}))
    else:
        if args.out is not None and args.out.exists():
            raise FileExistsError(args.out)
        core = load_package(args.package, expected_manifest_sha256=args.expected_manifest_sha256)
        result = core.predict(_read(args.request_file, maximum=65536), now_epoch_s=args.now_epoch)
        if args.out is not None:
            _write(args.out, result)
        print(json.dumps(result, ensure_ascii=False, allow_nan=False))


if __name__ == '__main__':
    main()
