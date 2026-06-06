# KFP Slash Commands

Two Claude Code slash commands cover the full run lifecycle for any project scaffolded from the
`kfp-ft-eval` template. Both auto-detect the project from the current directory.

---

## `/kfp-deploy [run-name] [--flags]`

**Purges KFP state, deploys a new run, and creates the status log file.**

```bash
# Auto-increment run number, no profiling
/kfp-deploy

# Explicit run name
/kfp-deploy run-021

# Profile baseline eval step only
/kfp-deploy run-021 --profile-baseline

# Profile fine-tune step only
/kfp-deploy run-021 --profile-finetune

# Profile both steps (shorthand)
/kfp-deploy run-021 --profile-nsight
```

Steps it performs:
1. Determines the next run name (auto-increments from `runs/run-NNN.md`, or uses the argument)
2. Checks for active pods — asks for confirmation before purging if any are Running
3. Runs `python3 scripts/purge_kfp.py`
4. Runs `python3 scripts/deploy_pipeline.py --run-name <run-name> [flags]`
5. Creates `runs/<run-name>.md` with the KFP Run ID, start time, and profile flags pre-filled

After this finishes, invoke `/kfp-monitor <run-name>` to start the monitoring loop.

---

## `/kfp-monitor [run-name]`

**Monitors a running pipeline — checks pods, logs, and MLflow; appends timestamped entries to
`runs/run-NNN.md` until the pipeline completes or fails.**

```bash
# Monitor the latest run (auto-detects from runs/)
/kfp-monitor

# Monitor a specific run
/kfp-monitor run-021
```

What it checks each tick:
1. `kubectl get pods -n kubeflow | grep <project-name>` — pod state
2. Running pod logs — progress lines, errors, accuracy output
3. MLflow REST API — `running_accuracy` step metrics and final metrics for `run-NNN*` entries

MLflow UI for live charts: **http://localhost:5000**

Adaptive cadence:

| Phase | Interval |
|---|---|
| Model loading (no `Progress:` yet) | 5 min |
| Inference < 50% | 20 min |
| Inference 50–80% | 10 min |
| Inference > 80% | 5 min |
| Between pipeline stages | 2 min |

Stops automatically when all pods reach Completed or any pod reaches Error/Failed.

---

## Typical workflow

```bash
cd ~/git-miramar-labs-org/projects/my-kfp-project

/kfp-deploy run-021
# → purges, deploys, creates runs/run-021.md

/kfp-monitor run-021
# → monitoring loop starts; open http://localhost:5000 for live MLflow charts
```

---

## Run log format (`runs/run-NNN.md`)

Each run gets a file in the git-ignored `runs/` directory:

```
# run-021 — Status Log

**KFP Run ID:** `<uuid>`
**Started:** 2026-06-07 10:00 PDT
**Profile flags:** none
**KFP UI:** http://localhost:8080/#/runs/details/<uuid>

Changes from previous run:
- ...

## Status Updates

### 10:05 PDT — baseline_eval running, model loading
- Pods: 1 Running, 4 Completed
- Progress: model loading (~17 min for 27B)
- MLflow: no entries yet
```

`runs/RUNS.md` (also git-ignored) is the cumulative run history — update it manually after each
run completes with outcome, accuracy, and any notable changes.

---

## `/model-card [org/model-id]`

**Fetches and displays the HuggingFace model card for the project's base model.**

```bash
# Show card for the model in config.yaml
/model-card

# Look up any model directly
/model-card google/medgemma-27b-it
/model-card meta-llama/Llama-3.1-70B-Instruct
```

Reads `base_model_id` from `config.yaml` when no argument is given. For long cards
(>300 lines), shows a summary first — description, benchmarks table, inference
settings — then offers the full card on request.

---

## `/nsight-interpret [report | run-NNN] [--ollama model]`

**Extracts Nsight Systems profiling summaries and sends them to an LLM for bottleneck
analysis — no manual reading of `.nsys-rep` files required.**

```bash
# Auto-detect latest report in the project's nsight-reports directory
/nsight-interpret

# Report from a specific run
/nsight-interpret run-021

# Direct path
/nsight-interpret /nsight-reports/my-project/run-021/baseline.nsys-rep

# Use a local Ollama model instead of Claude API
/nsight-interpret run-021 --ollama llama3
```

What it does:
1. Locates the `.nsys-rep` file (argument → run name → latest auto-detected)
2. Runs `nsys stats` for five report types: `cuda_gpu_kern_sum`, `cuda_api_sum`,
   `cuda_gpu_mem_time_sum`, `cuda_gpu_mem_size_sum`, `nvtx_sum`
3. Sends the extracted tables to an LLM with a GPU optimization system prompt
4. Returns a structured analysis covering:
   - Top 3 bottlenecks (ranked by % of total time)
   - GPU idle / underutilization gaps
   - Memory transfer overhead vs compute time
   - NVTX stage breakdown (if annotations present)
   - Prioritized recommended next steps
   - What's already well-optimized

**LLM backends:**
- Claude Code skill (`/nsight-interpret`): uses `claude-opus-4-8` by default
- Codex skill (`/nsight-interpret`): uses `gpt-4o` by default
- Both accept `--ollama <model>` to use a local model via Ollama instead

**Prerequisites:** `nsys` must be installed and on `PATH`; the `.nsys-rep` file must
be readable from the current machine (not inside a pod).

---

## Prerequisites

- KFP running on DGX (`kubeflow` namespace) — deploy via `deploy-kubeflow.yaml` workflow
- `scripts/purge_kfp.py` and `scripts/deploy_pipeline.py` present (scaffolded by template)
- `runs/` directory exists (created by template or first `/kfp-deploy`)
- MLflow accessible at `localhost:5000`
