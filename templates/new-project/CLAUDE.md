# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — an ML project on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description of this project. -->

## Platform

- **KFP**: Kubeflow Pipelines 2.x running on DGX minikube (`kubeflow` namespace)
- **NeMo**: NeMo Microservices running on DGX minikube (`nemo-microservices` namespace)
- **Platform repo**: [miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)

## Key files

| File | Purpose |
|---|---|
| `pipeline.py` | KFP v2 pipeline definition — the `pipeline()` function is what gets compiled and submitted |
| `notebook.ipynb` | Development notebook; compile and inspect the pipeline interactively |
| `scripts/deploy_pipeline.py` | Called by the Deploy to KFP workflow — compiles `pipeline.py`, uploads, submits a run |
| `scripts/terminate_pipeline.py` | Called by the Undeploy from KFP workflow — terminates a run by ID |

## Workflows

All four workflows run on the DGX (`[self-hosted, dgx]`) and require the relevant platform to be deployed first.

| Workflow | Input | Effect |
|---|---|---|
| **Deploy to KFP** | `run_name` | Compile `pipeline.py` → upload → submit run; prints `run_id` to summary |
| **Undeploy from KFP** | `run_id` | Terminate a KFP run |
| **Deploy to NeMo** | `job_name`, `model`, `dataset_path`, `num_epochs` | POST training job to `http://nemo.test/v1/jobs` |
| **Undeploy from NeMo** | `job_name` | DELETE NeMo job |

## Working on the pipeline

Edit `pipeline.py` — define your components with `@dsl.component` and wire them in the `@dsl.pipeline` function named `pipeline`. The scaffold has a hello-world example to replace.

```python
from kfp import dsl

@dsl.component(base_image="python:3.11-slim", packages_to_install=["your-dep"])
def my_step(input: str) -> str:
    ...

@dsl.pipeline(name="{{PROJECT_NAME}}")
def pipeline(input: str = "default"):
    my_step(input=input)
```

To compile and inspect locally (requires `pip install kfp`):

```sh
python3 -c "
from kfp import compiler
from pipeline import pipeline
compiler.Compiler().compile(pipeline, '/tmp/pipeline.yaml')
"
cat /tmp/pipeline.yaml
```

## Accessing the platform UIs

SSH tunnel from your laptop:

```sh
ssh -L 8080:localhost:8080 -L 8082:localhost:8082 <user>@spark-79b7.local
```

- KFP UI: `http://localhost:8080`
- NeMo APIs: `http://nemo.test:8082/v1/...` (add `127.0.0.1 nemo.test` to laptop `/etc/hosts`)

## NeMo job payload

The `deploy-nemo.yaml` workflow contains a `# TODO` comment marking the training job
payload — adjust it for your model and dataset before first use. See the
[NeMo Microservices Jobs API](https://docs.nvidia.com/nemo/microservices/latest/) for
the full schema.

## Prerequisites

Before triggering any workflow, confirm the target platform is running on the DGX:

- KFP workflows → trigger **Kubeflow Deploy** in miramar-platform-gcp first
- NeMo workflows → trigger **NeMo Deploy** in miramar-platform-gcp first
