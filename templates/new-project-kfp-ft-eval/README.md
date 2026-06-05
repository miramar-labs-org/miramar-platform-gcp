# {{PROJECT_NAME}}

[![Open in JupyterLab](https://img.shields.io/badge/Open%20in-JupyterLab-F37626?logo=jupyter&logoColor=white)]({{JL_URL}})

<!-- One-line description of this project -->

**Type**: KFP v2 eval-first fine-tuning pipeline

---

## 1. What this is

A config-driven, eval-first fine-tuning pipeline for language models on the Miramar platform.
The pipeline evaluates the base model first, fine-tunes with LoRA, re-evaluates, runs an LLM-as-judge
safety pass, then gates deployment on the results.

**DAG:**
```
prepare_dataset ──► baseline_eval ──► fine_tune ─┬─► post_finetune_eval ──►─┐
                                                 │                          │
                                                 └─► safety_eval ──────────►┤
                                                                            │
                                                                   deployment_gate
```

> `fine_tune` runs after `baseline_eval` (not parallel) — on single-node minikube, both steps
> need GPU memory simultaneously and will exceed the allocatable limit if run together.

To start a new project with this template, run **Create Project** in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) with type `kfp-ft-eval`.

---

## 2. Quick start

1. Edit `config.yaml` — set `model.id`, the `datasets` list, LoRA params, eval thresholds, and judge prompt
2. Edit `formatters.py` — add one function per dataset that maps a raw HF row to `{instruction, response, source}`; register in `FORMATTERS`
3. Open `notebook.ipynb` in JupyterLab and implement the `TODO` logic in each `@dsl.component` cell
4. Save (`Ctrl+S`), run the **Build → `pipeline.py`** cell
5. Run the compile check:
   ```sh
   python3 -c "from kfp import compiler; from pipeline import pipeline; \
       compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
   ```
6. Trigger **Deploy to KFP** from the Actions tab (or `python3 scripts/deploy_pipeline.py`)

---

## 3. config.yaml reference

| Key | Type | Description |
|---|---|---|
| `model.id` | string | HuggingFace model ID (e.g. `google/medgemma-27b-it`) |
| `datasets[].name` | string | Dataset name — must match a key in `FORMATTERS` |
| `datasets[].hf_path` | string | HuggingFace dataset path |
| `datasets[].hf_config` | string | Optional HF dataset config name |
| `datasets[].trust_remote_code` | bool | Pass `trust_remote_code=True` to `load_dataset` |
| `lora.r` | int | LoRA rank |
| `lora.alpha` | int | LoRA alpha (scaling = alpha/r) |
| `lora.dropout` | float | LoRA dropout |
| `lora.target_modules` | list | Attention/MLP modules to adapt |
| `training.num_epochs` | int | Fine-tuning epochs |
| `training.learning_rate` | float | AdamW learning rate |
| `training.batch_size` | int | Per-device batch size |
| `training.gradient_accumulation_steps` | int | Gradient accumulation steps |
| `training.max_seq_length` | int | Max token sequence length |
| `training.val_size` | float | Fraction of data for validation |
| `training.test_size` | float | Fraction of data for final test |
| `eval.sample_size` | int | Number of val examples used for baseline/post-FT eval |
| `eval.safety_sample_size` | int | Number of val examples used for LLM-judge eval |
| `eval.accuracy_delta_threshold` | float | Max allowed accuracy regression (post-FT vs baseline) |
| `eval.safety_score_threshold` | float | Min average judge score to pass gate |
| `judge.model` | string | OpenAI model ID for LLM-as-judge (e.g. `gpt-4o`) |
| `judge.system_prompt` | string | System prompt for the judge — must elicit JSON output |
| `deployment.gcs_bucket` | string | GCS bucket for adapter upload on gate pass |

---

## 4. Writing formatters

Each formatter converts a single HuggingFace dataset row to a standard dict:

```python
def format_my_dataset(example: dict) -> dict:
    return {
        "instruction": example["question"],   # str — the prompt
        "response": example["answer"],         # str — the expected response
        "source": "my-dataset",               # str — traceability label
    }

FORMATTERS = {
    "my-dataset": format_my_dataset,          # key must match config.yaml datasets[].name
}
```

**Common pitfalls:**
- Imports used inside a formatter must be in `prepare_dataset`'s `packages_to_install` — the Build
  cell inlines `formatters.py` into the component body, but does not add packages automatically
- If options are a list of dicts (e.g. `[{"key": "A", "value": "..."}]`), convert them explicitly
- Datasets using custom scripts need `trust_remote_code: true` in `config.yaml` and `datasets<3.0`

---

## 5. Pipeline structure

| Step | Inputs | Outputs | Notes |
|---|---|---|---|
| `prepare_dataset` | `dataset_names`, `val_size`, `test_size` | `train_out`, `val_out`, `test_out` | Formatters inlined from `formatters.py` |
| `baseline_eval` | `val_out`, `base_model_id` | `metrics` | Runs in parallel with `fine_tune` |
| `fine_tune` | `train_out`, `val_out`, `base_model_id`, LoRA params | `ft_model` | Runs in parallel with `baseline_eval` |
| `post_finetune_eval` | `val_out`, `ft_model` | `metrics` | After `fine_tune` |
| `safety_eval` | `val_out`, `ft_model`, judge params | `metrics` | After `fine_tune`; uses `OPENAI_API_KEY` |
| `deployment_gate` | `test_out`, `ft_model`, all metrics, thresholds | — | Fails pipeline on regression |

---

## 6. Secrets

All API keys (`HF_TOKEN`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `WANDB_API_KEY`, etc.) are injected
automatically into every component pod from the `mlabs-api-keys` K8s secret in the `kubeflow` namespace.

**No manual setup required** — the secret is provisioned by the **Kubeflow Deploy** workflow in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp).

---

## 7. MLflow

Each component logs metrics to MLflow automatically. Access the UI:

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
# → http://localhost:5000
```

Use **ML** experiment type (not *GenAI apps & agents*). Logged values:
- `baseline_eval` → `baseline_accuracy`
- `fine_tune` → training hyperparameters
- `post_finetune_eval` → `postft_accuracy`
- `safety_eval` → `safety_avg_score`

---

## 8. Adding a new dataset

1. Add an entry to `config.yaml` under `datasets:`
   ```yaml
   - name: my-dataset
     hf_path: org/my-dataset
   ```
2. Add a formatter to `formatters.py` and register it in `FORMATTERS`
3. Add the load logic in the `prepare_dataset` cell (find the `TODO`)
4. Save, run Build cell, compile check, trigger **Deploy to KFP**

---

## 9. Changing the model

Edit `model.id` in `config.yaml`. The `base_model_id` pipeline parameter default updates automatically
when the Build cell regenerates `pipeline.py`. You may also need to update `lora.target_modules` to
match the new model's attention architecture.

---

## 10. KFP UI

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# → http://localhost:8080
```

Runs appear in the **Runs** tab. After the first submission, the pipeline also appears in the
**Pipelines** tab (registered by `scripts/deploy_pipeline.py`).

Prerequisites: **Kubeflow Deploy** must be running. Trigger it in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) if the KFP UI
is unreachable.
