"""Offline experimental pairwise numeric adapter; never a live service or ready flag.

Only known integer evidence enters the features. Labels, training, checkpoint files,
and evaluation belong to the caller. The MLP does not contain an oracle, fixed
preference direction, monotonicity constraint, or answer correction. Antisymmetry
is a structural prior, not a guarantee of correct or transitive comparisons.

Importing this module (and validating requests) does not import torch. Accessing
NumericPairwiseRanker or a tensor operation imports torch lazily. Save the returned
artifact_config and ordinary state_dict in the independent experiment runner;
load_ranker accepts an already safely loaded state_dict and performs no file I/O.
"""
from __future__ import annotations

from collections.abc import Mapping
import math

from decision_contract import MAX_CANDIDATES, MAX_TIME_SECONDS, SCHEMA, normalize_request

ARTIFACT_SCHEMA = 'mifu-numeric-pairwise-artifact-v1'
FEATURE_SCHEMA = 'mifu-numeric-pairs-v1'
FEATURE_NAMES = ('signed_log1p_finish_difference_seconds',
                 'signed_log1p_setup_difference_seconds')
_RANKER_TYPE = None


def prepare_numeric_request(request: dict, *, now_epoch_s: float) -> dict:
    """Use the existing evidence/admission checks, without asserting token/model readiness.

    The numeric adapter only supports known finish, with preparation as a tie
    criterion. Both synthetic and live declarations keep their original source;
    passing validation does not authenticate real-world observations.
    """
    prepared = normalize_request(request, now_epoch_s=now_epoch_s)
    if prepared['state']['objective'] != 'earliest_known_finish':
        raise ValueError('The numeric experiment only supports earliest_known_finish')
    return prepared


def _integer(value, field: str, maximum: int) -> int:
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError(field + ' must be a known bounded Python integer')
    return value


def _signed_log1p(value: int) -> float:
    # Subtraction happens before this function, on Python integers. Casting large
    # absolute seconds to BF16/FP32 first would irreversibly lose close differences.
    return math.copysign(math.log1p(abs(value)), value) if value else 0.0


def pair_features(prepared_or_candidates, *, device='cpu'):
    """Return float64 [K,K,2] differences; no sorting, ranking, IDs or labels.

    Prefer prepare_numeric_request(request) as input. A list of its diagnostics
    candidates is also accepted for runners that retain the validated envelope
    separately. A bare list performs numeric validation only, not admission or
    freshness validation, and must not be treated as authenticated live input.
    """
    if isinstance(prepared_or_candidates, dict):
        prepared = prepared_or_candidates
        state = prepared.get('state', {})
        if state.get('schema') != SCHEMA or state.get('objective') != 'earliest_known_finish':
            raise ValueError('Expected a normalized earliest_known_finish request')
        candidates = prepared.get('diagnostics', {}).get('candidates')
    else:
        candidates = prepared_or_candidates
    if not isinstance(candidates, (list, tuple)) or not 2 <= len(candidates) <= MAX_CANDIDATES:
        raise ValueError('Numeric ranking requires 2 through 16 candidates')
    values = []
    for candidate in candidates:
        if not isinstance(candidate, dict):
            raise ValueError('Expected normalized diagnostic candidate objects')
        finish = _integer(candidate.get('finish_s'), 'finish_s', 3 * MAX_TIME_SECONDS)
        setup = _integer(candidate.get('setup_s'), 'setup_s', MAX_TIME_SECONDS)
        if finish <= setup:
            raise ValueError('Known finish must include a positive run duration')
        values.append((finish, setup))
    features = [[[_signed_log1p(left[0] - right[0]),
                  _signed_log1p(left[1] - right[1])]
                 for right in values] for left in values]
    import torch
    return torch.tensor(features, dtype=torch.float64, device=device)


def _check_pair_tensor(tensor, *, features: bool):
    import torch
    minimum_dimensions = 3 if features else 2
    if not isinstance(tensor, torch.Tensor) or tensor.ndim < minimum_dimensions:
        raise ValueError('Expected a pairwise tensor with optional batch dimensions')
    if features and tensor.shape[-1] != len(FEATURE_NAMES):
        raise ValueError('Expected exactly two signed-log difference features')
    matrix = tensor[..., 0] if features else tensor
    if not 2 <= matrix.shape[-1] <= MAX_CANDIDATES or matrix.shape[-2] != matrix.shape[-1]:
        raise ValueError('Expected a square pair matrix for 2 through 16 candidates')
    if tensor.dtype != torch.float64:
        raise ValueError('Numeric tensors must remain float64; lost precision cannot be restored')
    if tensor.device.type not in ('cpu', 'cuda') or not bool(torch.isfinite(tensor).all()):
        raise ValueError('Expected finite CPU/CUDA numeric evidence')
    transpose = tensor.transpose(-3, -2) if features else tensor.transpose(-2, -1)
    if not torch.allclose(tensor, -transpose, rtol=0, atol=1e-12):
        raise ValueError('Pairwise evidence/logits must be antisymmetric with zero self comparison')


def candidate_scores(pair_logits):
    """Sum learned pairwise win probabilities, excluding self; no oracle correction.

    Returns [...,K]. The runner may use argmax on these scores. Nontransitive
    preferences and score ties are possible and must be reported, not corrected
    using finish/setup. A completely identical candidate is not identifiable from
    evidence alone; evaluation must treat equally optimal candidates accordingly.
    """
    import torch
    _check_pair_tensor(pair_logits, features=False)
    with torch.autocast(device_type=pair_logits.device.type, enabled=False):
        mask = ~torch.eye(pair_logits.shape[-1], dtype=torch.bool, device=pair_logits.device)
        return torch.sigmoid(pair_logits).masked_fill(~mask, 0.0).sum(dim=-1)


def _ranker_type():
    global _RANKER_TYPE
    if _RANKER_TYPE is not None:
        return _RANKER_TYPE
    import torch
    from torch import nn

    class NumericPairwiseRanker(nn.Module):
        """Learn h(d)-h(-d); positive pair logit means row candidate beats column."""

        def __init__(self, hidden_sizes=(32, 16), *, hybrid=False, activation='tanh'):
            super().__init__()
            if (not isinstance(hidden_sizes, (tuple, list)) or len(hidden_sizes) != 2
                    or any(type(size) is not int or not 1 <= size <= 256 for size in hidden_sizes)):
                raise ValueError('Specify two hidden-layer widths between 1 and 256')
            if type(hybrid) is not bool or activation not in ('tanh', 'relu'):
                raise ValueError('Invalid hybrid mode or activation')
            self.hidden_sizes = tuple(hidden_sizes)
            self.hybrid = hybrid
            self.activation = activation
            nonlinear = nn.Tanh if activation == 'tanh' else nn.ReLU
            self.network = nn.Sequential(
                nn.Linear(2, self.hidden_sizes[0], dtype=torch.float64), nonlinear(),
                nn.Linear(self.hidden_sizes[0], self.hidden_sizes[1], dtype=torch.float64), nonlinear(),
                # The final bias would cancel in h(d)-h(-d), so do not train it.
                nn.Linear(self.hidden_sizes[1], 1, bias=False, dtype=torch.float64))
            if hybrid:
                # Zero is an unconstrained starting point, not a positive/negative
                # direction constraint. A zero learned value implies no Laya gain.
                self.alpha = nn.Parameter(torch.zeros((), dtype=torch.float64))
            else:
                self.register_parameter('alpha', None)

        def pair_logits(self, features, laya_delta=None):
            """Score independent pairs [...,2] -> [...], for sampled-pair training.

            A positive output means the first candidate wins. The caller provides
            labels separately, and in hybrid mode a matching signed Laya score
            difference. Matrix symmetry is not required for this independent-pair
            interface; evaluating -features/-laya_delta reverses the logit.
            """
            if (not isinstance(features, torch.Tensor) or features.ndim < 1
                    or features.shape[-1] != 2 or features.dtype != torch.float64
                    or features.device.type not in ('cpu', 'cuda')
                    or not bool(torch.isfinite(features).all())):
                raise ValueError('Independent pair features must be finite float64 [...,2]')
            if any(parameter.dtype != torch.float64 or parameter.device != features.device
                   for parameter in self.parameters()):
                raise ValueError('Ranker parameters and numeric features must share float64 and device')
            if not self.hybrid and laya_delta is not None:
                raise ValueError('numeric-only mode cannot consume Laya logits')
            if self.hybrid:
                if (not isinstance(laya_delta, torch.Tensor) or laya_delta.shape != features.shape[:-1]
                        or not laya_delta.is_floating_point() or laya_delta.device != features.device
                        or not bool(torch.isfinite(laya_delta).all())):
                    raise ValueError('hybrid mode needs finite matching pairwise Laya differences')
            with torch.autocast(device_type=features.device.type, enabled=False):
                logits = (self.network(features) - self.network(-features)).squeeze(-1)
                if self.hybrid:
                    logits = logits + self.alpha * laya_delta.to(dtype=torch.float64)
            if not bool(torch.isfinite(logits).all()):
                raise ValueError('Numeric ranker produced nonfinite pair logits')
            return logits

        def forward(self, features, laya_logits=None):
            _check_pair_tensor(features, features=True)
            if not self.hybrid and laya_logits is not None:
                raise ValueError('numeric-only mode cannot consume Laya logits')
            delta = None
            if self.hybrid:
                expected_shape = features.shape[:-3] + (features.shape[-2],)
                if (not isinstance(laya_logits, torch.Tensor) or laya_logits.shape != expected_shape
                        or not laya_logits.is_floating_point() or laya_logits.device != features.device
                        or not bool(torch.isfinite(laya_logits).all())):
                    raise ValueError('hybrid mode needs finite matching candidate Laya logits')
                # Convert BEFORE differencing; this does not claim to undo any
                # precision already lost during the independent Laya forward.
                with torch.autocast(device_type=features.device.type, enabled=False):
                    scores = laya_logits.to(dtype=torch.float64)
                    delta = scores.unsqueeze(-1) - scores.unsqueeze(-2)
            logits = self.pair_logits(features, delta)
            with torch.autocast(device_type=features.device.type, enabled=False):
                # Make floating-point antisymmetry exact even if a backend uses
                # different reduction paths for opposite rows. This inserts no
                # preference direction and reads no target.
                logits = (logits - logits.transpose(-2, -1)) * 0.5
            return logits

        def artifact_config(self):
            """Architecture only: neither training provenance nor quality evidence."""
            return {
                'schema': ARTIFACT_SCHEMA,
                'architecture': 'shared_antisymmetric_pairwise_mlp',
                'inputContract': SCHEMA,
                'featureSchema': FEATURE_SCHEMA,
                'featureNames': list(FEATURE_NAMES),
                'hiddenSizes': list(self.hidden_sizes),
                'activation': self.activation,
                'hybrid': self.hybrid,
                'dtype': 'float64',
                'objective': 'earliest_known_finish_then_preparation',
                'aggregation': 'sum_sigmoid_pair_wins_excluding_self',
                'source': 'offline_experimental_adapter',
                'deployable': False,
                'automaticExecutionAuthorized': False,
            }

    NumericPairwiseRanker.__module__ = __name__
    NumericPairwiseRanker.__qualname__ = 'NumericPairwiseRanker'
    _RANKER_TYPE = NumericPairwiseRanker
    return _RANKER_TYPE


def __getattr__(name):
    if name == 'NumericPairwiseRanker':
        return _ranker_type()
    raise AttributeError(name)


def load_ranker(config: dict, state_dict: Mapping, *, device='cpu'):
    """Strict, file-free reconstruction. Caller safely loads and hashes artifacts.

    Reject ready/deployment claims, altered feature definitions, dtype casts,
    missing/extra weights, nonfinite weights, and wrong tensor shapes. This does
    not authenticate provenance or demonstrate model quality.
    """
    import torch
    if not isinstance(config, dict) or not isinstance(state_dict, Mapping):
        raise ValueError('Expected experiment architecture and a state dictionary')
    ranker = _ranker_type()(hidden_sizes=config.get('hiddenSizes'),
                            hybrid=config.get('hybrid'), activation=config.get('activation'))
    if config != ranker.artifact_config():
        raise ValueError('Artifact architecture/feature schema must match exactly; no ready claims')
    expected = ranker.state_dict()
    if set(state_dict) != set(expected):
        raise ValueError('Artifact weight names do not match the architecture')
    for name, value in state_dict.items():
        if (not isinstance(value, torch.Tensor) or value.shape != expected[name].shape
                or value.dtype != torch.float64 or value.device.type not in ('cpu', 'cuda')
                or not bool(torch.isfinite(value).all())):
            raise ValueError('Invalid float64 artifact weight: ' + name)
    ranker.load_state_dict(state_dict, strict=True)
    return ranker.to(device=device)


__all__ = ['ARTIFACT_SCHEMA', 'FEATURE_SCHEMA', 'FEATURE_NAMES', 'NumericPairwiseRanker',
           'prepare_numeric_request', 'pair_features', 'candidate_scores', 'load_ranker']
