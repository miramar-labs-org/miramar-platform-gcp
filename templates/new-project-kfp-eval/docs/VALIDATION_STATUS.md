# Validation Status — {{PROJECT_NAME}}

**Type:** KFP v2 model bakeoff (eval + rank)
**Platform:** Kubeflow Pipelines on NVIDIA DGX Spark (GB10, 128 GB unified memory)
**Last updated:** (fill in after first run)

---

## Current Status

| Component | Status |
|-----------|--------|
| `load_dataset` | ✅ Implemented (template) |
| `serve_model` | ✅ Implemented — `ollama` + `guided` |
| `teardown_model` | ✅ Implemented (template) |
| `example_harness` | ✅ Reference harness (template) — replace with real tasks |
| `judge_and_score` | ✅ Implemented (template) — `evallib/` spliced via `# inline:` |
| `report` | ✅ Implemented (template) — MLflow + `RUNS.md` |

**Project is in scaffolding phase.** Pipeline compiles with the example harness;
no bakeoff runs executed yet. See `WORKBOOK.md`.

---

## Run Table

| Run | Dataset | Combos | Winner | Composite | Key Finding |
|-----|---------|--------|--------|-----------|-------------|
| — | — | — | — | — | — |

> Update after each run (also auto-appended to `bakeoff-runs/RUNS.md` on the PVC).

---

## What Is Implemented

### Infrastructure (inherited from platform template)
- KFP v2 pipeline scaffold; `models × serving_modes` matrix unrolled from `config.yaml`, serial.
- `load_dataset` — pulls the frozen snapshot from MinIO (`s3://<bucket>/datasets/<version>/`).
- `serve_model` / `teardown_model` — `ollama` evict/preload; `guided` transient vLLM Deployment (xgrammar, fp8).
- `judge_and_score` — fixed 1–5 LLM-judge + weighted composite ranking.
- `report` — MLflow run + `RUNS.md` winner block.
- `evallib/scoring.py` + `evallib/rubric.py` — pure, unit-tested, `# inline:`-spliced.
- PVC mount `hf-model-cache` at `/root/.cache/huggingface`; secret injection `mlabs-api-keys`.

### Project-specific (to be supplied)
- `config.yaml` — `models`, `serving_modes`, `tasks`, `gate_thresholds`, `score_weights`, `dataset.version`.
- Task harness cells in `notebook.ipynb` (copy `example_harness`).
- Frozen dataset via `scripts/export_dataset.py`.

---

## What Is Still Pending

- Configure `config.yaml` (candidates, tasks, thresholds, dataset version).
- Freeze a dataset and upload to MinIO.
- Add the real task harnesses; register in `_HARNESSES`.
- For `guided` mode: `kubectl apply -f manifests/bakeoff-rbac.yaml`.
- First bakeoff run — establish the baseline leaderboard.

---

## Known Issues

None yet.

---

## Fixed Issues

*(fill in as issues are discovered and resolved)*
