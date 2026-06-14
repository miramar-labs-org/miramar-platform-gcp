# {{PROJECT_NAME}}

[![Open in JupyterLab](https://img.shields.io/badge/Open%20in-JupyterLab-F37626?logo=jupyter&logoColor=white)]({{JL_URL}})  [![last run](https://img.shields.io/badge/last%20run-pending-lightgrey)](runs/RUNS.md)

| ----------- | ---------------------------------------------------------------------- |
| ----------- | ---------------------------------------------------------------------- |
| **Type**    | KFP v2 eval-first fine-tuning pipeline                                 |
| **Model**   | [{{HF_MODEL_ID}}](https://huggingface.co/{{HF_MODEL_ID}})              |
| **Dataset** | [{{HF_DATASET_ID}}](https://huggingface.co/datasets/{{HF_DATASET_ID}}) |

<!-- One-line description of this project -->

> **Validation status:** Pipeline is in scaffolding phase — no runs yet. Status tracked in
> [docs/VALIDATION_STATUS.md](docs/VALIDATION_STATUS.md).

---

## 1. What this is

A config-driven, eval-first fine-tuning pipeline for language models on the Miramar platform.
The pipeline evaluates the base model first, fine-tunes with LoRA, re-evaluates, runs an LLM-as-judge
safety pass, then gates deployment on the results.

**DAG:**
```
download_model
  --> prepare_dataset
        --> baseline_eval     ---------> fine_tune
        --> baseline_safety_eval ------> fine_tune
                                              --> post_finetune_eval --> deployment_gate
                                              --> safety_eval        -->
```

> `fine_tune` runs after both baseline evals (not parallel) — on single-node k3s, GPU steps
> cannot overlap without exceeding the allocatable memory limit.

---

## 2. Quick start

1. Edit `config.yaml` — set `model.id`, the `datasets` list, LoRA params, eval thresholds, and judge prompt
2. Edit `formatters.py` and `loaders.py` — add one function/lambda per dataset (see `WORKBOOK.md`)
3. Open `notebook.ipynb` in JupyterLab and fill in every `# ---- USER CODE BLOCK ----` section
4. Run the **Build → `pipeline.py`** cell
5. Run the compile check:
   ```sh
   python3 -c "from kfp import compiler; from pipeline import pipeline; \
       compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
   ```
6. Trigger **Deploy to KFP** from the Actions tab (or `python3 scripts/deploy_pipeline.py`)

---

## 3. config.yaml reference

| Key                                    | Type   | Description                                                   |
| -------------------------------------- | ------ | ------------------------------------------------------------- |
| `model.id`                             | string | HuggingFace model ID (e.g. `google/medgemma-27b-it`)          |
| `datasets[].name`                      | string | Dataset name — must match a key in `FORMATTERS` and `LOADERS` |
| `datasets[].hf_path`                   | string | HuggingFace dataset path                                      |
| `datasets[].hf_config`                 | string | Optional HF dataset config name                               |
| `datasets[].trust_remote_code`         | bool   | Pass `trust_remote_code=True` to `load_dataset`               |
| `lora.r`                               | int    | LoRA rank                                                     |
| `lora.alpha`                           | int    | LoRA alpha (scaling = alpha/r)                                |
| `lora.dropout`                         | float  | LoRA dropout                                                  |
| `lora.target_modules`                  | list   | Attention/MLP modules to adapt                                |
| `training.num_epochs`                  | int    | Fine-tuning epochs                                            |
| `training.learning_rate`               | float  | AdamW learning rate                                           |
| `training.batch_size`                  | int    | Per-device batch size                                         |
| `training.gradient_accumulation_steps` | int    | Gradient accumulation steps                                   |
| `training.max_seq_length`              | int    | Max token sequence length                                     |
| `training.val_size`                    | float  | Fraction of data for validation                               |
| `training.test_size`                   | float  | Fraction of data for final test                               |
| `eval.sample_size`                     | int    | Number of val examples used for baseline/post-FT eval         |
| `eval.safety_sample_size`              | int    | Number of val examples used for LLM-judge eval                |
| `eval.accuracy_delta_threshold`        | float  | Max allowed accuracy regression (post-FT vs baseline)         |
| `eval.safety_score_threshold`          | float  | Min average judge score to pass gate                          |
| `judge.model`                          | string | OpenAI model ID for LLM-as-judge (e.g. `gpt-4o`)              |
| `judge.system_prompt`                  | string | System prompt for the judge — must elicit JSON output         |
| `deployment.gcs_bucket`                | string | GCS bucket for adapter upload on gate pass                    |

---

## 4. MLflow

Each component logs metrics to MLflow automatically. Access the UI:

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
# → http://localhost:5000
```

Use **ML** experiment type (not *GenAI apps & agents*).

---

## 5. Optional integrations

### Weights & Biases

W&B integration is built in and opt-in. Enable it in `config.yaml`:

```yaml
wandb:
  enabled: true
  project: "{{PROJECT_NAME}}"
  entity: ""   # leave blank for personal account
```

When enabled, `fine_tune` logs step-level metrics (loss, grad_norm, lr, token accuracy) to W&B alongside MLflow via `report_to: ["mlflow", "wandb"]`. Requires `WANDB_API_KEY` in the `mlabs-api-keys` K8s secret (already provisioned by the platform). Full details: [docs/kfp-skills.md — Weights & Biases](https://github.com/miramar-labs-org/miramar-platform-gcp/blob/main/docs/kfp-skills.md#weights--biases).

### Slack notifications

`/kfp-monitor` sends a one-line summary to Slack on every terminal pipeline result (PASS or FAIL). Set once in `~/.zshrc` on the DGX:

```bash
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
```

If unset, `/kfp-monitor` runs silently — no notification is sent.

---

## 6. Kubeflow Pipelines UI

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# → http://localhost:8080
```

Runs appear in the **Runs** tab. After the first submission, the pipeline also appears in the
**Pipelines** tab (registered by `scripts/deploy_pipeline.py`).

Prerequisites: **Kubeflow Deploy** must be running. Trigger it in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) if the Kubeflow Pipelines UI
is unreachable.

---

## 7. GPU profiling (Nsight Operator)

The Nsight Operator is a cluster-level profiler — no code changes needed in components. To profile a stage, add a pod label in the pipeline definition:

```python
from kfp import kubernetes
# Inside the pipeline() function, after creating the task:
kubernetes.add_pod_label(base_eval, label_key="nvidia-nsight-profile", label_value="enabled")
```

The operator injects `nsys` at pod creation and stores the report in its MinIO. Components already contain NVTX annotations (`nvtx.annotate(...)`) that appear on the timeline.

**Viewing results:** Open the Nsight Operator UI at [http://localhost:8889](http://localhost:8889) (via SSH tunnel on port 8889) and navigate to the captured session.

**Interpreting results:**
```bash
/nsight-interpret run-NNN   # AI-assisted bottleneck analysis
```

See [miramar-platform-gcp — Nsight Operator Deploy workflow](https://github.com/miramar-labs-org/miramar-platform-gcp) for deployment instructions.

