# Validation Status — {{PROJECT_NAME}}

**Model:** `{{MODEL_ID}}`
**Task:** {{TASK_DESCRIPTION}}
**Platform:** Kubeflow Pipelines on NVIDIA DGX Spark (GB10, 128 GB unified memory)
**Last updated:** {{DATE}}

---

## Current Status

| Component | Status |
|---|---|
| `baseline_eval` | 🔲 Not yet run |
| `fine_tune` | 🔲 Not yet run |
| `post_finetune_eval` | 🔲 Not yet run |
| `baseline_safety_eval` | 🔲 Not yet run |
| `safety_eval` | 🔲 Not yet run |
| `deployment_gate` | ✅ Implemented (template) |
| GPU profiling (nsys) | 🔲 Not yet configured |

**Project is in scaffolding phase.** Pipeline compiles; no runs have been executed yet.

---

## Run Table

| Run | Purpose | Result | Baseline Accuracy | Key Finding |
|---|---|---|---|---|
| — | — | — | — | — |

> Update this table after each run. Pull from `runs/RUNS.md` — keep this doc as the sanitized public summary.

---

## What Is Implemented

### Infrastructure (inherited from platform template)
- KFP v2 pipeline scaffold with all 6 stages wired
- `_local_model_path()` — bypasses HuggingFace `.locks/` PermissionError on 9p mount
- Hard-link HF cache (minikube 9p symlink fix)
- `deploy_pipeline.py` with per-stage nsys profiling flags
- MLflow run-per-stage tracking with live `running_accuracy` curve
- Nsight profiling infrastructure (privileged pods, `/tmp` write + `cp`, base64 inline scripts)
- `purge_kfp.py`, `purge_nsight.py`
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
- GPU profiling run

---

## Known Issues

None yet.

> **Platform-level fixes** (bitsandbytes on Blackwell, trl 0.29 API, PIP_CONSTRAINT, 9p symlinks, nsys mmap, CUPTI privileges) are already incorporated in this template. See [medgemma-kfp-ft-eval-pipeline/docs/VALIDATION_STATUS.md](https://github.com/miramar-labs-org/medgemma-kfp-ft-eval-pipeline/blob/main/docs/VALIDATION_STATUS.md) for full history.

---

## Fixed Issues

*(fill in as issues are discovered and resolved)*

---

## Latest Profiling Finding

No profiling runs yet.
