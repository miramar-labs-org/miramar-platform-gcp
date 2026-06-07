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
prepare_dataset
  --> baseline_eval
  --> baseline_safety_eval
  --> fine_tune
        --> post_finetune_eval --> deployment_gate
        --> safety_eval        -->
```

> `fine_tune` runs after both baseline evals (not parallel) — on single-node minikube, GPU steps
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

| Key | Type | Description |
|---|---|---|
| `model.id` | string | HuggingFace model ID (e.g. `google/medgemma-27b-it`) |
| `datasets[].name` | string | Dataset name — must match a key in `FORMATTERS` and `LOADERS` |
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

## 4. Secrets

All API keys (`HF_TOKEN`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `WANDB_API_KEY`, etc.) are injected
automatically into every component pod from the `mlabs-api-keys` K8s secret in the `kubeflow` namespace.

**No manual setup required** — the secret is provisioned by the **Kubeflow Deploy** workflow in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp).

---

## 5. MLflow

Each component logs metrics to MLflow automatically. Access the UI:

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
# → http://localhost:5000
```

Use **ML** experiment type (not *GenAI apps & agents*).

---

## 6. KFP UI

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# → http://localhost:8080
```

Runs appear in the **Runs** tab. After the first submission, the pipeline also appears in the
**Pipelines** tab (registered by `scripts/deploy_pipeline.py`).

Prerequisites: **Kubeflow Deploy** must be running. Trigger it in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) if the KFP UI
is unreachable.

---

## 7. GPU profiling (Nsight Systems)

Optional Nsight Systems profiling on individual pipeline stages. Enable per-stage flags when submitting a run:

```bash
python3 scripts/deploy_pipeline.py --run-name run-001 \
    --profile-baseline \
    --profile-finetune
```

| Flag | Stage profiled |
|---|---|
| `--profile-baseline` | `baseline_eval` |
| `--profile-finetune` | `fine_tune` |
| `--profile-postft` | `post_finetune_eval` |
| `--profile-safety` | `safety_eval` |
| `--profile-baseline-safety` | `baseline_safety_eval` |

All flags default to off. Unprofiled runs behave identically to runs before this feature existed.

**Output** — reports are written to the host at:
```
/home/aaron/shared/nsight/
  {{PROJECT_NAME}}/
    {run_id}/
      baseline-eval/profile.nsys-rep
      fine-tune/profile.nsys-rep
      ...
```
`{run_id}` is the value you passed as `--run-name` (e.g., `run-001`).

**Viewing** — open any `.nsys-rep` in NVIDIA Nsight Systems desktop GUI:
```bash
nsys-ui /home/aaron/shared/nsight/{{PROJECT_NAME}}/{run_id}/baseline-eval/profile.nsys-rep
```

**Setup** — host directory and PVC are provisioned automatically by **Kubeflow Deploy**. No manual setup required.
