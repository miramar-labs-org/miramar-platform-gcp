# {{PROJECT_NAME}}

[![Open in JupyterLab](https://img.shields.io/badge/Open%20in-JupyterLab-F37626?logo=jupyter&logoColor=white)]({{JL_URL}})  [![Deploy to KFP](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/deploy-to-kfp.yaml/badge.svg)](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/deploy-to-kfp.yaml)  [![Undeploy from KFP](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/undeploy-from-kfp.yaml/badge.svg)](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/undeploy-from-kfp.yaml)

| | |
| ----------- | -------------------------------------------------------------------- |
| **Type**    | KFP v2 model bakeoff (eval + rank)                                  |
| **Host**    | {{PROJECT_HOST}}                                                     |

{{DESCRIPTION}}

---

## 1. What this is

A repeatable **model bakeoff**: run every candidate LLM in `config.yaml` under
every serving mode against a frozen set of task cases, score each output with
deterministic **gates** + a fixed **LLM-as-judge** (1–5), and rank
`(model, mode)` by a weighted composite. The winner is logged to MLflow and
appended to `runs/RUNS.md`.

Nothing here is task-specific — you supply the task **harnesses** (what to send
the model, what a good answer looks like) and the frozen **dataset**.

**DAG:**
```
load_dataset
  → for each (model, mode) in models × serving_modes   [SERIAL — one GPU]:
        serve_model → <harness> × tasks → teardown_model
  → judge_and_score → report   (MLflow + runs/RUNS.md)
```

The matrix is unrolled from `config.yaml` at build time. Combos run serially
because the box has one GPU and Ollama pins a single resident model.

---

## 2. Quick start

1. **Freeze a dataset.** Fill in `langsmith.project` + `langsmith.export[]` in
   `config.yaml`, then:
   ```sh
   LANGCHAIN_API_KEY=...  python3 scripts/export_dataset.py --version v$(date +%Y%m%d)
   ```
   Set the resulting `dataset.version` in `config.yaml`.
2. **Add a harness.** Copy the `example_harness` cell in `notebook.ipynb`, rename
   it, rewrite `run_case` / `gates`, register it in `_HARNESSES` (Pipeline cell),
   and add it to `tasks:` / `gate_thresholds:` / `score_weights:`. See `WORKBOOK.md`.
3. **List candidates.** Add entries to `models:` (`ollama_tag` for `ollama` mode,
   `hf_id` + `quant` for `guided` mode).
4. **Build.** Run the **Build → `pipeline.py`** cell (or `python3 scripts/build_pipeline.py`).
5. **Deploy.** Trigger **Deploy to KFP** from the Actions tab.
   For `serving_modes: [guided]`, first `kubectl apply -f manifests/bakeoff-rbac.yaml`.

---

## 3. config.yaml reference

| Key | Type | Description |
|-----|------|-------------|
| `models[].id` | string | Leaderboard key — unique |
| `models[].ollama_tag` | string | `ollama pull` target (serving_mode `ollama`) |
| `models[].hf_id` | string | HF repo (serving_mode `guided`, vLLM) |
| `models[].quant` | string | vLLM `--quantization` (`fp8` on GB10 — never nvfp4) |
| `serving_modes` | list | Subset of `[ollama, guided]` |
| `tasks` | list | Harness names — each needs a cell + `_HARNESSES` entry |
| `dataset.s3_endpoint_url` | string | MinIO S3 endpoint (in-cluster default pre-filled) |
| `dataset.bucket` | string | Bucket holding `datasets/<version>/` |
| `dataset.version` | string | Dated snapshot dir, e.g. `v20260828` |
| `dataset.access_key` / `secret_key` | string | MinIO creds (platform dev defaults pre-filled) |
| `judge.model` | string | Fixed judge model (keep local — Ollama) |
| `judge.base_url` | string | Judge endpoint |
| `gate_thresholds.<task>` | map | Deterministic pass/fail knobs read by that harness's `gates()` |
| `score_weights.<task>.gate_pass` | float | Weight on gate-pass rate (normalized per task) |
| `score_weights.<task>.judge` | float | Weight on mean judge score |
| `case_timeout_s` | int | Hard cap per model call — bounds every agentic loop |
| `serving.ollama_base_url` | string | Shared Ollama `/v1` |
| `serving.guided_*` / `vllm_*` | — | Transient vLLM Deployment knobs |
| `langsmith.project` | string | LangSmith project `export_dataset.py` reads |
| `langsmith.export[]` | list | One `{task, run_filter, limit, input_path, output_path}` per task |

---

## 4. Dataset format

`scripts/export_dataset.py` writes `dataset/<task>.jsonl` — one case per line:
```json
{"case_id": "analyst_universe-000", "provenance": "real",
 "inputs": {"prompt": "..."}, "reference": {"...": "..."}}
```
plus `dataset/manifest.json` (counts, date range, source run ids). Both are
uploaded to `s3://<bucket>/datasets/<version>/`. `load_dataset` reads them back
at run time. `provenance: "synthetic"` cases are run and judged but excluded
from the real-case counts.

---

## 5. Results

- **MLflow** — `report` logs `winner_model`, `winner_mode`, `winner_composite`,
  a `composite::<model>::<mode>` metric per combo, and the `leaderboard.md` /
  `leaderboard.json` artifacts. Use the **ML** experiment type.
  ```sh
  ssh -L 5000:localhost:5000 <user>@spark-79b7.local   # → http://localhost:5000
  ```
- **`runs/RUNS.md`** — a dated winner block + leaderboard table appended per run
  (on the PVC at `/root/.cache/huggingface/bakeoff-runs/RUNS.md`).

---

## 6. Kubeflow Pipelines UI

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local   # → http://localhost:8080
```

Prerequisites: **Kubeflow Deploy** + **MLflow Deploy** must be running. Trigger
them in [miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
if unreachable.
