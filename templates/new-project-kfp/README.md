# {{PROJECT_NAME}}

<!-- One-line description of this project -->

**Type**: Kubeflow Pipelines

## Prerequisites

KFP running on DGX — trigger **Kubeflow Deploy** in [miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

## Workflows

| Workflow | Input | Effect |
|---|---|---|
| **Open in JupyterLab** | — | Clone/pull repo to DGX `~/git-miramar-labs-org/projects/`, print direct URL |
| **Deploy to KFP** | `run_name` | Compile `pipeline.py` → upload → submit run; prints `run_id` |
| **Undeploy from KFP** | `run_id` | Terminate a KFP run |

## Project structure

```
pipeline.py          ← KFP v2 pipeline definition — edit this
notebook.ipynb       ← Development notebook
scripts/
  deploy_pipeline.py    ← Called by Deploy to KFP workflow
  terminate_pipeline.py ← Called by Undeploy from KFP workflow
```

---

## Developer guide: filling out the notebook

### 1. Open in JupyterLab

Trigger **Open in JupyterLab** from the Actions tab. It clones/pulls this repo to
`~/git-miramar-labs-org/projects/{{PROJECT_NAME}}` on the DGX and prints a direct link in the workflow summary.

Then open: [http://localhost:8888/lab/tree/git-miramar-labs-org/projects/{{PROJECT_NAME}}](http://localhost:8888/lab/tree/git-miramar-labs-org/projects/{{PROJECT_NAME}})

### 2. Define your pipeline in `pipeline.py`

Replace the hello-world stub with your own components. Each `@dsl.component`
function runs as an isolated container step:

```python
from kfp import dsl

@dsl.component(
    base_image="python:3.11-slim",
    packages_to_install=["pandas", "scikit-learn"],
)
def preprocess(data_path: str) -> str:
    import pandas as pd
    df = pd.read_csv(data_path)
    # ... your preprocessing logic ...
    output = "/tmp/processed.parquet"
    df.to_parquet(output)
    return output

@dsl.component(base_image="python:3.11-slim", packages_to_install=["scikit-learn"])
def train(data_path: str) -> float:
    # ... training logic ...
    return accuracy

@dsl.pipeline(name="{{PROJECT_NAME}}")
def pipeline(data_path: str = ""):
    processed = preprocess(data_path=data_path)
    train(data_path=processed.output)
```

### 3. Compile and inspect in the notebook

```python
from kfp import compiler
from pipeline import pipeline
compiler.Compiler().compile(pipeline_func=pipeline, package_path='/tmp/pipeline.yaml')
```

Open `/tmp/pipeline.yaml` to verify the DAG structure before submitting.

### 4. Connect to KFP and submit a run

```python
import kfp
client = kfp.Client(host='http://localhost:8080')

run = client.create_run_from_pipeline_package(
    pipeline_file='/tmp/pipeline.yaml',
    arguments={"data_path": "/path/to/data"},
    run_name="my-run",
)
print(f"Run ID: {run.run_id}")
```

### 5. Monitor the run

- **KFP UI**: [http://localhost:8080](http://localhost:8080) → Runs → select your run
- **Notebook poll**:
  ```python
  import time
  for _ in range(20):
      r = client.get_run(run.run_id)
      print(r.state)
      if r.state in ('SUCCEEDED', 'FAILED', 'CANCELED'):
          break
      time.sleep(15)
  ```

### 6. CI/CD via GitHub Actions

When your pipeline is ready, trigger **Deploy to KFP** from the Actions tab.
The workflow compiles `pipeline.py`, uploads it to KFP, and submits a run.
The run ID is printed in the workflow summary.

---

## UI endpoints

| UI | URL | Notes |
|---|---|---|
| KFP Pipelines | [http://localhost:8080](http://localhost:8080) | Requires SSH tunnel `-L 8080:localhost:8080` |
| JupyterLab | [http://localhost:8888](http://localhost:8888) | Requires SSH tunnel `-L 8888:localhost:8888` |
| Kubernetes dashboard | [http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/](http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/) | Requires SSH tunnel `-L 8001:localhost:8001` |
