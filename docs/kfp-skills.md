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

# Profile baseline eval only
/kfp-deploy run-021 --profile-baseline

# Profile fine-tune only
/kfp-deploy run-021 --profile-finetune

# Profile post-fine-tune eval only
/kfp-deploy run-021 --profile-postft

# Profile safety eval only
/kfp-deploy run-021 --profile-safety

# Profile baseline safety eval only
/kfp-deploy run-021 --profile-baseline-safety

# Profile baseline + fine-tune (shorthand)
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

Each run gets a file in the `runs/` directory (git-tracked):

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

## `/nsight-interpret <project-name> <run-NNN> [--ollama model]`

**Extracts Nsight Systems profiling summaries and sends them to an LLM for bottleneck
analysis — no manual reading of `.nsys-rep` files required.**

```bash
# Specific project + run (standard usage from any directory)
/nsight-interpret my-project run-021

# Use a local Ollama model instead of Claude/OpenAI API
/nsight-interpret my-project run-021 --ollama qwen3-coder:30b

# Direct path (no project name needed)
/nsight-interpret /home/aaron/shared/nsight/my-project/run-021/main/profile.nsys-rep

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

## Nsight Profiling in KFP

Profiling a KFP pipeline component requires special pod configuration. The `--profile-*` flags
to `/kfp-deploy` enable this automatically.

### How it works

When a profiling flag is set, `scripts/deploy_pipeline.py` patches the Argo Workflow with:

```yaml
podSpecPatch: |
  containers:
    - name: main
      securityContext:
        privileged: true
        capabilities:
          add: ["SYS_PTRACE"]
        seccompProfile:
          type: Unconfined
```

This grants CUPTI access to the `main` container (the KFP component). The `wait` container
(argoexec sidecar) is not patched.

The nsys command embedded in the component (base64 in `build_pipeline.py`):

```bash
nsys profile \
  --trace=cuda,nvtx,cublas,cudnn,osrt \
  --cuda-flush-interval=10000 \
  --cuda-trace-scope=process-tree \
  --sample=none --force-overwrite=true \
  -o "/tmp/nsys_profile" \
  python3 /tmp/nsys_eval_script.py
```

Key flags:
- `--cuda-flush-interval=10000` — required for runs >5 min; prevents trace buffer overflow
- `--cuda-trace-scope=process-tree` — attaches CUPTI to the full subprocess chain
  (argoexec → kfp-launcher → bash → nsys → python3)
- `--sample=none` — CPU sampling disabled (irrelevant for GPU profiling; reduces overhead)

### Profile output location

```
~/shared/nsight/<project-name>/<run-name>/<component>/profile.nsys-rep
```

### GPU weight migration (GB10 unified memory)

On DGX Spark (GB10, unified memory), `from_pretrained` with `device_map="auto"` loads weights
to CPU-accessible pages. The first GPU kernel access triggers a blocking `cudaMemcpyAsync` that
migrates the full model weight tensor (~54 GB for MedGemma 27B, ~49.7s).

The eval scripts force this migration immediately after `model.eval()` via a dummy forward pass:

```python
model.eval()
with torch.no_grad():
    _dummy_ids = torch.zeros(1, 1, dtype=torch.long, device=next(model.parameters()).device)
    model(_dummy_ids)
    torch.cuda.synchronize()
del _dummy_ids
```

This ensures the migration never overlaps warmup or inference timing.

### Known issues

**`cuda_gpu_kern_sum` SKIPPED** — if the GPU kernel summary is absent from `nsys stats` output:
- Possible cause 1: trace buffer overflow (run exceeded ~5 min without `--cuda-flush-interval`)
- Possible cause 2: CUPTI subscription not reaching the Python subprocess (add `--cuda-trace-scope=process-tree`)
- Possible cause 3: privilege/capability issue in the pod (verify `privileged: true` on `main` container)
- Note: `cuda_api_sum` present without `cuda_gpu_kern_sum` is NOT a GB10 hardware limitation —
  it indicates a capture/reporting/process issue

**Standalone pods (outside KFP) always work** — `nsys` with `privileged: true` and
`RmProfilingAdminOnly=0` in `/etc/modprobe.d/nvidia.conf` captures GPU kernels correctly.
The subprocess chain in KFP adds complexity that the flags above address.

### Purging large artifacts

```bash
python3 scripts/purge_nsight.py [--sqlite-only] [--generate-missing] [--exclude run-NNN] [--dry-run]
```

- Default: delete `.sqlite` (always safe) + delete `.nsys-rep` where `summaries.csv` exists
- `--sqlite-only`: keep `.nsys-rep` files, only remove `.sqlite`
- `--generate-missing`: run `nsys stats` to create `summaries.csv` before deleting `.nsys-rep`
- `--exclude run-NNN`: skip specific runs

---

## Prerequisites

- KFP running on DGX (`kubeflow` namespace) — deploy via `deploy-kubeflow.yaml` workflow
- `scripts/purge_kfp.py` and `scripts/deploy_pipeline.py` present (scaffolded by template)
- `runs/` directory exists (created by template or first `/kfp-deploy`)
- MLflow accessible at `localhost:5000`
- For Nsight profiling: `nsys` installed on host, kubeflow namespace PSS set to `privileged`,
  `RmProfilingAdminOnly=0` in `/etc/modprobe.d/nvidia.conf`
