"""Small, instrumented Laya controls. Never writes a production manifest.

Uses only training/validation splits. One row per episode avoids pretending
successive simulated assignments are independent examples. The installed SDK is
not patched; its tokenization, model and objectives are reused unchanged.
"""
from __future__ import annotations

import argparse
import contextlib
import copy
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import random
import time


CONTROLS = {
    'a': {'precision': 'fp16', 'loss': 'rlcd', 'encoder_layers': 0, 'parallel': False},
    'b': {'precision': 'fp32', 'loss': 'rlcd', 'encoder_layers': 0, 'parallel': False},
    'c': {'precision': 'fp32', 'loss': 'soft-ce', 'encoder_layers': 0, 'parallel': False},
    'd': {'precision': 'fp32', 'loss': 'soft-ce', 'encoder_layers': 4, 'parallel': False},
    'e': {'precision': 'fp32', 'loss': 'soft-ce', 'encoder_layers': 4, 'parallel': True},
    'f': {'precision': 'fp32', 'loss': 'soft-ce', 'encoder_layers': 0, 'parallel': True, 'compact': True},
    'g': {'precision': 'fp32', 'loss': 'soft-ce', 'encoder_layers': 4, 'parallel': True, 'compact': True},
    'h': {'precision': 'bf16', 'loss': 'soft-ce', 'encoder_layers': 4, 'parallel': True, 'compact': True,
          'physical_rename_augmentation': True},
}


def select_episodes(path: Path, count: int):
    selected, groups = [], set()
    with path.open(encoding='utf-8') as handle:
        for line in handle:
            row = json.loads(line)
            group = row['mifu_provenance']['groupId']
            if group in groups:
                continue
            groups.add(group)
            selected.append(row)
            if len(selected) == count:
                break
    if len(selected) != count:
        raise ValueError('Insufficient distinct episodes')
    return selected, groups


def renamed_row(row):
    """Reverse physical candidates and relabel; preserve the actual answer."""
    result = copy.deepcopy(row)
    old_keys = list(row['questions']['printer']['criteria'])
    remap = dict(zip(reversed(old_keys), old_keys))
    result['state']['candidates'] = {remap[key]: value for key, value in
                                     reversed(list(row['state']['candidates'].items()))}
    result['questions']['printer']['criteria'] = {key: key for key in old_keys}
    result['expected']['printer'] = remap[row['expected']['printer']]
    return result


def signature(rows):
    return hashlib.sha256(json.dumps(rows, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def forward(model, batch, device, precision, frozen):
    import torch
    kwargs = {'detach_encoder': frozen}
    if 'option_ids' in batch:
        kwargs.update(position_ids=batch['position_ids'].to(device),
                      option_ids=batch['option_ids'].to(device))
    ctx = torch.autocast('cuda', dtype={'fp16': torch.float16, 'bf16': torch.bfloat16}[precision]) \
        if precision != 'fp32' else contextlib.nullcontext()
    with ctx:
        logits, _ = model(*(batch[key].to(device) for key in
                            ('input_ids', 'attention_mask', 'marker_pos', 'marker_mask', 'qtype')),
                          **kwargs)
    return logits.float()


def execute(args):
    os.environ.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1')
    if importlib.metadata.version('laya') != '0.4.31':
        raise RuntimeError('This diagnostic requires pinned laya==0.4.31')
    import torch
    from laya import train as sdk
    from laya.common import collate_items
    from audit_token_budget import inspect_question

    if args.out.exists():
        raise FileExistsError(args.out)
    args.out.mkdir(parents=True)
    train_rows, train_groups = select_episodes(args.bundle / 'train.jsonl', args.train_episodes)
    valid_rows, valid_groups = select_episodes(args.bundle / 'validation.jsonl', args.validation_episodes)
    if train_groups & valid_groups:
        raise ValueError('Training and validation episodes overlap')
    device = torch.device('cuda')
    if not torch.cuda.is_available():
        raise RuntimeError('CUDA required')
    report = {'purpose': 'learning_diagnosis', 'deployable': False,
              'runnerSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'sdkVersion': importlib.metadata.version('laya'),
              'reservedSplitsRead': [], 'seed': args.seed, 'requestedUpdates': args.updates,
              'trainEpisodes': len(train_groups), 'validationEpisodes': len(valid_groups),
              'trainSignature': signature(train_rows), 'validationSignature': signature(valid_rows),
              'controls': {}, 'device': torch.cuda.get_device_name(0)}

    def persist():
        (args.out / 'diagnosis_report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')

    for name in args.controls.split(','):
        settings = CONTROLS[name]
        print('CONTROL_START', name, json.dumps(settings), flush=True)
        torch.manual_seed(args.seed)
        model, tok, cfg = sdk.load_checkpoint(str(args.base))
        model.to(device)
        max_len, head_max_len = (2048, 1024) if settings.get('compact') else (1024, 256)
        def adapt(rows):
            if not settings.get('compact'):
                return rows
            from decision_contract import build_decision_input, from_simulation_row, label_for_candidate
            result = []
            for row in rows:
                prepared = build_decision_input(from_simulation_row(row), tokenizer=tok, now_epoch_s=0)
                result.append({'state': prepared['state'], 'questions': prepared['questions'],
                               'expected': {'printer': label_for_candidate(prepared, row['expected']['printer'])},
                               'mifu_provenance': copy.deepcopy(row['mifu_provenance'])})
            return result
        input_train, input_valid = adapt(train_rows), adapt(valid_rows)
        for row in input_train + input_valid:
            check = inspect_question(tok, row['state'], row['questions']['printer'], max_len, head_max_len)
            if check['errors']:
                raise ValueError(check)
        train_items, skips = sdk.items_from_rows(tok, input_train, max_len, head_max_len)
        valid_items, valid_skips = sdk.items_from_rows(tok, input_valid, max_len, head_max_len)
        renamed_items, renamed_skips = sdk.items_from_rows(tok, adapt([renamed_row(r) for r in valid_rows]), max_len, head_max_len)
        renamed_train_items = None
        if settings.get('physical_rename_augmentation'):
            renamed_train_items, _ = sdk.items_from_rows(tok, adapt([renamed_row(r) for r in train_rows]), max_len, head_max_len)
            if len(renamed_train_items) != len(train_items):
                raise ValueError('Augmentation dropped training rows')
        if len(train_items) != len(train_rows) or len(valid_items) != len(valid_rows) or len(renamed_items) != len(valid_rows):
            raise ValueError((skips, valid_skips, renamed_skips))
        parallel = settings['parallel']
        def evaluate(items, reverse=False):
            model.eval()
            records, decisions = [], []
            with torch.no_grad():
                for start in range(0, len(items), 4):
                    its = items[start:start + 4]
                    encoded = [sdk.encode_item(tok, it, max_len, head_max_len,
                                               list(reversed(range(it['k']))) if reverse else None,
                                               parallel) for it in its]
                    batch = collate_items([encoded], tok.pad_token_id)
                    logits = forward(model, batch, device, 'fp32', True).cpu()
                    for i, it in enumerate(its):
                        z = logits[i, :it['k']]
                        if reverse:
                            z = z.flip(0)
                        records.append((it['qtype'], z.numpy(), it['target'], it['k']))
                        decisions.append(int(z.argmax()))
            return sdk.evaluate_records(records), decisions

        before, _ = evaluate(valid_items)
        for p in model.encoder.parameters():
            p.requires_grad_(False)
        for layer in list(model.encoder.layers)[-settings['encoder_layers']:] if settings['encoder_layers'] else []:
            for p in layer.parameters():
                p.requires_grad_(True)
        model.head_checkpointing = True
        if settings['encoder_layers']:
            model.encoder.gradient_checkpointing_enable(gradient_checkpointing_kwargs={'use_reentrant': False})
        groups = [{'params': [p for n, p in model.named_parameters() if not n.startswith('encoder.') and p.requires_grad], 'lr': 1e-4}]
        encoder_params = [p for n, p in model.named_parameters() if n.startswith('encoder.') and p.requires_grad]
        if encoder_params:
            groups.append({'params': encoder_params, 'lr': 2.5e-5})
        optimizer = torch.optim.AdamW(groups, weight_decay=0.01)
        scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=args.updates, eta_min=1e-6)
        scaler = torch.amp.GradScaler('cuda') if settings['precision'] == 'fp16' else None
        params = [p for g in groups for p in g['params']]
        rng = random.Random(args.seed)
        updates = attempts = skips = 0
        step_events = []
        optimizer.register_step_post_hook(lambda *unused: step_events.append(1))
        grad_norms, losses, trace = [], [], []
        torch.cuda.reset_peak_memory_stats()
        started = time.perf_counter()
        model.train()
        # Keep representation dropout disabled consistently across all controls;
        # trainability is the only encoder difference between C and D.
        model.encoder.eval()
        while updates < args.updates and attempts < args.updates + 64:
            optimizer.zero_grad(set_to_none=True)
            loss_sum = 0.0
            for _ in range(4):
                item_index = rng.randrange(len(train_items))
                pool = renamed_train_items if renamed_train_items and rng.random() < 0.5 else train_items
                it = pool[item_index]
                order = sdk.draw_option_order(it, rng, ('choice',))
                batch = collate_items([[sdk.encode_item(tok, it, max_len, head_max_len, order, parallel)]], tok.pad_token_id)
                logits = forward(model, batch, device, settings['precision'], not settings['encoder_layers'])
                if settings['loss'] == 'rlcd':
                    loss = sdk.rlcd_loss(logits, batch['target'].to(device), batch['marker_mask'].to(device),
                                        batch['qtype'].to(device), 0.1, 4, 0.75, 1.0)
                else:
                    loss = sdk.soft_ce_loss(logits, batch['target'].to(device), batch['marker_mask'].to(device))
                if not torch.isfinite(loss):
                    raise RuntimeError('Nonfinite loss')
                loss_sum += float(loss.detach())
                if scaler:
                    scaler.scale(loss / 4).backward()
                else:
                    (loss / 4).backward()
            if scaler:
                scaler.unscale_(optimizer)
            norm = float(torch.nn.utils.clip_grad_norm_(params, 1.0))
            prior_steps = len(step_events)
            if scaler:
                scaler.step(optimizer)
                scaler.update()
            else:
                if not math.isfinite(norm):
                    raise RuntimeError('Nonfinite gradient without GradScaler')
                optimizer.step()
            attempts += 1
            did_step = len(step_events) > prior_steps
            if did_step:
                updates += 1
                scheduler.step()
                grad_norms.append(norm)
                losses.append(loss_sum / 4)
            else:
                skips += 1
            if updates and updates % 32 == 0 and did_step:
                item = {'updates': updates, 'attempts': attempts, 'skipped': skips,
                        'meanLossLast32': sum(losses[-32:]) / len(losses[-32:]),
                        'gradNorm': norm, 'scale': scaler.get_scale() if scaler else None}
                trace.append(item)
                print('CONTROL_PROGRESS', name, json.dumps(item), flush=True)
        after, decisions = evaluate(valid_items)
        fitted, _ = evaluate(train_items[:args.fit_eval_items])
        _, permuted_decisions = evaluate(valid_items, reverse=True)
        renamed_metrics, renamed_decisions = evaluate(renamed_items)
        rename_matches = sum(a == it['k'] - 1 - b for a, b, it in zip(decisions, renamed_decisions, valid_items))
        costs = [[r['state']['candidates'][key]['wait_s'] + r['state']['candidates'][key]['setup_s'] + r['state']['candidates'][key]['run_s']
                  for key in r['questions']['printer']['criteria']] for r in valid_rows]
        regrets = [c[d] - min(c) for c, d in zip(costs, decisions)]
        buckets = {}
        for k in sorted(set(it['k'] for it in valid_items)):
            indices = [i for i, it in enumerate(valid_items) if it['k'] == k]
            buckets[str(k)] = {
                'independentEpisodes': len(indices),
                'accuracy': sum(decisions[i] == valid_items[i]['target'].index(max(valid_items[i]['target'])) for i in indices) / len(indices),
                'optionPermutationConsistency': sum(decisions[i] == permuted_decisions[i] for i in indices) / len(indices),
                'physicalRenameConsistency': sum(decisions[i] == k - 1 - renamed_decisions[i] for i in indices) / len(indices),
                'meanRegretSeconds': sum(regrets[i] for i in indices) / len(indices),
                'maxRegretSeconds': max(regrets[i] for i in indices),
            }
        result = {**settings, 'before': before, 'after': after, 'trainingFit': fitted,
                  'candidateBuckets': buckets, 'trainingFitSampleSize': min(len(train_items), args.fit_eval_items),
                  'status': 'completed' if updates == args.updates else 'incomplete_update_budget',
                  'encoderCheckpointingActive': False,
                  'encoderMode': 'eval_with_gradients_for_unfrozen_layers',
                  'renamedValidation': renamed_metrics,
                  'optionPermutationConsistency': sum(a == b for a, b in zip(decisions, permuted_decisions)) / len(decisions),
                  'physicalRenameConsistency': rename_matches / len(decisions),
                  'meanRegretSeconds': sum(regrets) / len(regrets), 'maxRegretSeconds': max(regrets),
                  'actualOptimizerUpdates': updates, 'skippedUpdates': skips,
                  'attempts': attempts, 'maxGradNorm': max(grad_norms, default=None),
                  'seconds': time.perf_counter() - started,
                  'peakAllocatedBytes': torch.cuda.max_memory_allocated(),
                  'trainableParameters': sum(p.numel() for p in params), 'trace': trace}
        if args.save_checkpoints:
            saved_cfg = dict(cfg, max_len=max_len, head_max_len=head_max_len,
                             option_layout='parallel' if parallel else 'sequential',
                             temperature=[1.0, 1.0, 1.0], temperature_by_options={},
                             mifu_experiment={'inputContract': 'mifu-decision-v4' if settings.get('compact') else 'mifu-hardware-sim-v3',
                                              'deployable': False, 'settings': settings,
                                              'optimizerUpdates': updates})
            saved = args.out / ('checkpoint_' + name)
            sdk.save_checkpoint(model, tok, saved_cfg, str(saved))
            result['checkpoint'] = saved.name
        report['controls'][name] = result
        persist()
        print('CONTROL_RESULT', name, json.dumps(result), flush=True)
        del optimizer, scheduler, model, params, groups, encoder_params, loss, logits, batch
        del p
        if settings['encoder_layers']:
            del layer
        import gc
        gc.collect()
        torch.cuda.empty_cache()
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', required=True, type=Path)
    p.add_argument('--bundle', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path)
    p.add_argument('--controls', default='a,b,c,d,e')
    p.add_argument('--train-episodes', type=int, default=64)
    p.add_argument('--validation-episodes', type=int, default=128)
    p.add_argument('--updates', type=int, default=128)
    p.add_argument('--seed', type=int, default=4070)
    p.add_argument('--save-checkpoints', action='store_true')
    p.add_argument('--fit-eval-items', type=int, default=256)
    args = p.parse_args()
    if any(name not in CONTROLS for name in args.controls.split(',')) or min(args.train_episodes, args.validation_episodes, args.updates) < 1:
        p.error('Invalid controls or sizes')
    execute(args)


if __name__ == '__main__':
    main()
