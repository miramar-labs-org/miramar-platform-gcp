# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a KFP v2 eval-first fine-tuning pipeline on the Miramar platform (DGX Spark),
using **NeMo Microservices Customizer** as the training backend instead of HF Trainer.

Fine-tuning is submitted as an async NeMo Customizer job. The resulting `.nemo` checkpoint is
exported to HF PEFT format by the `export_adapter` stage so all downstream eval and serving
stages use the same format as `ft-eval` projects.

## Key files

| File                            | Purpose                                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `config.yaml`                   | Project config — model IDs (NeMo + HF), NeMo URL/namespace, training params, eval thresholds          |
| `formatters.py`                 | Dataset formatters — one function per dataset, registered in `FORMATTERS` dict                         |
| `loaders.py`                    | Dataset loaders — one lambda per dataset, registered in `LOADERS` dict                                 |
| `notebook.ipynb`                | Source of truth — develop step logic here, run the Build cell to regenerate `pipeline.py`              |
| `pipeline.py`                   | Generated from notebook — **do not edit manually** (gitignored)                                        |
| `WORKBOOK.md`                   | Implementation checklist — every `USER CODE BLOCK` to fill in, with order and snippets                 |
| `scripts/deploy_pipeline.py`    | Compile, register, and submit a run (called by Deploy to KFP workflow)                                 |
| `scripts/terminate_pipeline.py` | Terminate a run by ID (called by Undeploy from KFP workflow)                                           |

## Slash commands

| Command                      | What it does                                                                                  |
| ---------------------------- | --------------------------------------------------------------------------------------------- |
| `/kfp-deploy [run-NNN]`      | Purge KFP, deploy next run, create `runs/run-NNN.md`                                          |
| `/kfp-monitor [run-NNN]`     | Self-paced monitoring loop — checks pods + MLflow, appends to `runs/run-NNN.md`               |
| `/nsight-interpret [run-NNN]` | Interpret an Nsight Systems `.nsys-rep` report with an LLM                                   |
| `/nsight-export <project> <run-NNN> <stage> [--duration N] [--adhoc]` | Pull a profiled stage's Nsight report from the operator's MinIO into `~/shared/nsight/<project>/<run-id>/<stage>/` and auto-run `/nsight-interpret` |

> **Profiling is opt-in via `config.yaml`'s `profiling:` block** (per-stage keys +
> `collection_window_s`), or the `/kfp-deploy --profile-<stage>` flags. `fine-tune` is not
> profilable — it runs on the NeMo API, not a local GPU pod. Do NOT label the kubeflow
> namespace with `nvidia-nsight-profile=enabled` — per-pod labels only.

## Pipeline stages

```
download_model
  --> prepare_dataset
        --> baseline_eval          ---> fine_tune --> export_adapter -+-> post_finetune_eval --> gate
        --> baseline_safety_eval --/                                  |
                                                                      +--> safety_eval --> gate
```

| Stage                 | Backend            | Notes                                                          |
| --------------------- | ------------------ | -------------------------------------------------------------- |
| `download_model`      | HF Hub             | Downloads base model for eval stages                           |
| `prepare_dataset`     | HF datasets        | Same as `ft-eval` — outputs `{instruction, response, source}`  |
| `baseline_eval`       | HF Transformers    | Same as `ft-eval`                                              |
| `baseline_safety_eval`| HF Transformers    | Same as `ft-eval`                                              |
| `fine_tune`           | NeMo Customizer    | Submits async job, polls, downloads `.nemo` checkpoint         |
| `export_adapter`      | NeMo toolkit       | Converts `.nemo` → HF PEFT adapter dir (`adapter_model.safetensors`) |
| `post_finetune_eval`  | HF Transformers    | Same as `ft-eval` but loads from `export_adapter` output       |
| `safety_eval`         | HF Transformers    | Same as `ft-eval` but loads from `export_adapter` output       |
| `deployment_gate`     | Python             | Same gate contract as `ft-eval` — writes `gate_result.json`    |

## config.yaml — key differences from ft-eval

- No `lora:` block — LoRA hyperparameters come from the NeMo Customizer job config
- Two model IDs: `model.id` (NeMo catalog name) and `model.hf_id` (HuggingFace ID for eval)
- `nemo:` section: `base_url`, `namespace`, `data_store_path`

## NeMo API access

SSH tunnel: `ssh -L 8082:localhost:8082 spark-79b7.local`  
Laptop `/etc/hosts`: `127.0.0.1 nemo.test nim.test data-store.test`

Useful checks:
```sh
curl http://nemo.test:8082/v1/models                    # list available base models
curl http://nemo.test:8082/v1/customization/jobs        # list jobs
curl http://data-store.test:8082/v1/health              # data store health
```

## Filling in the pipeline steps

After creating a project, `download_model` and `prepare_dataset` are fully implemented.
The eval stages are identical to `ft-eval`. Fill in the two NeMo-specific stages:

### 1. `fine_tune` (NeMo Customizer)
1. Convert train data to NeMo JSONL format (`{"input": ..., "output": ...}`)
2. Upload to NeMo Data Store via `/v1/datastore/files` or SDK
3. Create customization job with `client.customization.jobs.create(...)`
4. Poll until `status == "completed"` or raise on `"failed"`
5. Download checkpoint artifact to `ft_model.path/`

```python
from nemo_microservices import NeMoMicroservices
client = NeMoMicroservices(base_url=nemo_base_url)

# Upload data (see NeMo SDK docs for data store API)
# Create job:
job = client.customization.jobs.create(
    name=f"{run_id}-finetune",
    model=base_model_id,
    training_config={"num_epochs": num_epochs, "batch_size": batch_size, "learning_rate": learning_rate},
    dataset={"train": {"file_id": "uploaded-dataset-id"}},
)
# Poll: client.customization.jobs.retrieve(job.id).status
# Download: client.customization.jobs.download(job.id, ft_model.path)
```

### 2. `export_adapter` (NeMo → HF PEFT)
Locate the `.nemo` checkpoint in `ft_model.path`, run `nemo2hf` to produce a standard
HF PEFT adapter directory at `hf_adapter.path`.

```python
# Available in nvcr.io/nvidia/nemo:25.04+
import subprocess
subprocess.run([
    "python3", "/opt/nemo/scripts/nemo2hf.py",
    "--input", str(nemo_ckpt_path),
    "--output", str(hf_adapter.path),
], check=True)
```

The output must be a valid HF PEFT adapter directory (`adapter_model.safetensors` +
`adapter_config.json`) — the same format `serving-vllm` expects.

## Gate contract (identical to ft-eval)

On gate pass, `deployment_gate` writes `gate_result.json` to:
```
/root/.cache/huggingface/runs/{pipeline_name}/{run_id}/gate_result.json
```

This file is consumed by `serving-vllm`'s `build-push.yaml` — no changes needed there.

## Workflows

Require KFP running on DGX (`kubeflow` namespace) AND NeMo Microservices running (`nemo-microservices` namespace).

| Workflow              | Input      | Effect                                        |
| --------------------- | ---------- | --------------------------------------------- |
| **Deploy to KFP**     | `run_name` | Compile `pipeline.py` → register → submit run |
| **Undeploy from KFP** | `run_id`   | Terminate a run                               |

## Compile check

```sh
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
