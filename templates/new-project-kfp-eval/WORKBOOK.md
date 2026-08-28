# WORKBOOK — {{PROJECT_NAME}}

How to turn this template into a real bakeoff. Order matters: dataset → harness →
models → run. After each change: **Build → `pipeline.py`** cell, then the compile
check.

---

## 0. Prerequisites

- [ ] KFP + MLflow/MinIO running on the DGX (platform **Kubeflow Deploy** /
      **MLflow Deploy** workflows).
- [ ] `LANGCHAIN_API_KEY` in the `mlabs-api-keys` K8s secret (platform-provisioned)
      and in your shell for `scripts/export_dataset.py`.
- [ ] `pytest -q` green out of the box (`evallib/` unit tests).

---

## 1. Freeze the dataset

`scripts/export_dataset.py` turns a LangSmith trace slice into the frozen eval
set. Configure one `export` spec per task in `config.yaml`:

```yaml
langsmith:
  project: "my-langsmith-project"
  export:
    - task: analyst_universe
      run_filter: 'eq(name, "analyst_universe")'   # LangSmith filter DSL
      limit: 20
      input_path: "inputs"        # dotted path into the run dict → case inputs
      output_path: "outputs"      # dotted path into the run dict → reference
```

```sh
# dry run — just list what matches
python3 scripts/export_dataset.py --version v$(date +%Y%m%d) --dry-run

# write ./dataset/*.jsonl + manifest.json, upload to MinIO
LANGCHAIN_API_KEY=...  python3 scripts/export_dataset.py --version v$(date +%Y%m%d)
```

Then set `dataset.version` in `config.yaml` to that `v<date>`.

- Each `dataset/<task>.jsonl` line: `{case_id, provenance, inputs, reference}`.
- Thin on real cases? Hand-write extra lines with `"provenance": "synthetic"` —
  they're run + judged but excluded from `n_real`.
- Verify: every `<task>.jsonl` non-empty; `manifest.json` counts match.

---

## 2. Add a task harness

The `example_harness` cell is the reference. To add task `foo`:

1. **Copy the `example_harness` cell** (keep the `kfp_step` tag).
2. Rename the function to `foo` and set `TASK = "foo"`.
3. Rewrite **`run_case(case)`** — build the prompt from `case["inputs"]`, call the
   model (`client` is already wired to the served candidate), return the parsed
   structured output as a dict. Keep `timeout=case_timeout_s` on the call.
4. Rewrite **`gates(case, output)`** — return `{gate_name: bool}`. Deterministic
   only, no model. Read thresholds from `gate_cfg` (that's
   `config.yaml → gate_thresholds.foo`).
5. Leave the row-writing loop as-is — it already emits the contract schema and
   the judge scores later.

Then:
- **Pipeline cell** — add `"foo": foo` to `_HARNESSES`.
- **config.yaml** — add `foo` to `tasks:`, a `gate_thresholds.foo:` block, and a
  `score_weights.foo: {gate_pass, judge}` block.

### The harness contract (enforced by `_HARNESSES` + the pipeline)

```python
@dsl.component(base_image="python:3.11-slim", packages_to_install=["openai>=1.0"])
def foo(cases: Input[Artifact], model_id: str, model_name: str, base_url: str,
        mode: str, run_id: str, gate_cfg: dict, case_timeout_s: int, runs_dir: str):
    ...
```

Row written per case (one JSON object per line):
```json
{"model": "<model_id>", "mode": "ollama", "task": "foo", "case_id": "foo-000",
 "provenance": "real", "gate_pass": true, "gates": {"...": true},
 "output": {...}, "reference": {...}, "error": null}
```

`model` is the **config `id`**, not the served name. `output` + `reference` are
handed to the judge verbatim in `judge_and_score` — don't score in the harness.

---

## 3. List the candidates

```yaml
models:
  - id: qwen3.6-35b-a3b
    ollama_tag: "qwen3.6:35b-a3b"      # serving_mode: ollama
  - id: qwen3.8-27b
    ollama_tag: "qwen3.8:27b"
    hf_id: "Qwen/Qwen3.8-27B"          # serving_mode: guided (vLLM)
    quant: "fp8"                        # fp8 on GB10 — never nvfp4
serving_modes: [ollama]                 # add `guided` for the vLLM path
```

`models × serving_modes` combos run **serially**. For `guided`:
`kubectl apply -f manifests/bakeoff-rbac.yaml` once (grants the KFP SA
deployments/services in `kubeflow`).

---

## 4. Tune scoring

```yaml
gate_thresholds:
  foo: { min_output_keys: 3 }          # whatever gates() reads

score_weights:
  foo: { gate_pass: 0.6, judge: 0.4 }  # normalized per task before the composite
```

`task_score` = `gate_pass_rate` weighted with `judge_mean_unit` (1–5 → 0–1). A
task with no parseable judge scores falls back to `gate_pass_rate` alone. The
per-(model, mode) **composite** is the mean of its per-task scores.

---

## 5. Build, check, run

```sh
python3 scripts/build_pipeline.py
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
pytest -q

git add notebook.ipynb config.yaml && git commit -m "feat: <task> harness + candidates"
git push

python3 scripts/purge_kfp_mlflow.py            # runs/pipelines persist across deploys
gh workflow run deploy-to-kfp.yaml --field run_name=run-001
```

---

## 6. Read the result

- **`/root/.cache/huggingface/bakeoff-runs/RUNS.md`** on the PVC — a dated winner
  block + leaderboard table appended per run.
- **MLflow** (`report` run, ML experiment type) — `winner_*` params,
  `composite::<model>::<mode>` metrics, `leaderboard.md` / `leaderboard.json`.
- Per-case rows: `/root/.cache/huggingface/bakeoff-runs/<run_id>/*.jsonl`.
