# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a Kubeflow Pipelines fine-tuning project on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File | Purpose |
|---|---|
| `notebook.ipynb` | Source of truth — develop step logic here, then run the Build cell to regenerate `pipeline.py` |
| `pipeline.py` | Generated from notebook — do not edit manually |
| `scripts/deploy_pipeline.py` | Called by Deploy to KFP workflow |
| `scripts/terminate_pipeline.py` | Called by Undeploy from KFP workflow |

## Workflows

Require KFP running on DGX (`kubeflow` namespace). Trigger **Kubeflow Deploy** in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

| Workflow | Input | Effect |
|---|---|---|
| **Deploy to KFP** | `run_name` | Compile `pipeline.py` → upload → submit run |
| **Undeploy from KFP** | `run_id` | Terminate a run |

Click the **Open in JupyterLab** badge in the README to open `notebook.ipynb` directly (requires SSH tunnel).

## Development workflow

1. Open `notebook.ipynb` in JupyterLab
2. Write step logic in each `@dsl.component` function body under **Step Development**
3. Wire steps in the **Pipeline** cell
4. Save the notebook (`Ctrl+S`), then run **Build → pipeline.py**
5. Compile and submit in the **Compile & Submit** section

### Component rules

- **Imports must be inside the function body** — KFP runs each component in its own container
- Set `base_image` and `packages_to_install` on `@dsl.component` to match your step's runtime
- Use `Input[Dataset]`, `Output[Model]`, etc. to pass artifacts between steps

### Quick pattern

```python
@dsl.component(base_image="python:3.11-slim", packages_to_install=["my-dep"])
def my_step(input_data: Input[Dataset], output_model: Output[Model]):
    import my_dep  # import inside the function
    # step logic here
```

Compile locally to inspect before submitting:

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
