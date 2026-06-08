# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a Kubeflow Pipelines project on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File | Purpose |
|---|---|
| `pipeline.py` | KFP v2 pipeline definition — `pipeline()` is compiled and submitted |
| `notebook.ipynb` | Interactive development: compile, inspect, submit, monitor runs |
| `scripts/deploy_pipeline.py` | Compile + submit; `--profile` enables nsys GPU profiling |
| `scripts/terminate_pipeline.py` | Called by Undeploy from KFP workflow |
| `scripts/purge_kfp.py` | Purge all runs + pipeline versions before redeploy |
| `scripts/purge_nsight.py` | Clean up large nsys artifacts from `~/shared/nsight/` |

## Slash commands

| Command | What it does |
|---|---|
| `/kfp-monitor [run-NNN]` | Self-paced monitoring loop — checks pods, appends to `runs/run-NNN.md` |
| `/nsight-interpret [run-NNN\|path]` | Interpret an Nsight Systems `.nsys-rep` with an LLM |

## Workflows

Require KFP running on DGX (`kubeflow` namespace). Trigger **Kubeflow Deploy** in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

| Workflow | Input | Effect |
|---|---|---|
| **Deploy to KFP** | `run_name` | Compile `pipeline.py` → upload → submit run |
| **Undeploy from KFP** | `run_id` | Terminate a run |

## Deploy cycle

```bash
# Always purge before redeploy
python3 scripts/purge_kfp.py

# Normal run
python3 scripts/deploy_pipeline.py --run-name run-001

# With nsys GPU profiling
python3 scripts/deploy_pipeline.py --run-name run-001 --profile
```

## Editing the pipeline

`pipeline.py` ships a GPU-capable stub using the NGC PyTorch base image. Replace the
`WORKLOAD` string in `gpu_stage` with your GPU body. For non-GPU stages, swap to
`base_image="python:3.11-slim"` and drop the nsys/PVC boilerplate.

```python
from kfp import dsl

@dsl.component(base_image="python:3.11-slim", packages_to_install=["my-dep"])
def my_step(x: str) -> str:
    ...

@dsl.pipeline(name="{{PROJECT_NAME}}")
def pipeline(run_id: str = "run-001", profile: bool = False):
    my_step(x=run_id)
```

Compile check:

```sh
python3 -c "from kfp import compiler; from pipeline import pipeline; compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

## KFP UI access

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# http://localhost:8080
```

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
