# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a KFP v2 eval-first fine-tuning pipeline on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File                            | Purpose                                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `config.yaml`                   | Project config — model ID, datasets, LoRA params, eval thresholds, judge prompt                        |
| `formatters.py`                 | Dataset formatters — one function per dataset, registered in `FORMATTERS` dict                         |
| `loaders.py`                    | Dataset loaders — one lambda per dataset, registered in `LOADERS` dict                                 |
| `notebook.ipynb`                | Source of truth — develop step logic here, run the Build cell to regenerate `pipeline.py`              |
| `pipeline.py`                   | Generated from notebook — **do not edit manually** (gitignored)                                        |
| `WORKBOOK.md`                   | Implementation checklist — every `USER CODE BLOCK` and helper file to fill in, with order and snippets |
| `scripts/deploy_pipeline.py`    | Compile, register, and submit a run (called by Deploy to KFP workflow)                                 |
| `scripts/terminate_pipeline.py` | Terminate a run by ID (called by Undeploy from KFP workflow)                                           |
| `runs/RUNS.md`                  | Run history — outcome, changes, and notes for every pipeline run                                       |
| `runs/run-NNN.md`               | Periodic status log for run NNN, written by the monitoring loop                                        |

## Slash commands

| Command                      | What it does                                                                                  |                                                                                                                   |
| ---------------------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `/kfp-deploy [run-NNN]`      | Purge KFP, deploy next run, create `runs/run-NNN.md`                                          |                                                                                                                   |
| `/kfp-monitor [run-NNN]`     | Self-paced monitoring loop — checks pods + MLflow, appends to `runs/run-NNN.md`               |                                                                                                                   |
| `/model-card [org/model-id]` | Fetch and display the HuggingFace model card (defaults to `base_model_id` from `config.yaml`) |                                                                                                                   |
| `/nsight-interpret [run-NNN\ | path] [--ollama model]`                                                                       | Interpret an Nsight Systems `.nsys-rep` report with an LLM — bottlenecks, idle time, optimization recommendations |

> **Nsight Operator — namespace label warning:** Do NOT label the kubeflow namespace with `nvidia-nsight-profile=enabled`. It injects nsys into ALL pods including KFP's DAG driver pods, which fail with `runAsNonRoot`. Use per-pod `kubernetes.add_pod_label(task, "nvidia-nsight-profile", "enabled")` in the pipeline definition only.

Full docs: [miramar-platform-gcp/docs/kfp-skills.md](https://github.com/miramar-labs-org/miramar-platform-gcp/blob/main/docs/kfp-skills.md)

## Editing config.yaml

**`eval.system_message` — HARD RULE:** copy this VERBATIM from the model card or technical report for the specific model you are using. Do NOT invent a system prompt. An incorrect system message invalidates baseline accuracy — the delta between baseline and post-FT becomes meaningless.

`config.yaml` drives the pipeline parameter defaults. After editing:

1. Open `notebook.ipynb` and run the **Build → `pipeline.py`** cell (notebook imports config at pipeline cell run time)
2. Compile check: `python3 -c "from kfp import compiler; from pipeline import pipeline; compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"`
3. Commit and trigger **Deploy to KFP** — or run `python3 scripts/deploy_pipeline.py` directly

## Writing formatters

Each formatter in `formatters.py`:

```python
def format_my_dataset(example):
    # example: a single row dict from the HuggingFace dataset
    return {
        "instruction": str,   # prompt / question
        "response": str,      # expected answer
        "source": str,        # dataset name (for traceability)
    }
```

Register it in `FORMATTERS` with the same key as the `name:` in `config.yaml`:

```python
FORMATTERS = {
    "my-dataset": format_my_dataset,
}
```

The Build cell inlines the entire `formatters.py` file into the `prepare_dataset` component body.
Any imports used by the formatters must be available in the component container — add them to
`prepare_dataset`'s `packages_to_install`.

## Writing loaders

Each loader in `loaders.py` is a zero-argument lambda that returns a mapped HuggingFace Dataset:

```python
from datasets import load_dataset

LOADERS = {
    "my-dataset": lambda: load_dataset("org/repo", split="train").map(format_my_dataset),
}
```

Register it with the same key as the `name:` in `config.yaml`. The Build cell inlines the entire
`loaders.py` file after `formatters.py` into the `prepare_dataset` component body — formatter
functions are already in scope, so no import is needed. Imports like `load_dataset` must be in
`prepare_dataset`'s `packages_to_install`.

## Adding a new dataset

1. Add entry to `config.yaml` under `datasets:`
2. Add formatter to `formatters.py` and register in `FORMATTERS`
3. Add loader lambda to `loaders.py` and register in `LOADERS`
4. Run Build cell → compile check → deploy

## Filling in the pipeline steps

After creating a project, `download_model` and `prepare_dataset` are fully implemented. The five model steps are stubs
— they compile and run, but return placeholder values. Fill them in in this order:

### 1. `baseline_eval`
Load the base model, run inference on `val_data`, compute your accuracy metric, log to MLflow.

```python
# Inside baseline_eval:
from transformers import AutoModelForCausalLM, AutoTokenizer
tokenizer = AutoTokenizer.from_pretrained(base_model_id)
model = AutoModelForCausalLM.from_pretrained(
    base_model_id, device_map="auto", torch_dtype="auto",
    max_memory={0: "100GiB"})   # required on DGX Spark — prevents silent CPU offload
# run inference on val_data, compute accuracy
mlflow.log_metric("baseline_accuracy", accuracy)
```

### 2. `fine_tune`
Fine-tune the base model with LoRA on `train_data`, save the adapter, log to MLflow.

```python
# Inside fine_tune:
from transformers import AutoModelForCausalLM, AutoTokenizer
from peft import LoraConfig, get_peft_model
from trl import SFTTrainer, SFTConfig
# load model, apply LoraConfig, set tokenizer.model_max_length = max_seq_length
# run SFTTrainer(processing_class=tokenizer, args=SFTConfig(...)), save adapter to ft_model.path
mlflow.log_params({...})
```

> **trl ≥ 0.29:** Use `from trl import SFTTrainer, SFTConfig` (not `TrainingArguments`).
> Pass `processing_class=tokenizer` (not `tokenizer=`). Set `tokenizer.model_max_length = max_seq_length`
> before constructing the trainer — `max_seq_length` was removed from `SFTConfig.__init__` in trl 0.29.

### 3. `post_finetune_eval`
Load base model + LoRA adapter from `ft_model.path`, run inference on `val_data`, compute the
same metric as `baseline_eval`, log to MLflow.

```python
from peft import PeftModel
model = PeftModel.from_pretrained(base_model, ft_model.path)
# run inference, compute accuracy
mlflow.log_metric("postft_accuracy", accuracy)
```

### 4. `baseline_safety_eval`
Load the base model (no adapter), run inference on a sample, score with the judge LLM. Logs
`baseline_safety_avg_score`. Runs before `fine_tune` — establishes the pre-training safety floor.

> **Inline inference required:** `make_infer_fn` is not in scope here (no `EVAL_HELPERS_INJECT`
> marker). Load the model and call `generate` directly. `parse_score` is already available —
> injected from `utils.py`, do not redefine it.

```python
# Load base model only — no PeftModel, no ft_model input
model = AutoModelForCausalLM.from_pretrained(model_path, dtype=torch.bfloat16, ...)
# inline inference + judge loop; parse_score is already in scope
mlflow.log_metric("baseline_safety_avg_score", avg_score)
```

### 5. `safety_eval`
Load the fine-tuned model, generate responses for a sample of `val_data`, score each response
with a judge LLM via the local Ollama API (model and base_url come from `config.yaml` `judge:` section).

> **Inline inference required:** `make_infer_fn` is not in scope here (no `EVAL_HELPERS_INJECT`
> marker). Load base model + `PeftModel` adapter inline and call `generate` directly. `parse_score`
> is already available — injected from `utils.py`, do not redefine it.

```python
from openai import OpenAI
client = OpenAI(base_url=judge_base_url, api_key="ollama")
# inline inference + judge scoring; parse_score is already in scope
mlflow.log_metric("safety_avg_score", avg_score)
```

### 6. `deployment_gate`
Already implemented. Verify the metric keys it reads (`baseline_accuracy`, `postft_accuracy`,
`safety_avg_score`, `baseline_safety_avg_score`) match what your eval steps actually log.

On gate pass, writes `gate_result.json` to the HF cache PVC at:
`/root/.cache/huggingface/runs/{pipeline_name}/{run_id}/gate_result.json`

This file is picked up by the serving project's `build-push.yaml` to find the latest
gate-passing adapter and bundle it into the Docker image.

### Edit → build → deploy cycle

After implementing each step:

```sh
# 1. Edit notebook.ipynb (the step's function body)
python3 scripts/build_pipeline.py          # regenerate pipeline.py
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
python3 -m pytest tests/ -q
git add notebook.ipynb && git commit -m "feat: implement <step>"  # pipeline.py is gitignored (regenerated on deploy)
git push

# 2. Purge KFP state (runs + pipelines persist across deploys)
# Use the KFP REST API or UI to terminate + delete any existing runs and pipeline versions.

# 3. Deploy
gh workflow run deploy-to-kfp.yaml --field run_name=run-NNN
```

### Data format

All steps receive train/val/test data as JSON files where every row is:
```json
{"instruction": "...", "response": "...", "source": "dataset-name"}
```
`instruction` and `response` are the standard instruction-tuning fields. `source` is metadata
only — strip it before passing to the trainer.

## Chunked training (multi-run fine-tuning)

For datasets too large to train in a single run, split training across N sequential runs where
each run trains on a different data slice and warm-starts from the previous run's adapter.

**Enable in `config.yaml`:**

```yaml
training:
  target_hours: 8.0      # wall-clock budget per run
  overhead_hours: 1.5    # model loads + eval stages (tune per model size)

chunking:
  enabled: true
  total_chunks: 5        # divide training data into 5 equal slices
  shuffle_seed: 42       # fixed seed — reproducible splits; val/test unchanged across runs
```

**Deploy each chunk manually** (one logical run base name, chunk suffix appended automatically):

```bash
# Chunk 1 — cold start, trains on data slice 0; KFP/MLflow run name: run-003-1
python3 scripts/deploy_pipeline.py --run-name run-003 --chunk-index 0

# Chunk 2 — warm-starts from chunk-1 adapter; KFP/MLflow run name: run-003-2
python3 scripts/deploy_pipeline.py --run-name run-003 --chunk-index 1

# Chunk N — KFP/MLflow run name: run-003-N
python3 scripts/deploy_pipeline.py --run-name run-003 --chunk-index N-1
```

**How it works:**
- `prepare_dataset` shuffles all rows with the fixed seed, then slices `train_rows[start:end]` for this chunk. Val/test are derived from the same fixed-seed shuffle and never chunked — metrics stay comparable across all runs.
- `fine_tune` loads the previous chunk's adapter from the HF cache PVC (`/root/.cache/huggingface/adapters/{pipeline-name}/chunk-{N-1}/`). `is_trainable=True` continues training without a memory-expensive merge.
- Adapter is copied to the PVC at the end of `fine_tune` regardless of the deployment gate outcome, so the next run always has a valid warm-start source.
- `max_steps` is self-calibrating: a `_TimeBudgetCallback` runs 10 warmup steps, measures sec/step, then sets `control.should_training_stop` at the computed step.

**Without chunking (`chunking.enabled: false`, `target_hours: 0`):** behaves identically to a standard single-run pipeline — backward-compatible default.

**Adapters on the DGX host:** `/home/aaron/shared/huggingface-kfp/adapters/{pipeline-name}/chunk-{N}/`

---

## Workflows

Require KFP running on DGX (`kubeflow` namespace). Trigger **Kubeflow Deploy** in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

| Workflow              | Input      | Effect                                        |
| --------------------- | ---------- | --------------------------------------------- |
| **Deploy to KFP**     | `run_name` | Compile `pipeline.py` → register → submit run |
| **Undeploy from KFP** | `run_id`   | Terminate a run                               |

## Component rules

- **All imports must be inside the function body** — each component runs in its own container
- `packages_to_install` on `@dsl.component` is the only way to add dependencies to a component
- GPU steps: `.set_gpu_limit(1).set_memory_limit("64G")` in the pipeline cell
- Secret env vars (HF_TOKEN, OPENAI_API_KEY, etc.) are injected from the `mlabs-api-keys` K8s secret
  via `k8s_ext.use_secret_as_env` — no manual setup needed, the platform provisions the secret

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

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
