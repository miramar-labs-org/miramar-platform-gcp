# Validation Status — {{PROJECT_NAME}}

**Model/Task:** {{DESCRIPTION}}
**Platform:** Kubeflow Pipelines on NVIDIA DGX Spark (GB10, 128 GB unified memory)
**Last updated:** {{DATE}}

---

## Current Status

| Component | Status |
|---|---|
| `gpu_stage` | 🔲 Not yet run |
| GPU profiling (nsys) | 🔲 Not yet configured |

**Project is in scaffolding phase.** Pipeline compiles; no runs have been executed yet.

---

## Run Table

| Run | Purpose | Result | Key Finding |
|---|---|---|---|
| — | — | — | — |

> Update this table after each run.

---

## What Is Implemented

### Infrastructure (inherited from platform template)
- KFP v2 pipeline with GPU component using NGC PyTorch base image
- nsys profiling: `--profile` flag on `deploy_pipeline.py`; privileged Argo patch; PVC mount
- `purge_kfp.py`, `purge_nsight.py`
- `deploy_pipeline.py` with `--run-name`, `--profile`, `--profile-stage`

### Project-specific
- `pipeline.py` — `gpu_stage` WORKLOAD to be replaced with actual workload
- `notebook.ipynb` — development notebook stub

---

## What Is Still Pending

- Replace `WORKLOAD` in `pipeline.py` with actual GPU body
- First pipeline run
- GPU profiling run

---

## Known Issues

None yet.

---

## Fixed Issues

*(fill in as issues are discovered and resolved)*

---

## Latest Profiling Finding

No profiling runs yet.
