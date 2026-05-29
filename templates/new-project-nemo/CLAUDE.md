# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a NeMo Microservices training project on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File | Purpose |
|---|---|
| `job_config.yaml` | Training job parameters — model, epochs, dataset path |
| `notebook.ipynb` | Interactive development: submit jobs, monitor status, inspect results |
| `scripts/submit_job.py` | Called by Deploy to NeMo workflow; reads `job_config.yaml` |
| `scripts/cancel_job.py` | Called by Undeploy from NeMo workflow |

## Workflows

Require NeMo running on DGX (`nemo-microservices` namespace). Trigger **NeMo Deploy** in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

| Workflow | Input | Effect |
|---|---|---|
| **Deploy to NeMo** | `job_name` (optional) | Submit training job from `job_config.yaml` |
| **Undeploy from NeMo** | `job_name` | Cancel a job |

## Configuring the job

Edit `job_config.yaml` — set your model, dataset path, and hyperparameters. The
`deploy-nemo.yaml` workflow reads this file and calls `scripts/submit_job.py`.

The job is submitted to `http://nemo.test/v1/customization/jobs`. The NeMo SDK
equivalent is:

```python
from nemo_microservices import NeMoMicroservices
client = NeMoMicroservices(base_url='http://nemo.test:8082')
job = client.customization.jobs.create(name=..., model=..., ...)
```

## NeMo API access

SSH tunnel: `ssh -L 8082:localhost:8082 spark-79b7.local`  
Laptop `/etc/hosts`: `127.0.0.1 nemo.test nim.test data-store.test`

Useful checks:
```sh
curl http://nemo.test:8082/v1/customization/jobs         # list jobs
curl http://nemo.test:8082/v1/models                     # list base models
curl http://data-store.test:8082/v1/health               # data store health
```

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
