# KFP Slash Commands

Two Claude Code slash commands cover the full run lifecycle for any project scaffolded from the
`ft-eval` template. Both auto-detect the project from the current directory.

---

## `/kfp-deploy [run-name] [--chunk-index N] [--flags]`

**Purges KFP state, deploys a new run, and creates the status log file.**

```bash
# Auto-increment run number
/kfp-deploy

# Explicit run name
/kfp-deploy run-021

# Multi-chunk run — deploy data slice N (0-based); KFP/MLflow run name becomes run-021-{N+1}
/kfp-deploy run-021 --chunk-index 2
```

`--chunk-index N` is only used when `chunking.enabled: true` and `total_chunks > 1` in `config.yaml`.
The log file is always `runs/run-NNN.md` (never chunk-suffixed). Purge is skipped for `chunk-index > 0`
to preserve MinIO artifacts from earlier chunks.

`--profile-<stage>` flags (`--profile-baseline`, `--profile-finetune`, `--profile-postft`,
`--profile-safety`, `--profile-baseline-safety`, `--profile-nsight` = baseline + finetune) patch
`config.yaml`'s `profiling:` block and regenerate `pipeline.py` so the operator injects `nsys` on
that stage. `/kfp-monitor` then drives `/nsight-export` during the stage's GPU-hot window. See
[Nsight Profiling in KFP](#nsight-profiling-in-kfp).

The 8-stage pipeline: `download_model` → `prepare_dataset` → `baseline_eval` + `baseline_safety_eval`
→ `fine_tune` → `post_finetune_eval` + `safety_eval` → `deployment_gate`. `download_model`,
`prepare_dataset`, and `deployment_gate` are fully implemented by the template.

Steps it performs:
1. Determines the next run name (auto-increments from `runs/run-NNN.md`, or uses the argument)
2. Checks for active pods — asks for confirmation before purging if any are Running
3. Runs `python3 scripts/purge_kfp_mlflow.py`
4. Runs `python3 scripts/deploy_pipeline.py --run-name <run-name>`
5. Creates `runs/<run-name>.md` with the KFP Run ID and start time

After this finishes, invoke `/kfp-monitor <run-name>` to start the monitoring loop.

---

---

## Optional integrations

### Weights & Biases

The `ft-eval` template has built-in, opt-in W&B support. Enable it in `config.yaml`:

```yaml
wandb:
  enabled: true
  project: "my-project"   # W&B project name
  entity: ""              # W&B team/org (leave blank for personal account)
```

`WANDB_API_KEY` is already injected into KFP pods from the `mlabs-api-keys` K8s secret — no
additional setup required. When enabled:

- **`fine_tune`** — calls `wandb.init()` before training and logs step metrics (loss, grad_norm,
  lr, token accuracy) via `report_to=["mlflow", "wandb"]` in `SFTConfig`. Calls `wandb.finish()`
  after the MLflow log block.
- **`deployment_gate`** — logs a final summary run (`baseline_accuracy`, `postft_accuracy`,
  `accuracy_delta`, `baseline_safety_score`, `safety_score`, `gate_pass`) before the pass/fail
  check. Errors are caught and printed — the gate result is unaffected.

W&B is fully opt-in. Both components behave identically when `wandb.enabled: false` (the default).

### Slack notifications

`/kfp-monitor` sends a one-line Slack summary on every terminal pipeline completion (PASS or FAIL).
Set the webhook URL once in `~/.zshrc`:

```bash
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

Example messages:
```
✅ *PASS* — biomistral-7b-onc / run-001
Accuracy: 0.45 → 0.52 (+15.6%)
Safety: 4.5 → 4.6 (+0.1)
Train loss: 0.82 | MLflow: http://localhost:5000

❌ *FAIL* — biomistral-7b-onc / run-001
Accuracy: 0.45 → 0.41 (−8.9%) ✗
Safety: 4.5 → 4.6 ✓
```

Fires on every chunk terminal completion for chunked runs, not just the last. Degrades silently
if `SLACK_WEBHOOK_URL` is unset or if the `curl` POST fails.

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

| Phase                              | Interval |
| ---------------------------------- | -------- |
| Model loading (no `Progress:` yet) | 5 min    |
| Inference < 50%                    | 20 min   |
| Inference 50–80%                   | 10 min   |
| Inference > 80%                    | 5 min    |
| Between pipeline stages            | 2 min    |

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

Each run gets a file in the `runs/` directory (git-tracked):

```
# run-021 — Status Log

**KFP Run ID:** `<uuid>`
**Started:** 2026-06-07 10:00 PDT
**KFP UI:** http://localhost:8080/#/runs/details/<uuid>

Changes from previous run:
- ...

## Status Updates

### 10:05 PDT — baseline_eval running, model loading
- Pods: 1 Running, 4 Completed
- Progress: model loading (~17 min for 27B)
- MLflow: no entries yet
```

`runs/RUNS.md` is the cumulative run history — update it manually after each run completes
with outcome, accuracy, and any notable changes. Both files are git-tracked.

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

## Nsight Profiling in KFP

GPU stages are profiled with the **NVIDIA Nsight Operator**: labelling a stage pod
`nvidia-nsight-profile=enabled` makes the operator inject an `nsys` process hook. The
operator writes the finished `.nsys-rep` **only to its internal MinIO** (namespace
`nsight-operator`, bucket `nsight-reports`) — nothing lands on disk automatically.

**`~/bin/nsight-export-report` / `/nsight-export`** is the bridge: it drives an Nsight
Operator *coordinator session*, pulls the report out of MinIO, verifies it, and writes it
to `~/shared/nsight/<project>/<run-id>/<stage>/profile.nsys-rep` with a `profile.json`
metadata sidecar and a `summaries.csv` for `/nsight-interpret`. The coordinator REST API
is reached at `http://localhost:13001/api/v1/` on the DGX host (forwarded by
`nsight-portfwd.service`; `:8889` is the web UI / SPA only).

> **MinIO is the operator's internal report storage. `~/shared/nsight` is the durable,
> human-facing profiling archive.**

**Turning profiling on** — set the per-stage toggle in the project's `config.yaml`
`profiling:` block (keys are the hyphenated KFP component names, e.g. `baseline-eval`,
`fine-tune`), or pass a `--profile-<stage>` flag to `/kfp-deploy` (which patches the block
and regenerates `pipeline.py`). `collection_window_s` bounds the `nsys` collection.

Full profiling arc:

```bash
/kfp-deploy run-032 --profile-baseline      # label baseline-eval, record it in runs/run-032.md
/kfp-monitor run-032                         # drives ~/bin/nsight-export-report in the background
                                             # when baseline-eval goes Running, then auto-runs
                                             # /nsight-interpret on the archived report
```

If the GPU-hot window is missed, run the export by hand while the stage is still busy:

```bash
/nsight-export <project> run-032 baseline-eval [--duration 120]
```

### `/nsight-export <project> <run-NNN> <stage> [--duration N] [--tool systems|compute] [--adhoc]`

**Archives an Nsight Operator report from MinIO into `~/shared/nsight/<project>/<run-id>/<stage>/`
and auto-chains `/nsight-interpret`.**

```bash
# Standard: derive KFP/MLflow linkage from runs/<run-NNN>.md, drive a fresh collection
/nsight-export my-project run-032 baseline-eval

# Wider collection window (default 90s from config.yaml)
/nsight-export my-project run-032 fine-tune --duration 180

# Ad-hoc capture (no KFP run) — lands under ~/shared/nsight/systems/<project>-<date>/
/nsight-export my-project run-000 main --adhoc

# Export an already-collected MinIO report by id (no new collection)
/nsight-export my-project run-032 baseline-eval --no-collect --report-id <uuid>
```

What it does:
1. Parses args (`<project>` falls back to `basename $(pwd)`); reads `runs/<run-NNN>.md` for
   the KFP Run ID and derives the MLflow run name from a stage→suffix map
2. Sanity-checks the target stage pod is `Running` (collection must happen while its GPU
   work is hot)
3. Runs `~/bin/nsight-export-report` — `POST /sessions` → `POST /collect` → poll →
   `GET /files` → pull from MinIO (`curl --aws-sigv4`) → verify (`nsys stats` returns ≥1
   GPU kernel row) → write `profile.nsys-rep` + `profile.json` + `summaries.csv` +
   `nsys_stats.txt` + `.sha256` → `DELETE /sessions/{sid}`
4. Tags the stage's MLflow run with `nsight_report_path` / `nsight_report_sha256` /
   `nsight_operator_session_id` / `nsight_report_dir`
5. Auto-chains `/nsight-interpret <project> <run-NNN>` → produces `analysis-claude.md`
6. Appends `- Nsight report (<stage>): <path>` to `runs/<run-NNN>.md`

**Prerequisites:** Nsight Operator deployed (`deploy-nsight-operator.yaml`);
`nsight-portfwd.service` forwarding `:13001`; MinIO credentials readable from the
`nsight-operator-cloud-storage-minio-credentials` secret (read at runtime — never
hardcoded); `nsys`, `kubectl`, `curl`, `jq` on `PATH`. Fails loudly (non-zero exit) if the
coordinator is unreachable, the `default` session tag is busy, or the report cannot be
verified — it will not report success when no report was retrieved.

### `/nsight-interpret <project-name> <run-NNN> [--ollama model]`

**Extracts Nsight Systems profiling summaries and sends them to an LLM for bottleneck
analysis — no manual reading of `.nsys-rep` files required.**

```bash
# Specific project + run (standard usage from any directory)
/nsight-interpret my-project run-021

# Use a local Ollama model instead of Claude/OpenAI API
/nsight-interpret my-project run-021 --ollama qwen3-coder:30b

# Direct path (no project name needed)
/nsight-interpret ~/shared/nsight/my-project/run-021/main/profile.nsys-rep

# Auto-detect: if only run-NNN given, project inferred from basename $(pwd)
/nsight-interpret run-021
```

What it does:
1. Locates the `.nsys-rep` under `$HOME/shared/nsight/<project-name>/<run-id>/`
2. Reads pre-generated `summaries.csv` if present; otherwise runs `nsys stats` for five report
   types: `cuda_gpu_kern_sum`, `cuda_api_sum`, `cuda_gpu_mem_time_sum`, `cuda_gpu_mem_size_sum`,
   `nvtx_sum` and saves the result to `summaries.csv`
3. Sends the extracted tables to an LLM with a GPU optimization system prompt
4. Returns a structured analysis covering:
   - Top 3 bottlenecks (ranked by % of total time)
   - GPU idle / underutilization gaps
   - Memory transfer overhead vs compute time
   - NVTX stage breakdown (if annotations present)
   - Prioritized recommended next steps
   - What's already well-optimized
5. Saves to `analysis-claude.md` / `analysis-codex.md` / `analysis-ollama-<model>.md` alongside
   the `.nsys-rep` file, and appends a reference line to `runs/<run-NNN>.md`

**LLM backends:**
- Claude Code skill (`/nsight-interpret`): uses `claude-opus-4-8` by default; auto-falls back to
  local Ollama (`qwen3-coder:30b`) if the API key is exhausted or unavailable
- Codex skill (`/nsight-interpret`): uses `gpt-4o` by default; same Ollama fallback
- Pass `--ollama <model>` to force a specific local model (DGX has `qwen3-coder:30b`,
  `llama3.3:70b-instruct-q4_K_M`, `qwen2.5-coder:32b-instruct-fp16`, and others)

**Prerequisites:** `nsys` must be installed and on `PATH`; the `.nsys-rep` file must
be readable from the current machine (not inside a pod).

---

## Prerequisites

- KFP running on DGX (`kubeflow` namespace) — deploy via `deploy-kubeflow.yaml` workflow
- `scripts/purge_kfp_mlflow.py` and `scripts/deploy_pipeline.py` present (scaffolded by template)
- `runs/` directory exists (created by template or first `/kfp-deploy`)
- MLflow accessible at `localhost:5000`
- For GPU profiling: deploy Nsight Operator via `deploy-nsight-operator.yaml` in miramar-platform-gcp,
  then turn on the per-stage toggle in `config.yaml`'s `profiling:` block (or pass a
  `--profile-<stage>` flag to `/kfp-deploy`). The template wires
  `kubernetes.add_pod_label(task, "nvidia-nsight-profile", "enabled")` onto the flagged stage.
  Reports are pulled out of the operator's MinIO into `~/shared/nsight/` by `/nsight-export`
  (driven automatically by `/kfp-monitor`, or run by hand). See
  [dgx.md § GPU Profiling](dgx.md#gpu-profiling) for the full picture.

> **Warning:** Do NOT label the `kubeflow` namespace with `nvidia-nsight-profile=enabled` — it
> injects nsys into ALL pods including KFP's DAG driver pods, which fail with `runAsNonRoot`.
> Use per-pod labels only.
