"""Explicit, offline feedback-review/export/training workflow for Mifu.

No HTTP endpoint can train, download a checkpoint, or choose an output path.
Run `python training.py --help`. Review labels are intentionally separate from
client accept/correct feedback: accepting a suggestion does not prove optimality.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
from typing import Any

from mifu_server import SDK_VERSION, build_question, utc_now, validate_request, request_contract
from model_acceptance import checkpoint_artifact_hashes


def read_jsonl(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8-sig") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            if len(line.encode("utf-8")) > 384 * 1024:
                raise ValueError(f"Line {line_number} exceeds the size limit")
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError(f"Line {line_number} must be an object")
            rows.append(row)
    return rows


def fingerprint(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, allow_nan=False).encode("utf-8")).hexdigest()


def file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def export_dataset(records_path: Path, labels_path: Path, output: Path, eval_fraction: float = 0.2) -> dict:
    if not 0 < eval_fraction < 1:
        raise ValueError("eval_fraction must be between zero and one")
    records = {}
    for record in read_jsonl(records_path):
        record_id = record.get("recordId")
        if not isinstance(record_id, str) or record_id in records:
            raise ValueError("Missing or duplicate recordId in feedback")
        records[record_id] = record
    prepared = []
    excluded_single_candidate = []
    seen_records = set()
    for label in read_jsonl(labels_path):
        record_id = label.get("recordId")
        if record_id not in records or record_id in seen_records:
            raise ValueError("Label references missing or duplicate recordId")
        seen_records.add(record_id)
        if label.get("reviewSource") not in {"expert_review", "controlled_experiment"}:
            raise ValueError("A separate expert_review or controlled_experiment label is required")
        if any(not isinstance(label.get(field), str) or not label[field].strip()
               for field in ("reviewer", "rationale", "selectedCandidateId")):
            raise ValueError("Reviewer, rationale and selectedCandidateId are required")
        raw_request = records[record_id]['request']
        if request_contract(raw_request) != 'legacy_v1':
            raise ValueError('Versioned v4 observations require their own reviewed export recipe; cannot project them as legacy_v1')
        request = validate_request(raw_request, minimum_candidates=1)
        if len(request['candidates']) == 1:
            if label['selectedCandidateId'] != request['candidates'][0]['id']:
                raise ValueError('Reviewed choice is not an eligible candidate')
            excluded_single_candidate.append(record_id)
            continue  # Useful outcome evidence, but not a ranking decision.
        task_id = request["plate"].get("taskId") or request["plate"].get("jobId")
        if not isinstance(task_id, str) or not task_id.strip():
            raise ValueError("plate.taskId or plate.jobId is required to keep all plates of a task in one split")
        state, questions, mapping = build_question(request)
        reverse = {identifier: token for token, identifier in mapping.items()}
        selected = label["selectedCandidateId"]
        if selected not in reverse:
            raise ValueError("Reviewed choice is not an eligible candidate")
        row = {"state": state, "questions": questions, "expected": {"printer": reverse[selected]}}
        prepared.append((fingerprint(task_id), row, record_id))
    groups = sorted({group for group, _, _ in prepared})
    if len(groups) < 2:
        raise ValueError("Need reviewed examples from at least two independent tasks")
    eval_count = max(1, min(len(groups) - 1, round(len(groups) * eval_fraction)))
    eval_groups = set(groups[:eval_count])
    train_rows, eval_rows = [], []
    sources = {"train": [], "eval": []}
    for group, row, record_id in prepared:
        split = "eval" if group in eval_groups else "train"
        (eval_rows if split == "eval" else train_rows).append(row)
        sources[split].append({"recordId": record_id, "taskHash": group})
    ensure_disjoint(train_rows, eval_rows)
    output.mkdir(parents=True, exist_ok=False)
    for name, rows in (("train", train_rows), ("eval", eval_rows)):
        with (output / f"{name}.jsonl").open("x", encoding="utf-8") as handle:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + "\n")
    report = {"schemaVersion": 1, "createdAt": utc_now(), "trainRows": len(train_rows), "evalRows": len(eval_rows),
              "taskGroups": len(groups), "splitMethod": "deterministic_task_hash",
              "labelsSource": "independently_reviewed", "sources": sources,
              "excludedSingleCandidateRecords": excluded_single_candidate,
              "warnings": ["通过数据格式检查不代表样本数量足够或标签是全局最优。", "发布前应增加时间外验证、候选顺序扰动与真实排队成本对比。"]}
    (output / "dataset_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def ensure_disjoint(train_rows: list[dict], eval_rows: list[dict]) -> None:
    train_states = {fingerprint({"state": row.get("state"), "questions": row.get("questions")}) for row in train_rows}
    eval_states = {fingerprint({"state": row.get("state"), "questions": row.get("questions")}) for row in eval_rows}
    if not train_rows or not eval_rows:
        raise ValueError("Train and independent evaluation files must both be nonempty")
    if train_states & eval_states:
        raise ValueError("Identical states/questions overlap train and eval; remove leakage before training")


def train_model(train_path: Path, eval_path: Path, base: Path, output: Path, version: str,
                full_finetune: bool = False, epochs: int = 4, dry_run: bool = False) -> dict:
    if not version.strip() or len(version) > 128:
        raise ValueError("A nonempty Mifu version is required")
    if not 1 <= epochs <= 100:
        raise ValueError("epochs must be between 1 and 100")
    base = base.resolve(strict=True)
    if not base.is_dir() or not (base / "rl_agent_config.json").is_file() or not (base / "model.safetensors").is_file():
        raise ValueError("--base must be an already downloaded local Laya multilingual checkpoint directory")
    config = json.loads((base / "rl_agent_config.json").read_text(encoding="utf-8"))
    # Confirm the backbone instead of trusting the filename or calling an English
    # root checkpoint a Chinese Mifu base. mmBERT uses the ModernBERT architecture.
    encoder_config_path = base / "encoder" / "config.json"
    encoder_config = json.loads(encoder_config_path.read_text(encoding="utf-8")) if encoder_config_path.is_file() else {}
    identifiers = " ".join(str(value) for key, value in {**config, **encoder_config}.items()
                           if key in {"encoder", "encoder_name", "encoder_model", "encoder_id", "model_name", "_name_or_path", "base_model"})
    if "mmbert" not in identifiers.lower() and "multilingual" not in identifiers.lower():
        raise ValueError("Cannot verify the local base as Laya multilingual/mmBERT; inspect its config before training")
    train_rows, eval_rows = read_jsonl(train_path), read_jsonl(eval_path)
    if any(row.get('inputContract') == 'mifu-decision-v4' or
           isinstance(row.get('state'), dict) and row['state'].get('schema') == 'mifu-decision-v4'
           for row in train_rows + eval_rows):
        raise ValueError('Formal legacy training cannot train or label mifu-decision-v4 inputs as legacy_v1')
    if any(isinstance(row.get("mifu_provenance"), dict)
           and row["mifu_provenance"].get("source") == "synthetic_pipeline_only"
           for row in train_rows + eval_rows):
        raise ValueError("Synthetic pipeline data cannot create a deployable Mifu manifest; use run_curriculum_experiment.py")
    ensure_disjoint(train_rows, eval_rows)
    plan = {"base": str(base), "trainRows": len(train_rows), "evalRows": len(eval_rows), "epochs": epochs,
            "microBatch": 1, "gradientAccumulation": 8, "freezeEncoder": not full_finetune,
            "maxLen": 1024, "headMaxLen": 256, "device": "cuda", "sdkVersion": SDK_VERSION}
    if dry_run:
        # Our dry-run is stricter than upstream: no tokenizer, dependencies, weights,
        # internet connection or output directory is required/created.
        return plan
    if output.exists():
        raise ValueError("Output must be a new directory; existing checkpoints are never overwritten")
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    if importlib.metadata.version("laya") != SDK_VERSION:
        raise RuntimeError("Install the pinned Laya SDK version before training")
    import torch
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is not available; training was not started")
    # The legacy option descriptions can silently lose text at the SDK's fixed
    # per-option cap even when every marker survives. Audit before output or GPU
    # training; the future v4 recipe is a separate explicit migration.
    from audit_token_budget import inspect_question
    from transformers import AutoTokenizer
    tokenizer = AutoTokenizer.from_pretrained(str(base / 'tokenizer'), local_files_only=True)
    token_audit = {'rows': 0, 'maxSequenceTokens': 0, 'maxOptionTokens': 0}
    for row in train_rows + eval_rows:
        state = row.get('state')
        if (not isinstance(state, dict) or set(state) != {'plate', 'objective'}
                or state['objective'] != 'minimize_completion_and_changeover'
                or set(row.get('questions', {})) != {'printer'}):
            raise ValueError('Formal legacy training cannot label a different input contract as legacy_v1')
        check = inspect_question(tokenizer, state, row['questions']['printer'], 1024, 256)
        if check['errors']:
            raise ValueError('Training evidence would be truncated: ' + ', '.join(check['errors']))
        token_audit['rows'] += 1
        token_audit['maxSequenceTokens'] = max(token_audit['maxSequenceTokens'], check['sequence_tokens'])
        token_audit['maxOptionTokens'] = max(token_audit['maxOptionTokens'], check['max_option_tokens'])
    from laya.train import TrainConfig, finetune
    training_config = TrainConfig(epochs=epochs, micro_batch=1, grad_accum=8,
                                 freeze_encoder=not full_finetune, shuffle_options=("choice",),
                                 max_len=1024, head_max_len=256, amp=True, gradient_checkpointing=True,
                                 eval_data=str(eval_path.resolve()))
    output.mkdir(parents=True, exist_ok=False)
    result = finetune(str(train_path.resolve()), str(base), str(output.resolve()), training_config, device="cuda")
    report = result.get("train_report", {})
    if report.get("is_held_out") is not True or not report.get("eval_items") or not result.get("train_items"):
        raise RuntimeError("Training output lacks independent evaluation; no deployable Mifu manifest was written")
    manifest = {"schemaVersion": 1, "modelName": "Mifu", "version": version, "base": "laya-multilingual",
                "sdkVersion": SDK_VERSION, "trainingCompleted": True, "trainedAt": utc_now(),
                "trainSha256": file_hash(train_path), "evalSha256": file_hash(eval_path),
                "weightsSha256": file_hash(output / "model.safetensors"),
                "trainingPlan": {k: v for k, v in plan.items() if k != "base"},
                "autoExecutionEnabled": False,
                "notice": "已完成训练与独立评估，不代表达到生产质量门槛；仍需人工确认建议。"}
    # Optimizer completion and a scored split are not an operational acceptance.
    # In particular, a chance-level checkpoint must never become service-ready.
    manifest['inputContract'] = 'legacy_v1'
    manifest['artifactsSha256'] = checkpoint_artifact_hashes(output)
    manifest['inputTokenAudit'] = token_audit
    manifest['notice'] = '训练结束，仍需按权重与输入契约绑定的独立质量验收。'
    (output / "candidate_manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"candidateManifest": manifest, "report": report, "deployable": False,
            "status": "trained_pending_operational_acceptance"}


def main():
    parser = argparse.ArgumentParser(description="Mifu 离线数据导出与显式训练；不会下载权重")
    subparsers = parser.add_subparsers(dest="command", required=True)
    export = subparsers.add_parser("export", help="仅导出已人工复核的标签")
    export.add_argument("--records", type=Path, default=Path(__file__).resolve().parent / "data" / "feedback.jsonl")
    export.add_argument("--labels", type=Path, required=True)
    export.add_argument("--out", type=Path, required=True)
    export.add_argument("--eval-fraction", type=float, default=0.2)
    train = subparsers.add_parser("train", help="使用已有本地权重训练，不隐式下载")
    train.add_argument("--data", type=Path, required=True)
    train.add_argument("--eval", type=Path, required=True)
    train.add_argument("--base", type=Path, required=True)
    train.add_argument("--out", type=Path, required=True)
    train.add_argument("--version", required=True)
    train.add_argument("--epochs", type=int, default=4)
    train.add_argument("--full-finetune", action="store_true")
    train.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "export":
            result = export_dataset(args.records, args.labels, args.out, args.eval_fraction)
        else:
            result = train_model(args.data, args.eval, args.base, args.out, args.version,
                                 args.full_finetune, args.epochs, args.dry_run)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (ValueError, OSError, RuntimeError) as exc:
        parser.exit(1, f"Mifu: {exc}\n")


if __name__ == "__main__":
    main()
