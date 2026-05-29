# {{PROJECT_NAME}}

<!-- One-line description of this project -->

[![Open in JupyterLab](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/open-jupyterlab.yaml/badge.svg)](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/open-jupyterlab.yaml)
[![Deploy to NeMo](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/deploy-nemo.yaml/badge.svg)](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/deploy-nemo.yaml)
[![Undeploy from NeMo](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/undeploy-nemo.yaml/badge.svg)](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/undeploy-nemo.yaml)

**Type**: NeMo Microservices

## Prerequisites

NeMo running on DGX — trigger **NeMo Deploy** in [miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

## Workflows

| Workflow | Input | Effect |
|---|---|---|
| **Open in JupyterLab** | — | Clone/pull repo to DGX `~/git-miramar-labs-org/projects/`, print direct URL |
| **Deploy to NeMo** | `job_name` (optional override) | Submit training job from `job_config.yaml` |
| **Undeploy from NeMo** | `job_name` | Cancel a training job |

## Project structure

```
job_config.yaml      ← Training job config — edit this first
notebook.ipynb       ← Interactive development with NeMo SDK
scripts/
  submit_job.py        ← Called by Deploy to NeMo workflow
  cancel_job.py        ← Called by Undeploy from NeMo workflow
```

---

## Developer guide: filling out the notebook

### 1. Open in JupyterLab

Trigger **Open in JupyterLab** from the Actions tab. It clones/pulls this repo to
`~/git-miramar-labs-org/projects/{{PROJECT_NAME}}` on the DGX and prints a direct link in the workflow summary.

Then open: [http://localhost:8888/lab/tree/git-miramar-labs-org/projects/{{PROJECT_NAME}}](http://localhost:8888/lab/tree/git-miramar-labs-org/projects/{{PROJECT_NAME}})

### 2. Set up NeMo access

SSH tunnel from your laptop:

```sh
ssh -L 8082:localhost:8082 -L 8888:localhost:8888 <user>@spark-79b7.local
```

Add to your laptop's `/etc/hosts` (Windows: `C:\Windows\System32\drivers\etc\hosts`, WSL2: `/etc/hosts`):

```
127.0.0.1 nemo.test nim.test data-store.test
```

Then open JupyterLab at [http://localhost:8888](http://localhost:8888).

### 3. Install the NeMo SDK

In a terminal or notebook cell:

```sh
pip install nemo-microservices pyyaml
```

### 4. Connect and explore

```python
from nemo_microservices import NeMoMicroservices

client = NeMoMicroservices(
    base_url="http://nemo.test:8082",
    inference_base_url="http://nim.test:8082",
)

# List available base models
for m in client.models.list().items:
    print(m.name)
```

### 5. Configure your job

Edit `job_config.yaml`:

```yaml
name: "{{PROJECT_NAME}}-job"
model: "meta/llama-3.1-8b"       # base model to fine-tune
training:
  num_epochs: 3
  batch_size: 8
  learning_rate: 1.0e-4
  dataset_path: ""                # upload your dataset first (see below)
```

#### Uploading a dataset

```sh
# Upload a JSONL file to the NeMo data store
curl -X POST "http://data-store.test:8082/v1/hf/datasets/upload" \
  -F "file=@my_dataset.jsonl"
```

Then set `dataset_path` in `job_config.yaml` to the returned path.

### 6. Submit a job from the notebook

```python
import yaml

with open("job_config.yaml") as f:
    config = yaml.safe_load(f)

job = client.customization.jobs.create(
    name=config["name"],
    model=config["model"],
    training_config={
        "num_epochs": config["training"]["num_epochs"],
        "batch_size": config["training"].get("batch_size", 8),
        "learning_rate": config["training"].get("learning_rate", 1e-4),
    },
    dataset={"file_path": config["training"].get("dataset_path", "")},
)
print(f"Job: {job.id}  status: {job.status}")
```

### 7. Monitor job status

```python
import time

for _ in range(60):
    j = client.customization.jobs.retrieve(config["name"])
    print(f"  {j.status}")
    if j.status in ("completed", "failed", "cancelled"):
        break
    time.sleep(30)
```

### 8. Run inference on the fine-tuned model (after job completes)

```python
# Point the client at the fine-tuned model
response = client.inference.completions.create(
    model=config["name"],
    prompt="Summarise this document:",
    max_tokens=256,
)
print(response.choices[0].text)
```

### 9. CI/CD via GitHub Actions

When `job_config.yaml` is ready, trigger **Deploy to NeMo** from the Actions tab.
The workflow calls `scripts/submit_job.py` and prints the job name + ID in the summary.

---

## API endpoints (after SSH tunnel + /etc/hosts)

| Endpoint | URL | What it does |
|---|---|---|
| List jobs | [http://nemo.test:8082/v1/customization/jobs](http://nemo.test:8082/v1/customization/jobs) | All fine-tuning jobs |
| List models | [http://nemo.test:8082/v1/models](http://nemo.test:8082/v1/models) | Available base models |
| Data store health | [http://data-store.test:8082/v1/health](http://data-store.test:8082/v1/health) | Data store status |
| NIM inference | [http://nim.test:8082/v1/models](http://nim.test:8082/v1/models) | Deployed NIM models |
| JupyterLab | [http://localhost:8888](http://localhost:8888) | Notebook environment |
