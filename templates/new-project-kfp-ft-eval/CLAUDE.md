# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a KFP v2 eval-first fine-tuning pipeline on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File | Purpose |
|---|---|
| `config.yaml` | Project config — model ID, datasets, LoRA params, eval thresholds, judge prompt |
| `formatters.py` | Dataset formatters — one function per dataset, registered in `FORMATTERS` dict |
| `notebook.ipynb` | Source of truth — develop step logic here, run the Build cell to regenerate `pipeline.py` |
| `pipeline.py` | Generated from notebook — **do not edit manually** |
| `scripts/deploy_pipeline.py` | Compile, register, and submit a run (called by Deploy to KFP workflow) |
| `scripts/terminate_pipeline.py` | Terminate a run by ID (called by Undeploy from KFP workflow) |

## Editing config.yaml

`config.yaml` drives the pipeline parameter defaults. After editing:

1. Open `notebook.ipynb` and run the **Build → `pipeline.py`** cell (notebook imports config at pipeline cell run time)
2. Compile check: `python3 -c "from kfp import compiler; from pipeline import pipeline; compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"`
3. Commit and trigger **Deploy to KFP** — or run `python3 scripts/deploy_pipeline.py` directly

## Writing formatters

Each formatter in `formatters.py`:

```python
def format_my_dataset(example):
    # example: a single row dict from the HuggingFace dataset
    return {
        "instruction": str,   # prompt / question
        "response": str,      # expected answer
        "source": str,        # dataset name (for traceability)
    }
```

Register it in `FORMATTERS` with the same key as the `name:` in `config.yaml`:

```python
FORMATTERS = {
    "my-dataset": format_my_dataset,
}
```

The Build cell inlines the entire `formatters.py` file into the `prepare_dataset` component body.
Any imports used by the formatters must be available in the component container — add them to
`prepare_dataset`'s `packages_to_install`.

## Adding a new dataset

1. Add entry to `config.yaml` under `datasets:`
2. Add formatter to `formatters.py` and register in `FORMATTERS`
3. Implement the load logic in `prepare_dataset` (find the `TODO` in that cell)
4. Run Build cell → compile check → deploy

## Workflows

Require KFP running on DGX (`kubeflow` namespace). Trigger **Kubeflow Deploy** in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) first.

| Workflow | Input | Effect |
|---|---|---|
| **Deploy to KFP** | `run_name` | Compile `pipeline.py` → register → submit run |
| **Undeploy from KFP** | `run_id` | Terminate a run |

## Component rules

- **All imports must be inside the function body** — each component runs in its own container
- `packages_to_install` on `@dsl.component` is the only way to add dependencies to a component
- GPU steps: `.set_gpu_limit(1).set_memory_limit("64G")` in the pipeline cell
- Secret env vars (HF_TOKEN, OPENAI_API_KEY, etc.) are injected from the `mlabs-api-keys` K8s secret
  via `k8s_ext.use_secret_as_env` — no manual setup needed, the platform provisions the secret

## Compile check

```sh
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

## KFP UI access

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# → http://localhost:8080
```

## MLflow access

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
# → http://localhost:5000  (use ML experiment type, not GenAI apps & agents)
```

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
