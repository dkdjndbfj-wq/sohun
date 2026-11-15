"""Optional GPU pipeline experiment. Deliberately never creates mifu_manifest.json."""
from __future__ import annotations

import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import time

from prepare_curriculum import validate_bundle


def run(bundle: Path, base: Path, output: Path, epochs: int = 1, dry_run: bool = False) -> dict:
    manifest = validate_bundle(bundle)
    if not 1 <= epochs <= 4:
        raise ValueError('Pipeline experiments support 1 through 4 epochs')
    if output.exists():
        raise ValueError('Experiment output must be a new directory')
    if not (base / 'model.safetensors').is_file() or not (base / 'rl_agent_config.json').is_file():
        raise ValueError('Complete local base checkpoint is required')
    base_config = json.loads((base / 'rl_agent_config.json').read_text(encoding='utf-8'))
    if 'mmbert' not in str(base_config.get('encoder', '')).lower():
        raise ValueError('Expected Laya multilingual/mmBERT base')
    report = {'purpose': 'synthetic_pipeline_experiment', 'deployable': False,
              'domainTrainingCompleted': False, 'epochs': epochs,
              'featureSchemaVersion': manifest.get('featureSchemaVersion', 'current_online_v1'),
              'calibrationMode': 'disabled_pending_separate_grouped_calibration',
              'trainRows': manifest['files']['train']['rows'],
              'validationRows': manifest['files']['validation']['rows'],
              'reservedSplits': ['calibration', 'holdout'],
              'inputHashes': {name: value['sha256'] for name, value in manifest['files'].items()},
              'productionManifestCreated': False}
    if dry_run:
        return {**report, 'status': 'plan_only_no_gpu_or_sdk_loaded'}
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    if importlib.metadata.version('laya') != '0.4.31':
        raise RuntimeError('Expected laya==0.4.31')
    import torch
    if not torch.cuda.is_available():
        raise RuntimeError('CUDA is unavailable')
    if manifest.get('featureSchemaVersion'):
        # A future hardware layout must fit intact. Do not rely on the SDK's
        # marker check: distinct options can still lose most of their text.
        from audit_token_budget import inspect_question
        from transformers import AutoTokenizer
        tokenizer = AutoTokenizer.from_pretrained(str(base / 'tokenizer'), local_files_only=True)
        token_report = {'rows': 0, 'maxSequenceTokens': 0, 'truncatedRows': 0}
        for split in ('train', 'validation', 'calibration', 'holdout'):
            with (bundle / f'{split}.jsonl').open(encoding='utf-8') as handle:
                for line in handle:
                    row = json.loads(line)
                    if row['state'].get('featureSchemaVersion') != manifest['featureSchemaVersion']:
                        raise ValueError('Experimental row schema differs from bundle')
                    check = inspect_question(tokenizer, row['state'], row['questions']['printer'], 1024, 256)
                    if check['errors']:
                        raise ValueError('Experimental input would lose evidence: ' + ', '.join(check['errors']))
                    token_report['rows'] += 1
                    token_report['maxSequenceTokens'] = max(token_report['maxSequenceTokens'], check['sequence_tokens'])
        report['inputTokenAudit'] = token_report
    from laya.train import TrainConfig, finetune
    config = TrainConfig(epochs=epochs, micro_batch=1, grad_accum=8,
                         freeze_encoder=True, shuffle_options=('choice',),
                         calib_frac=0.0, calib_max=0,
                         max_len=1024, head_max_len=256, amp=True,
                         gradient_checkpointing=True,
                         eval_data=str((bundle / 'validation.jsonl').resolve()))
    output.mkdir(parents=True, exist_ok=False)
    torch.cuda.synchronize()
    torch.cuda.reset_peak_memory_stats()
    started = time.perf_counter()
    result = finetune(str((bundle / 'train.jsonl').resolve()), str(base.resolve()),
                      str(output.resolve()), config, device='cuda')
    torch.cuda.synchronize()
    report.update(status='pipeline_run_finished_not_domain_validated', sdkResult=result,
                  runtime={'device': torch.cuda.get_device_name(0),
                           'elapsedSeconds': round(time.perf_counter() - started, 3),
                           'peakTensorAllocatedBytes': torch.cuda.max_memory_allocated(),
                           'peakTensorReservedBytes': torch.cuda.max_memory_reserved()})
    if (output / 'mifu_manifest.json').exists():
        raise RuntimeError('Unexpected production manifest in an experimental output')
    (output / 'experiment_report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    return report


def main():
    parser = argparse.ArgumentParser(description='Mifu 仅模拟数据的GPU管线实验，不生成可部署模型')
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--epochs', type=int, default=1)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    print(json.dumps(run(args.bundle, args.base, args.out, args.epochs, args.dry_run), ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
