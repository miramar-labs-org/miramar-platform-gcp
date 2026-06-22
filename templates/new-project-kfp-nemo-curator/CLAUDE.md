# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a KFP v2 NeMo Curator data-curation pipeline on the Miramar platform (DGX Spark).

## Key files

| File | Purpose |
|------|---------|
| `config.yaml` | Project config — input format, quality thresholds, dedup settings, PII entity list |
| `data_src/` | Raw source documents to curate (.txt, .md, .html, .jsonl); copied to PVC by `scripts/deploy_pipeline.py` |
| `notebook.ipynb` | Source of truth — develop step logic here, run the Build cell to regenerate `pipeline.py` |
| `pipeline.py` | Generated from notebook — **do not edit manually** (gitignored) |
| `WORKBOOK.md` | Implementation guide — every `USER CODE BLOCK` to fill in, with order and code examples |
| `scripts/deploy_pipeline.py` | Copy data_src/ to PVC, compile, register, and submit a run (called by Deploy to KFP workflow) |
| `scripts/terminate_pipeline.py` | Terminate a run by ID (called by Undeploy from KFP workflow) |

## Slash commands

| Command | What it does |
|---------|-------------|
| `/kfp-deploy [run-NNN]` | Purge KFP, deploy next run |
| `/kfp-monitor [run-NNN]` | Self-paced monitoring loop — checks pods + MLflow |

## Pipeline data flow

All data stages live under PVC `hf-model-cache` at `/root/.cache/huggingface/`:

```
curator-input/{{PROJECT_NAME}}/raw/              ← staged from data_src/ by deploy_pipeline.py
curator-input/{{PROJECT_NAME}}/extracted/        ← output of extract_text
curator-input/{{PROJECT_NAME}}/quality_filtered/ ← output of quality_filter
curator-input/{{PROJECT_NAME}}/deduped/          ← output of deduplication
curator-input/{{PROJECT_NAME}}/curated/          ← final output of pii_redaction
curator-output/{{PROJECT_NAME}}/{run_id}/curation_report.json ← written by curator_report
```

## Component rules

- **All imports must be inside the function body** — each component runs in its own container
- `packages_to_install` on `@dsl.component` is the only way to add dependencies
- **CPU components** (`preflight_check`, `extract_text`, `pii_redaction`, `curator_report`): use `python:3.11-slim`
- **GPU components** (`quality_filter`, `deduplication`): use `nvcr.io/nvidia/pytorch:26.04-py3` + RAPIDS packages
- GPU components MUST include in `packages_to_install`:
  ```python
  "--extra-index-url=https://pypi.nvidia.com",
  "nemo-curator[cuda12x]>=0.5.0",
  ```
- GPU components MUST have `.set_accelerator_type("nvidia.com/gpu").set_accelerator_limit(1).set_memory_limit("48G")` in the pipeline cell
- Secret env vars (`OPENAI_API_KEY`, `HF_TOKEN`) injected from `mlabs-api-keys` K8s secret via `k8s_ext.use_secret_as_env`
- PVC `hf-model-cache` is mounted at `/root/.cache/huggingface`

## Editing config.yaml

After editing `config.yaml`:
1. Open `notebook.ipynb` and run the **Build → `pipeline.py`** cell
2. Compile check: `python3 -c "from kfp import compiler; from pipeline import pipeline; compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"`
3. Trigger **Deploy to KFP**

## Compile check

```sh
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

## KFP UI access

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# → http://localhost:8080
```

## MLflow access

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
# → http://localhost:5000  (use ML experiment type, not GenAI apps & agents)
```

## GPU wheel fallback

If `nemo-curator[cuda12x]` pip wheels are unavailable for arm64 (aarch64), see
`WORKBOOK.md → GPU wheel fallback` for the custom image approach.

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
