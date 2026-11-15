"""Bind operational acceptance to the observed pinned Laya execution policy.

No torch import is needed to validate reports or inspect an agent's attributes.
The production loader pins Laya 0.4.31. These fields are read from its active
runtime and resident model, never inferred from checkpoint cfg.amp_dtype.
This is an execution-policy guard, not a claim about every operator's arithmetic.
Only the one-question CPU/CUDA eager path is supported by this service.
"""
from __future__ import annotations

RUNTIME_SCHEMA = 'mifu-runtime-profile-v1'
FIELDS = {'schema', 'deviceType', 'questionRows', 'computePrecision', 'autocastEnabled',
          'parameterDtype', 'backend', 'fastEnabled', 'compiled', 'referenceCompile',
          'attentionImplementation', 'evaluationMode', 'cpuFallbackCount', 'autocastFailureCount'}


def _require(condition, message):
    if not condition:
        raise ValueError('Runtime profile: ' + message)


def validate_runtime_profile(profile):
    _require(isinstance(profile, dict) and set(profile) == FIELDS,
             'a complete explicit runtimeProfile is required; previous acceptance needs reevaluation')
    _require(profile['schema'] == RUNTIME_SCHEMA, 'unsupported schema')
    _require(profile['deviceType'] in ('cpu', 'cuda'), 'only CPU/CUDA execution is qualified')
    _require(type(profile['questionRows']) is int and profile['questionRows'] == 1, 'one question per inference is required')
    _require(type(profile['autocastEnabled']) is bool, 'autocastEnabled must be explicit')
    precision = profile['computePrecision']
    _require(precision in ('float32', 'float16', 'bfloat16'), 'unsupported compute precision')
    _require((profile['autocastEnabled'] and precision in ('float16', 'bfloat16')) or
             (not profile['autocastEnabled'] and precision == 'float32'), 'autocast and compute precision disagree')
    _require(profile['deviceType'] != 'cpu' or precision != 'float16', 'CPU float16 is not qualified')
    _require(profile['parameterDtype'] == 'float32', 'only the pinned FP32-resident parameter path is qualified')
    _require(profile['backend'] == 'eager', 'only eager inference is qualified')
    for key in ('fastEnabled', 'compiled', 'referenceCompile'):
        _require(profile[key] is False, key + ' must remain disabled')
    _require(profile['attentionImplementation'] in ('sdpa', 'eager'), 'unknown encoder attention implementation')
    _require(profile['evaluationMode'] is True, 'all model modules must remain in evaluation mode')
    for key in ('cpuFallbackCount', 'autocastFailureCount'):
        _require(type(profile[key]) is int and profile[key] == 0,
                 key + ' must be zero; a fallback cannot inherit quality acceptance')
    return dict(profile)


def device_type(device):
    # torch.device exposes .type; explicit lightweight test agents may use text.
    value = getattr(device, 'type', None) if not isinstance(device, str) else device.split(':', 1)[0]
    _require(value in ('cpu', 'cuda'), 'active device is absent or unsupported')
    return value


def _dtype(value):
    value = str(value)
    if value.startswith('torch.'):
        value = value[len('torch.'):]
    _require(value in ('float32', 'float16', 'bfloat16'), 'parameter or compute dtype is absent or unsupported')
    return value


def inspect_agent_runtime(agent):
    """Snapshot effective single-question policy, parameter placement and counters.

    In Laya 0.4.31 CPU OOM fallback is scoped and can restore `device` before
    returning. Its cumulative counter must therefore also remain zero. CPU AMP
    can similarly retry a call in FP32 without changing the advertised dtype;
    _amp_failures exposes that retry for this one-question request.
    """
    model = getattr(agent, 'model', None)
    _require(model is not None, 'resident model is missing')
    active_device = device_type(getattr(agent, 'device', None))
    amp_for = getattr(agent, '_amp_enabled_for', None)
    dtype_for = getattr(agent, 'dtype_for', None)
    _require(callable(amp_for) and callable(dtype_for), 'effective per-call precision is not observable')
    autocast = amp_for(1)
    _require(type(autocast) is bool and autocast is getattr(agent, 'amp_enabled', None),
             'active autocast policy is inconsistent')
    parameters = list(model.parameters())
    _require(bool(parameters), 'resident parameter dtype cannot be inspected')
    parameter_dtypes = {_dtype(parameter.dtype) for parameter in parameters}
    _require(len(parameter_dtypes) == 1, 'mixed resident parameter dtypes are not qualified')
    _require(all(device_type(parameter.device) == active_device for parameter in parameters),
             'resident parameters do not match active device')
    modules = list(model.modules())
    _require(bool(modules), 'model evaluation mode is not observable')
    config = model.encoder.config
    profile = {'schema': RUNTIME_SCHEMA, 'deviceType': active_device, 'questionRows': 1,
               'computePrecision': _dtype(dtype_for(1)), 'autocastEnabled': autocast,
               'parameterDtype': next(iter(parameter_dtypes)), 'backend': getattr(agent, 'backend', None),
               'fastEnabled': getattr(agent, '_fast', 'missing') is not None,
               'compiled': getattr(agent, '_compiled', None),
               'referenceCompile': getattr(config, 'reference_compile', None),
               'attentionImplementation': getattr(config, '_attn_implementation', None),
               'evaluationMode': all(getattr(module, 'training', None) is False for module in modules),
               'cpuFallbackCount': getattr(agent, 'cpu_fallback_count', None),
               'autocastFailureCount': getattr(agent, '_amp_failures', None)}
    return validate_runtime_profile(profile)


def require_matching_runtime(agent, accepted_profile):
    accepted = validate_runtime_profile(accepted_profile)
    actual = inspect_agent_runtime(agent)
    _require(actual == accepted, 'active execution differs from the evaluated runtime')
    return actual
