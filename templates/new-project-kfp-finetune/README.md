# {{PROJECT_NAME}}

[![Open in JupyterLab](https://img.shields.io/badge/Open%20in-JupyterLab-F37626?logo=jupyter&logoColor=white)]({{JL_URL}})

<!-- One-line description of this project -->

**Type**: KFP v2 fine-tuning pipeline

## Prerequisites

KFP running on DGX — trigger **Kubeflow Deploy** in [miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

## Workflows

| Workflow | Input | Effect |
|---|---|---|
| **Deploy to KFP** | `run_name` | Compile `pipeline.py` → upload → submit run; prints `run_id` |
| **Undeploy from KFP** | `run_id` | Terminate a KFP run |

## Project structure

```
notebook.ipynb       ← Source of truth — develop steps here, then build pipeline.py
pipeline.py          ← Generated from notebook — do not edit manually
scripts/
  deploy_pipeline.py    ← Called by Deploy to KFP workflow
  terminate_pipeline.py ← Called by Undeploy from KFP workflow
```

---

## Developer guide

### 1. Open in JupyterLab

Click the badge above or open: [{{JL_URL}}]({{JL_URL}})

### 2. Develop step logic in the notebook

Edit each `@dsl.component` function body under **Step Development** in `notebook.ipynb`.
Rename functions and update signatures as needed. All imports must be inside the function body.

### 3. Wire the pipeline

Update the **Pipeline** cell to connect step outputs to the next step's inputs:

```python
@dsl.pipeline(name="{{PROJECT_NAME}}")
def pipeline():
    t1 = step_1()
    t2 = step_2(input_data=t1.outputs["output_data"])
    # ... and so on
```

### 4. Build pipeline.py

Save the notebook (`Ctrl+S`), then run the **Build → pipeline.py** cell.

### 5. Compile and submit

Run the **Compile & Submit** cells to verify locally before deploying via GitHub Actions.

### 6. CI/CD via GitHub Actions

When your pipeline is ready, trigger **Deploy to KFP** from the Actions tab.
The workflow compiles `pipeline.py`, uploads it to KFP, and submits a run.

---

## UI endpoints

| UI | URL | Notes |
|---|---|---|
| KFP Pipelines | [http://localhost:8080](http://localhost:8080) | Requires SSH tunnel `-L 8080:localhost:8080` |
| JupyterLab | [http://localhost:8888](http://localhost:8888) | Requires SSH tunnel `-L 8888:localhost:8888` |
| Kubernetes dashboard | [http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/](http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/) | Requires SSH tunnel `-L 8001:localhost:8001` |
