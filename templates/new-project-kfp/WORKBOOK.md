# Project Implementation Workbook

Steps to go from the scaffold to a running pipeline.

---

## 1. `pipeline.py` — replace the GPU workload

Open `pipeline.py` and replace the `gpu_stage` component body with your actual GPU code.
Add NVTX annotations around logical sections — they appear in the Nsight timeline if you profile.

```python
@dsl.component(base_image="nvcr.io/nvidia/pytorch:26.04-py3", packages_to_install=["nvtx"])
def gpu_stage(run_id: str):
    import torch, nvtx
    with nvtx.annotate("my_workload", color="green"):
        result = my_model(inputs)
        torch.cuda.synchronize()
    print(f"Result: {result}")
```

Key rules:
- All imports inside the function body (each component runs in its own container)
- `torch.cuda.synchronize()` at the end of each logical block (accurate timing)
- NVTX annotations make bottlenecks visible in Nsight Operator captures

---

## 2. Rename the component (optional)

`gpu_stage` is a placeholder name. Rename it to match your workload:

```python
def my_inference_stage(run_id: str):
    ...

def pipeline(run_id: str = "run-001"):
    task = my_inference_stage(run_id=run_id)
    task.set_gpu_limit(1).set_memory_limit("64G")
```

---

## 3. Add pipeline parameters (if needed)

Add parameters to both the component and the pipeline function:

```python
def my_stage(run_id: str, model_id: str):
    ...

def pipeline(run_id: str = "run-001", model_id: str = "my-model"):
    task = my_stage(run_id=run_id, model_id=model_id)
```

Update `scripts/deploy_pipeline.py` to pass any new args in the `arguments={}` dict.

---

## 4. Add more stages (if needed)

Chain multiple components by passing outputs as inputs:

```python
@dsl.component(base_image="nvcr.io/nvidia/pytorch:26.04-py3")
def stage_b(input_path: str, run_id: str) -> float:
    ...

def pipeline(run_id: str = "run-001"):
    a = stage_a(run_id=run_id)
    a.set_gpu_limit(1).set_memory_limit("64G")

    b = stage_b(input_path=a.output, run_id=run_id)
    b.set_gpu_limit(1).set_memory_limit("64G")
```

---

## 5. Compile check

```bash
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

---

## 6. Deploy

```bash
python3 scripts/purge_kfp_mlflow.py
python3 scripts/deploy_pipeline.py --run-name run-001
```

To profile the GPU stage with the Nsight Operator, set the toggle in `config.yaml` (the
notebook's pipeline cell reads it and labels the stage pod — do not hand-edit `pipeline.py`):

```yaml
profiling:
  enabled: true
  collection_window_s: 90
```

The operator injects `nsys` and writes the report to its internal MinIO. Pull it onto disk by
firing the export the **instant** the stage pod is `Running` — on GB10 hw-trace the operator
only retrieves GPU-side kernel timestamps when the collect is triggered within the stage
process's first few seconds. Trigger it ~60s in (or let `gpu_stage` idle before its compute)
and the report comes back kernel-less even though the GPU is saturated. A bigger
`collection_window_s` does **not** fix that; keep the GPU work on `gpu_stage`'s first line.

```bash
/nsight-export {{PROJECT_NAME}} run-001 main
# → ~/shared/nsight/{{PROJECT_NAME}}/run-001/main/profile.nsys-rep (+ auto /nsight-interpret)
```

---

## 7. Update `docs/VALIDATION_STATUS.md`

After each run, update the run table and status section in `docs/VALIDATION_STATUS.md`.
