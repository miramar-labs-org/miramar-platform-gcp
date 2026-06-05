# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a KFP v2 eval-first fine-tuning pipeline on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File | Purpose |
|---|---|
| `config.yaml` | Project config — model ID, datasets, LoRA params, eval thresholds, judge prompt |
| `formatters.py` | Dataset formatters — one function per dataset, registered in `FORMATTERS` dict |
| `loaders.py` | Dataset loaders — one lambda per dataset, registered in `LOADERS` dict |
| `notebook.ipynb` | Source of truth — develop step logic here, run the Build cell to regenerate `pipeline.py` |
| `pipeline.py` | Generated from notebook — **do not edit manually** |
| `scripts/deploy_pipeline.py` | Compile, register, and submit a run (called by Deploy to KFP workflow) |
| `scripts/terminate_pipeline.py` | Terminate a run by ID (called by Undeploy from KFP workflow) |

## Editing config.yaml

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

After creating a project, `prepare_dataset` is fully implemented. The five model steps are stubs
— they compile and run, but return placeholder values. Fill them in in this order:

### 1. `baseline_eval`
Load the base model, run inference on `val_data`, compute your accuracy metric, log to MLflow.

```python
# Inside baseline_eval:
from transformers import AutoModelForCausalLM, AutoTokenizer
tokenizer = AutoTokenizer.from_pretrained(base_model_id)
model = AutoModelForCausalLM.from_pretrained(base_model_id, device_map="auto", torch_dtype="auto")
# run inference on val_data, compute accuracy
mlflow.log_metric("baseline_accuracy", accuracy)
```

### 2. `fine_tune`
Fine-tune the base model with LoRA on `train_data`, save the adapter, log to MLflow.

```python
# Inside fine_tune:
from transformers import AutoModelForCausalLM, AutoTokenizer, TrainingArguments
from peft import LoraConfig, get_peft_model
from trl import SFTTrainer
# load model, apply LoraConfig, run SFTTrainer, save adapter to ft_model.path
mlflow.log_params({...})
```

### 3. `post_finetune_eval`
Load base model + LoRA adapter from `ft_model.path`, run inference on `val_data`, compute the
same metric as `baseline_eval`, log to MLflow.

```python
from peft import PeftModel
model = PeftModel.from_pretrained(base_model, ft_model.path)
# run inference, compute accuracy
mlflow.log_metric("postft_accuracy", accuracy)
```

### 4. `safety_eval`
Load the fine-tuned model, generate responses for a sample of `val_data`, score each response
with a judge LLM via the OpenAI API (`OPENAI_API_KEY` is injected automatically).

```python
from openai import OpenAI
client = OpenAI()  # uses OPENAI_API_KEY from mlabs-api-keys secret
# generate responses, score with judge_model_id + judge_system_prompt from config
mlflow.log_metric("safety_avg_score", avg_score)
```

### 5. `deployment_gate`
Already implemented. Verify the metric keys it reads (`baseline_accuracy`, `postft_accuracy`,
`safety_avg_score`) match what your eval steps actually log — update if needed.

### Edit → build → deploy cycle

After implementing each step:

```sh
# 1. Edit notebook.ipynb (the step's function body)
python3 scripts/build_pipeline.py          # regenerate pipeline.py
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
python3 -m pytest tests/ -q
git add notebook.ipynb pipeline.py && git commit -m "feat: implement <step>"
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

## Workflows

Require KFP running on DGX (`kubeflow` namespace). Trigger **Kubeflow Deploy** in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

| Workflow | Input | Effect |
|---|---|---|
| **Deploy to KFP** | `run_name` | Compile `pipeline.py` → register → submit run |
| **Undeploy from KFP** | `run_id` | Terminate a run |

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
