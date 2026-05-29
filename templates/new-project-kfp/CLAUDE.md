# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a Kubeflow Pipelines project on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File | Purpose |
|---|---|
| `pipeline.py` | KFP v2 pipeline definition — `pipeline()` is compiled and submitted |
| `notebook.ipynb` | Interactive development: compile, inspect, submit, monitor runs |
| `scripts/deploy_pipeline.py` | Called by Deploy to KFP workflow |
| `scripts/terminate_pipeline.py` | Called by Undeploy from KFP workflow |

## Workflows

Require KFP running on DGX (`kubeflow` namespace). Trigger **Kubeflow Deploy** in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

| Workflow | Input | Effect |
|---|---|---|
| **Deploy to KFP** | `run_name` | Compile `pipeline.py` → upload → submit run |
| **Undeploy from KFP** | `run_id` | Terminate a run |

## Editing the pipeline

Define components with `@dsl.component` and wire them in the `@dsl.pipeline` function
named `pipeline`. The scaffold ships a hello-world component to replace.

```python
from kfp import dsl

@dsl.component(base_image="python:3.11-slim", packages_to_install=["my-dep"])
def my_step(x: str) -> str:
    ...

@dsl.pipeline(name="{{PROJECT_NAME}}")
def pipeline(x: str = "default"):
    my_step(x=x)
```

Compile locally to inspect the YAML before submitting:

```sh
python3 -c "from kfp import compiler; from pipeline import pipeline; compiler.Compiler().compile(pipeline, '/tmp/p.yaml')"
```

## KFP UI access

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# http://localhost:8080
```

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
