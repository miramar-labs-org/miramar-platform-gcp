# Validation Status — {{PROJECT_NAME}}

**Model/Task:** {{DESCRIPTION}}
**Platform:** Kubeflow Pipelines on NVIDIA DGX Spark (GB10, 128 GB unified memory)
**Last updated:** {{DATE}}

---

## Current Status

| Component | Status |
|---|---|
| `gpu_stage` | 🔲 Not yet run |

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
- `purge_kfp_mlflow.py`
- Nsight Operator integration — add `kubernetes.add_pod_label(task, "nvidia-nsight-profile", "enabled")` to profile any stage

### Project-specific
- `pipeline.py` — `gpu_stage` WORKLOAD to be replaced with actual workload
- `notebook.ipynb` — development notebook stub

---

## What Is Still Pending

- Replace `gpu_stage` stub in `pipeline.py` with actual GPU body
- First pipeline run

---

## Known Issues

None yet.

---

## Fixed Issues

*(fill in as issues are discovered and resolved)*

---

## Latest Nsight Finding

No profiling runs yet.
