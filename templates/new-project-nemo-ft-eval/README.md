# {{PROJECT_NAME}}

[![Open in JupyterLab](https://img.shields.io/badge/Open%20in-JupyterLab-F37626?logo=jupyter&logoColor=white)]({{JL_URL}})  [![last run](https://img.shields.io/badge/last%20run-pending-lightgrey)](runs/RUNS.md)

| | |
| ----------- | -------------------------------------------------------------------------- |
| **Type**    | KFP v2 eval-first fine-tuning pipeline (NeMo Customizer backend)           |
| **Model**   | [{{HF_MODEL_ID}}](https://huggingface.co/{{HF_MODEL_ID}})                 |
| **Dataset** | [{{HF_DATASET_ID}}](https://huggingface.co/datasets/{{HF_DATASET_ID}})    |

{{DESCRIPTION}}

---

## 1. What this is

A config-driven, eval-first fine-tuning pipeline using **NeMo Microservices Customizer** as the
training backend. The pipeline evaluates the base model first, submits an async NeMo fine-tuning
job, exports the resulting checkpoint to HF PEFT format, re-evaluates, runs an LLM-as-judge
safety pass, then gates deployment on the results.

The gate contract and adapter format are identical to `ft-eval` projects — `serving-vllm`'s
`build-push.yaml` works without modification.

**DAG:**
```
download_model
  --> prepare_dataset
        --> baseline_eval          ---> fine_tune --> export_adapter -+-> post_finetune_eval --> gate
        --> baseline_safety_eval --/                                  |
                                                                      +--> safety_eval --> gate
```

> `fine_tune` runs after both baseline evals — on single-node k3s, GPU steps cannot overlap
> without exceeding the allocatable memory limit.

---

## 2. Prerequisites

1. **KFP running on DGX** (`kubeflow` namespace) — trigger **Kubeflow Deploy** in
   [miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
2. **NeMo Microservices running on DGX** (`nemo-microservices` namespace) — trigger **NeMo Deploy**
3. NeMo Customizer must have the base model listed: `curl http://nemo.test:8082/v1/models`

---

## 3. Quick start

1. Edit `config.yaml` — set `model.id` (NeMo catalog name), `model.hf_id` (HuggingFace ID),
   `nemo.base_url`, datasets, eval thresholds, and judge prompt
2. Edit `formatters.py` and `loaders.py` — add one function/lambda per dataset
3. Open `notebook.ipynb` in JupyterLab and fill in every `# ---- USER CODE BLOCK ----` section
4. Run the **Build → `pipeline.py`** cell
5. Run the compile check:
   ```sh
   python3 -c "from kfp import compiler; from pipeline import pipeline; \
       compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
   ```
6. Trigger **Deploy to KFP** from the Actions tab (or `python3 scripts/deploy_pipeline.py`)

---

## 4. config.yaml reference

| Key                             | Type   | Description                                                           |
| ------------------------------- | ------ | --------------------------------------------------------------------- |
| `model.id`                      | string | NeMo Customizer base model ID (from `GET /v1/models`)                 |
| `model.hf_id`                   | string | HuggingFace model ID — used by eval stages                            |
| `nemo.base_url`                 | string | NeMo Microservices base URL (e.g. `http://nemo.test:8082`)            |
| `nemo.namespace`                | string | NeMo namespace for job submission                                     |
| `nemo.data_store_path`          | string | Path prefix in NeMo data store for dataset upload                     |
| `datasets[].name`               | string | Dataset name — must match a key in `FORMATTERS` and `LOADERS`         |
| `datasets[].hf_path`            | string | HuggingFace dataset path                                              |
| `training.num_epochs`           | int    | Fine-tuning epochs                                                    |
| `training.learning_rate`        | float  | AdamW learning rate                                                   |
| `training.batch_size`           | int    | Per-device batch size                                                 |
| `training.val_size`             | float  | Fraction of data for validation                                       |
| `training.test_size`            | float  | Fraction of data for final test                                       |
| `eval.sample_size`              | int    | Number of val examples for baseline/post-FT eval                      |
| `eval.accuracy_delta_threshold` | float  | Max allowed accuracy regression                                       |
| `eval.safety_score_threshold`   | float  | Min average judge score to pass gate                                  |
| `judge.model`                   | string | Ollama model ID for LLM-as-judge                                      |
| `judge.base_url`                | string | Ollama API base URL                                                   |

---

## 5. MLflow

Each component logs metrics to MLflow automatically. Access the UI:

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
# → http://localhost:5000
```

Use **ML** experiment type (not *GenAI apps & agents*).

---

## 6. NeMo access

SSH tunnel: `ssh -L 8082:localhost:8082 spark-79b7.local`  
Laptop `/etc/hosts`: `127.0.0.1 nemo.test nim.test data-store.test`

```sh
curl http://nemo.test:8082/v1/models                 # list available base models
curl http://nemo.test:8082/v1/customization/jobs     # list jobs
```

---

## 7. Kubeflow Pipelines UI

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# → http://localhost:8080
```

---

## 8. GPU profiling (Nsight Operator)

Same as `ft-eval` — opt in per stage via `config.yaml`'s `profiling:` block:

```yaml
profiling:
  baseline-eval: true
  baseline-safety-eval: false
  export-adapter: false
  post-finetune-eval: false
  safety-eval: false
  collection_window_s: 90
```

`fine-tune` is **not** listed — it runs against the NeMo Microservices Customizer API, not a
local GPU pod, so there is nothing for the operator to hook. A `true` value labels that
stage pod `nvidia-nsight-profile=enabled` (done by the notebook's pipeline cell); the
operator injects `nsys` and writes the report to its internal MinIO. `/kfp-monitor` drives
`/nsight-export` during the stage's GPU-hot window to archive it to
`~/shared/nsight/<project>/<run-id>/<stage>/` and auto-run `/nsight-interpret`. Manual
fallback if the window is missed:

```bash
/nsight-export {{PROJECT_NAME}} run-NNN baseline-eval [--duration 120]
```

See [miramar-platform-gcp — docs/dgx.md § GPU Profiling](https://github.com/miramar-labs-org/miramar-platform-gcp/blob/main/docs/dgx.md#gpu-profiling).
