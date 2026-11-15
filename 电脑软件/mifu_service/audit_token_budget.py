"""Audit generated shards using the installed Laya tokenizer and sequence builder.

This checks input preservation, not prediction accuracy. It never loads weights.
Only state and questions enter the model; audit/provenance fields remain outside.
"""
from __future__ import annotations

import argparse
from collections import Counter
import gzip
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path


def sha256(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def inspect_question(tokenizer, state, question, max_len=1024, head_max_len=256):
    from laya.common import build_head, build_sequence, encode_text, render_options
    from laya.train import to_internal
    internal = to_internal('printer', question)
    raw_options = [len(encode_text(tokenizer, ' ' + text.replace(tokenizer.mask_token, ' '),
                                  add_special_tokens=False)['input_ids'])
                   for text in render_options(internal)]
    head, _, option_stats = build_head(tokenizer, internal, head_max_len)
    ids, markers, _, truncation = build_sequence(
        tokenizer, state, internal, max_len, head_max_len,
        return_stats=True, return_truncation_stats=True)
    cap = min(48, (option_stats['tokens_per_option'] - 1)
              if option_stats['tokens_per_option'] is not None else 48)
    instruction = '%s question: %s' % (internal['t'], str(internal['ins']).replace(tokenizer.mask_token, ' '))
    raw_instruction = len(encode_text(tokenizer, instruction, add_special_tokens=False)['input_ids'])
    actual_instruction = markers[0] - 2 if markers else 0
    errors = []
    if truncation['truncated']:
        errors.append('state_truncated')
    if any(length > cap for length in raw_options):
        errors.append('option_description_truncated')
    if raw_instruction > actual_instruction:
        errors.append('instruction_truncated')
    if option_stats['options_distinct'] != option_stats['options']:
        errors.append('option_collision')
    if len(markers) != option_stats['options']:
        errors.append('option_marker_missing')
    return {'errors': errors, 'sequence_tokens': len(ids), 'head_tokens': len(head),
            'state_tokens': truncation['state_tokens'],
            'state_tokens_dropped': truncation['state_tokens_dropped'],
            'max_option_tokens': max(raw_options, default=0),
            'instruction_tokens': raw_instruction}


def audit(bundle: Path, tokenizer_dir: Path, max_rows: int = 10000,
          max_len: int = 1024, head_max_len: int = 256) -> dict:
    if max_rows < 1 or head_max_len < 1 or max_len <= head_max_len:
        raise ValueError('positive sample size and max_len > head_max_len required')
    manifest = json.loads((bundle / 'manifest.json').read_text(encoding='utf-8'))
    checked = scanned = 0
    errors, maxima, split_counts, feature_counts = Counter(), Counter(), Counter(), Counter()
    examples = []
    split_names = [name for name in ('train', 'validation', 'calibration', 'holdout', 'permutation_probes')
                   if name in manifest['splits']]
    total_rows = sum(manifest['splits'][name]['rows'] for name in split_names)
    if not split_names or total_rows < 1:
        raise ValueError('Cannot audit an empty corpus')
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(str(tokenizer_dir), local_files_only=True)
    stride = max(1, math.ceil(total_rows / max_rows))
    for split in split_names:
        spec = manifest['splits'][split]
        # Deterministic systematic sampling spread over every split, bounded memory.
        split_scanned = 0
        for shard in spec['shards']:
            path = (bundle / shard['path']).resolve()
            if path.parent != bundle.resolve() or sha256(path) != shard['sha256']:
                raise ValueError('Shard path or checksum mismatch: ' + shard['path'])
            shard_count = 0
            with gzip.open(path, 'rt', encoding='utf-8') as handle:
                for line in handle:
                    index = split_scanned
                    shard_count += 1
                    split_scanned += 1
                    scanned += 1
                    if index % stride:
                        continue
                    row = json.loads(line)
                    result = inspect_question(tokenizer, row['state'], row['questions']['printer'], max_len, head_max_len)
                    checked += 1
                    split_counts[split] += 1
                    errors.update(result['errors'])
                    for key, value in result.items():
                        if isinstance(value, int):
                            maxima[key] = max(maxima[key], value)
                    for candidate in row['state'].get('candidates', {}).values():
                        feature_counts[str(candidate.get('model')) + '/' + str(candidate.get('nozzle_mm')) + '/' + candidate.get('feed', {}).get('kind', 'unknown')] += 1
                    if result['errors'] and len(examples) < 12:
                        examples.append({'split': split, 'index': index, **result})
            if shard_count != shard['rows']:
                raise ValueError('Shard row count mismatch: ' + shard['path'])
        if split_scanned != spec['rows']:
            raise ValueError('Split row count mismatch: ' + split)
    if checked == 0:
        raise ValueError('No actual rows were tokenized')
    return {'schemaVersion': 1, 'purpose': 'token_preservation_only_not_model_quality',
            'status': ('passed_all_rows' if checked == scanned else 'passed_sample') if not errors else 'failed',
            'manifestSha256': sha256(bundle / 'manifest.json'),
            'tokenizerSha256': sha256(tokenizer_dir / 'tokenizer.json'),
            'packages': {name: importlib.metadata.version(name) for name in ('laya', 'transformers', 'tokenizers')},
            'maxLen': max_len, 'headMaxLen': head_max_len,
            'scannedRows': scanned, 'tokenizedRows': checked,
            'allRowsTokenized': checked == scanned, 'sampleBySplit': dict(split_counts),
            'maxima': dict(maxima), 'errors': dict(errors), 'examples': examples,
            'sampleHardwareCombinations': len(feature_counts),
            'limitations': ['Sample success does not prove unsampled rows fit.',
                            'No weights loaded; no training or recommendation accuracy measured.',
                            'Changing tokenizer, SDK, input schema or sequence lengths requires another audit.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--tokenizer', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--max-rows', type=int, default=10000)
    parser.add_argument('--max-len', type=int, default=1024)
    parser.add_argument('--head-max-len', type=int, default=256)
    args = parser.parse_args()
    if args.out.exists():
        raise FileExistsError(args.out)
    report = audit(args.bundle, args.tokenizer, args.max_rows, args.max_len, args.head_max_len)
    with args.out.open('x', encoding='utf-8') as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    print(json.dumps({key: report[key] for key in ('status', 'scannedRows', 'tokenizedRows', 'maxima', 'errors')}, ensure_ascii=False))
    if report['errors']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()
