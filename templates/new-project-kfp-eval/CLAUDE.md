# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a KFP v2 **model bakeoff** on the Miramar platform (DGX Spark):
rank N candidate LLMs × M serving modes against K task harnesses, scored with
deterministic gates + a fixed LLM-as-judge.

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File | Purpose |
|------|---------|
| `config.yaml` | The matrix — `models`, `serving_modes`, `tasks`, `judge`, `gate_thresholds`, `score_weights`, `dataset` version, timeouts |
| `notebook.ipynb` | Source of truth — component + pipeline logic in `kfp_step` / `kfp_pipeline` cells |
| `pipeline.py` | Generated from the notebook — **do not edit manually** (gitignored) |
| `evallib/scoring.py` | Pure composite-math + ranking helpers — unit-tested under `tests/`, spliced into `judge_and_score` via `# inline:` |
| `evallib/rubric.py` | Pure judge prompt wrapper + tolerant response parser — same deal |
| `tests/` | `pytest` over `evallib/` only (no GPU, no cluster) |
| `scripts/build_pipeline.py` | Concatenate tagged cells → `pipeline.py`; resolves `# inline: evallib/<mod>.py` |
| `scripts/export_dataset.py` | LangSmith trace slice → `dataset/*.jsonl` + manifest → MinIO |
| `scripts/deploy_pipeline.py` | Build, compile, register, submit a run (Deploy to KFP workflow) |
| `scripts/terminate_pipeline.py` | Terminate a run by ID (Undeploy from KFP workflow) |
| `manifests/bakeoff-rbac.yaml` | RBAC for `serving_mode: guided` (transient vLLM Deployment) |
| `WORKBOOK.md` | The harness contract + step-by-step for adding a task / model / export spec |

## Slash commands

| Command | What it does |
|---------|-------------|
| `/kfp-deploy [run-NNN]` | Purge KFP, deploy next run |
| `/kfp-monitor [run-NNN]` | Self-paced monitoring loop — checks pods + MLflow |
| `/model-card [org/model-id]` | Fetch and display the HuggingFace model card |
| `/nsight-export <project> run-NNN main --adhoc [--duration N]` | Ad-hoc Nsight capture of a serving backend while a combo is GPU-hot → `~/shared/nsight/systems/<project>-<date>/` + auto `/nsight-interpret` |

**GPU profiling.** This bakeoff's GPU work runs on the host Ollama service or a transient
vLLM `Deployment` that `serve_model` creates directly — neither is a KFP task pod, so the
Nsight Operator's per-pod webhook has nothing to hook. `config.yaml`'s `profiling:` block
is kept for parity (`collection_window_s` only, no per-stage toggle). To profile a
candidate's serving backend, run `/nsight-export {{PROJECT_NAME}} run-NNN main --adhoc`
on the host while a combo is running.

Full docs: [miramar-platform-gcp/docs/kfp-skills.md](https://github.com/miramar-labs-org/miramar-platform-gcp/blob/main/docs/kfp-skills.md)

## The harness contract

Every task harness is a `kfp_step` component with **exactly** this signature:

```python
def <task>(cases: Input[Artifact], model_id: str, model_name: str, base_url: str,
           mode: str, run_id: str, gate_cfg: dict, case_timeout_s: int, runs_dir: str):
```

It must:
1. read `cases` (JSONL from `load_dataset`), keep rows where `row["task"] == "<task>"`;
2. `run_case(case)` → the model's structured output as a dict, **time-bounded by
   `case_timeout_s`** (pass it as the OpenAI client `timeout=` — GB10 silent-hang lesson);
3. `gates(case, output)` → `{gate_name: bool}` — deterministic, no model;
4. write one JSONL row per case to
   `<runs_dir>/<run_id>/<model_id-slug>__<mode>__<task>.jsonl`:
   `{model, mode, task, case_id, provenance, gate_pass, gates, output, reference, error}`
   (`model` = `model_id`, the config key — not the served name).

The judge runs later in `judge_and_score`; emit `output` + `reference` verbatim,
don't score in the harness. Register the component in `_HARNESSES` in the
Pipeline cell and add the task to `tasks:` / `gate_thresholds:` / `score_weights:`.

## Editing config.yaml

- **`models[]`** — `ollama_tag` required for `serving_mode: ollama`; `hf_id` +
  `quant` required for `serving_mode: guided`. `quant: fp8` on GB10 — **never nvfp4**.
- **`serving_modes`** — `models × serving_modes` combos run **serially** (one GPU).
- **`dataset.version`** — must point at an uploaded MinIO snapshot
  (`scripts/export_dataset.py`). `load_dataset` fails fast if the prefix is missing.
- **`judge.model`** — keep local (Ollama). Note self-grading bias if the judge is
  also a candidate.

After editing:
1. Run the **Build → `pipeline.py`** cell (or `python3 scripts/build_pipeline.py`).
2. Compile check (below).
3. Trigger **Deploy to KFP**.

## Component rules

- **All imports inside the function body** — each component runs in its own container.
- `packages_to_install` on `@dsl.component` is the only way to add deps.
- Only `serve_model` uses the GPU (via the vLLM Deployment it creates); the KFP
  components themselves are CPU-only — do NOT `.set_accelerator_type(...)`.
- Secret env vars (`OPENAI_API_KEY`, `HF_TOKEN`, `LANGCHAIN_API_KEY`) come from
  the `mlabs-api-keys` K8s secret via `k8s_ext.use_secret_as_env` in the pipeline cell.
- PVC `hf-model-cache` is mounted at `/root/.cache/huggingface`; run rows +
  `RUNS.md` live under `/root/.cache/huggingface/bakeoff-runs/`.
- `evallib/` is stdlib-only so it stays both `pytest`-importable and `# inline:`-spliceable.
- Every judge / model `chat.completions.create` call MUST pass `timeout=` — the
  judge shares unified memory with vLLM; an unbounded call hangs the component.

## Compile check

```sh
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

## Tests

```sh
pytest -q          # evallib/ only — safe anywhere
```

## KFP / MLflow access

```sh
ssh -L 8080:localhost:8080 -L 5000:localhost:5000 <user>@spark-79b7.local
# KFP    → http://localhost:8080
# MLflow → http://localhost:5000   (use ML experiment type, not GenAI apps & agents)
```

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
