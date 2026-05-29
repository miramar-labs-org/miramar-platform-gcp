# {{PROJECT_NAME}}

<!-- One-line description of this project -->

## Prerequisites

- KFP running on DGX: trigger **Kubeflow Deploy** in [miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
- NeMo running on DGX (for NeMo workflows): trigger **NeMo Deploy**

## Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| **Deploy to KFP** | Actions → Deploy to KFP | Compiles `pipeline.py`, uploads to KFP, submits a run |
| **Undeploy from KFP** | Actions → Undeploy from KFP | Terminates a run by ID |
| **Deploy to NeMo** | Actions → Deploy to NeMo | Submits a training job to NeMo Microservices |
| **Undeploy from NeMo** | Actions → Undeploy from NeMo | Cancels a NeMo job by name |

## Project structure

```
pipeline.py          ← KFP v2 pipeline definition — edit this
notebook.ipynb       ← Development notebook
scripts/
  deploy_pipeline.py    ← Called by deploy-kfp workflow
  terminate_pipeline.py ← Called by undeploy-kfp workflow
.github/workflows/
  deploy-kfp.yaml
  undeploy-kfp.yaml
  deploy-nemo.yaml
  undeploy-nemo.yaml
```

## KFP UI access

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# open http://localhost:8080
```

## Customising the NeMo job payload

The `deploy-nemo.yaml` workflow contains a `TODO` comment marking the training
job payload. Adjust the JSON structure to match your model and dataset before
running it for the first time.
