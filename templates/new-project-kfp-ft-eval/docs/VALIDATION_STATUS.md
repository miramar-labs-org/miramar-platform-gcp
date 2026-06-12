# Validation Status — {{PROJECT_NAME}}

**Model:** `{{MODEL_ID}}`
**Task:** {{TASK_DESCRIPTION}}
**Platform:** Kubeflow Pipelines on NVIDIA DGX Spark (GB10, 128 GB unified memory)
**Last updated:** {{DATE}}

---

## Current Status

| Component              | Status                   |
| ---------------------- | ------------------------ |
| `baseline_eval`        | 🔲 Not yet run            |
| `fine_tune`            | 🔲 Not yet run            |
| `post_finetune_eval`   | 🔲 Not yet run            |
| `baseline_safety_eval` | 🔲 Not yet run            |
| `safety_eval`          | 🔲 Not yet run            |
| `deployment_gate`      | ✅ Implemented (template) |

**Project is in scaffolding phase.** Pipeline compiles; no runs have been executed yet.

---

## Run Table

| Run | Purpose | Result | Baseline Accuracy | Key Finding |
| --- | ------- | ------ | ----------------- | ----------- |
| —   | —       | —      | —                 | —           |

> Update this table after each run. Pull from `runs/RUNS.md` — keep this doc as the sanitized public summary.

---

## What Is Implemented

### Infrastructure (inherited from platform template)
- KFP v2 pipeline scaffold with all 6 stages wired
- MLflow run-per-stage tracking
- `purge_kfp_mlflow.py`
- Nsight Operator integration — add `kubernetes.add_pod_label(task, "nvidia-nsight-profile", "enabled")` to profile any stage
- BF16 direct loading with `max_memory={0: "100GiB"}` (Blackwell GB10 unified memory)

### Project-specific
- `config.yaml` — to be configured
- `formatters.py` / `loaders.py` — to be implemented per `WORKBOOK.md`
- `notebook.ipynb` — stage bodies to be filled in

---

## What Is Still Pending

- Configure `config.yaml`
- Implement dataset formatters and loaders
- Implement all pipeline stage bodies
- First pipeline run — establish baseline accuracy

---

## Known Issues

None yet.

> **Platform-level fixes** (bitsandbytes on Blackwell, trl 0.29 API, PIP_CONSTRAINT, nsys mmap, CUPTI privileges) are already incorporated in this template. See [qwen25-7b-arc-kfp-ft-eval-pipeline/docs/VALIDATION_STATUS.md](https://github.com/miramar-labs-org/qwen25-7b-arc-kfp-ft-eval-pipeline/blob/main/docs/VALIDATION_STATUS.md) for the full fix history (first green run).

---

## Fixed Issues

*(fill in as issues are discovered and resolved)*

---

## Latest Nsight Finding

No profiling runs yet.
