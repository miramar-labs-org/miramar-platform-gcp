# Validation Status — {{PROJECT_NAME}}

**Type:** KFP v2 NeMo Curator data-curation pipeline
**Platform:** Kubeflow Pipelines on NVIDIA DGX Spark (GB10, 128 GB unified memory)
**Last updated:** (fill in after first run)

---

## Current Status

| Component | Status |
|-----------|--------|
| `preflight_check` | ✅ Implemented (template) |
| `extract_text` | 🔲 USER CODE BLOCK — not yet implemented |
| `quality_filter` | 🔲 USER CODE BLOCK — not yet implemented |
| `deduplication` | 🔲 USER CODE BLOCK — not yet implemented |
| `pii_redaction` | 🔲 USER CODE BLOCK — not yet implemented |
| `curator_report` | ✅ Implemented (template) |

**Project is in scaffolding phase.** Pipeline compiles; no runs have been executed yet.
See `WORKBOOK.md` for implementation order.

---

## Run Table

| Run | Purpose | docs_in | quality_filtered | deduped | curated | Key Finding |
|-----|---------|---------|-----------------|---------|---------|-------------|
| — | — | — | — | — | — | — |

> Update this table after each run.

---

## What Is Implemented

### Infrastructure (inherited from platform template)
- KFP v2 pipeline scaffold with all 6 stages wired
- MLflow per-stage metric logging
- `preflight_check` — input dir validation, file count, total bytes
- `curator_report` — final doc count, word count, mean doc length; writes `curation_report.json`
- `purge_kfp_mlflow.py`
- PVC mount: `hf-model-cache` at `/root/.cache/huggingface`
- Secret injection: `mlabs-api-keys` (OPENAI_API_KEY, HF_TOKEN)
- GPU acceleration configured: `quality_filter` and `deduplication` request `nvidia.com/gpu`

### Project-specific
- `config.yaml` — to be configured (input format, quality thresholds, PII entities)
- `data_src/` — source documents to be added
- `notebook.ipynb` — 4 USER CODE BLOCKs to be filled in per `WORKBOOK.md`

---

## What Is Still Pending

- Add source documents to `data_src/`
- Configure `config.yaml` (input format, quality thresholds)
- Implement all 4 pipeline step USER CODE BLOCKs
- Verify arm64 RAPIDS wheel availability (see `WORKBOOK.md → GPU wheel fallback`)
- First pipeline run — establish baseline curation metrics

---

## Known Issues

None yet.

---

## Fixed Issues

*(fill in as issues are discovered and resolved)*
