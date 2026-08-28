# Validation Status — {{PROJECT_NAME}}

**Type:** KFP v2 RAG pipeline
**Qdrant collection:** `{{PROJECT_NAME}}`
**Platform:** Kubeflow Pipelines on NVIDIA DGX Spark (GB10, 128 GB unified memory)
**Last updated:** (fill in after first run)

---

## Current Status

| Component | Status |
|-----------|--------|
| `ingest_documents` | ✅ Implemented (template) |
| `retrieval_eval` | 🔲 USER CODE BLOCK — not yet implemented |
| `generation_eval` | 🔲 USER CODE BLOCK — not yet implemented |
| `faithfulness_eval` | 🔲 USER CODE BLOCK — not yet implemented |
| `safety_eval` | 🔲 USER CODE BLOCK — not yet implemented |
| `deployment_gate` | ✅ Implemented (template) |

**Project is in scaffolding phase.** Pipeline compiles; no runs have been executed yet.
See `WORKBOOK.md` for implementation order.

---

## Run Table

| Run | Purpose | Gate | recall@5 | faithfulness | safety | Key Finding |
|-----|---------|------|----------|--------------|--------|-------------|
| — | — | — | — | — | — | — |

> Update this table after each run.

---

## What Is Implemented

### Infrastructure (inherited from platform template)
- KFP v2 pipeline scaffold with all 6 stages wired
- MLflow run-per-stage tracking
- `ingest_documents` — chunking + embedding + Qdrant upsert (BAAI/bge-small-en-v1.5, CPU)
- `deployment_gate` — threshold checking for recall, faithfulness, relevancy, citation, safety
- `purge_kfp_mlflow.py`
- PVC mount: `hf-model-cache` at `/root/.cache/huggingface`
- Secret injection: `mlabs-api-keys` (OPENAI_API_KEY, HF_TOKEN, LANGCHAIN_API_KEY)

### Project-specific
- `config.yaml` — to be configured (llm.base_url, thresholds)
- `docs_src/` — domain documents to be added
- `eval_dataset.jsonl` — stub Q&A pairs to be replaced with real domain data
- `notebook.ipynb` — 4 USER CODE BLOCKs to be filled in per `WORKBOOK.md`

---

## What Is Still Pending

- Configure `config.yaml` (llm.base_url, llm.model, eval thresholds)
- Add documents to `docs_src/`
- Add Q&A rows to `eval_dataset.jsonl` (aim for ≥ 20)
- Implement all 4 pipeline step USER CODE BLOCKs
- First pipeline run — establish baseline RAG metrics

---

## Known Issues

None yet.

> **Platform-level fixes** (bitsandbytes on Blackwell, trl 0.29 API, PIP_CONSTRAINT, etc.) are not
> applicable to this project — all pipeline steps are CPU-only and use no training libraries.

---

## Fixed Issues

*(fill in as issues are discovered and resolved)*
