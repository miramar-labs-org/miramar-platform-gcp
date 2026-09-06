# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a Kubeflow Pipelines project on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File                            | Purpose                                                                                             |
| ------------------------------- | --------------------------------------------------------------------------------------------------- |
| `notebook.ipynb`                | Source of truth — define components in tagged cells, run the Build cell to regenerate `pipeline.py` |
| `pipeline.py`                   | Generated from notebook — **do not edit manually** (gitignored)                                     |
| `scripts/build_pipeline.py`     | Assemble `pipeline.py` from tagged notebook cells                                                   |
| `scripts/deploy_pipeline.py`    | Compile + submit a run                                                                              |
| `scripts/terminate_pipeline.py` | Called by Undeploy from KFP workflow                                                                |
| `scripts/purge_kfp_mlflow.py`   | Purge all runs + pipeline versions before redeploy                                                  |

## Slash commands

| Command                      | What it does                                                           |                                                     |
| ---------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------- |
| `/kfp-monitor [run-NNN]`     | Self-paced monitoring loop — checks pods, appends to `runs/run-NNN.md` |                                                     |
| `/nsight-export <project> <run-NNN> <stage>` | Pull a profiled stage's Nsight report from MinIO into `~/shared/nsight/` + auto `/nsight-interpret` |     |
| `/nsight-interpret [run-NNN\ | path]`                                                                 | Interpret an Nsight Systems `.nsys-rep` with an LLM |

## Workflows

Require KFP running on DGX (`kubeflow` namespace). Trigger **Kubeflow Deploy** in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

| Workflow              | Input      | Effect                                      |
| --------------------- | ---------- | ------------------------------------------- |
| **Deploy to KFP**     | `run_name` | Compile `pipeline.py` → upload → submit run |
| **Undeploy from KFP** | `run_id`   | Terminate a run                             |

## Deploy cycle

```bash
# Always purge before redeploy
python3 scripts/purge_kfp_mlflow.py

# Normal run
python3 scripts/deploy_pipeline.py --run-name run-001
```

## Editing the pipeline

`pipeline.py` ships a GPU-capable stub using the NGC PyTorch base image. Replace
`gpu_stage` with your own components. For non-GPU stages, swap to `base_image="python:3.11-slim"`.

```python
from kfp import dsl

@dsl.component(base_image="python:3.11-slim", packages_to_install=["my-dep"])
def my_step(x: str) -> str:
    ...

@dsl.pipeline(name="{{PROJECT_NAME}}")
def pipeline(run_id: str = "run-001"):
    my_step(x=run_id)
```

To profile the GPU stage with the Nsight Operator, set `profiling.enabled: true` in
`config.yaml` — the notebook's pipeline cell reads it and calls
`kubernetes.add_pod_label(task, "nvidia-nsight-profile", "enabled")` on the stage. The
operator writes the report to its internal MinIO; `/nsight-export {{PROJECT_NAME}} run-NNN
main` archives it to `~/shared/nsight/` and auto-runs `/nsight-interpret`.

**Do not label the kubeflow namespace** (`nvidia-nsight-profile=enabled` at namespace level) — it injects nsys into ALL pods including KFP's own DAG driver pods, which fail with `runAsNonRoot`. Per-pod labels are the only correct approach.

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
