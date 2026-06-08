# Project Implementation Workbook

Steps to go from the scaffold to a running pipeline.

---

## 1. `pipeline.py` — replace the GPU workload

Open `pipeline.py` and replace the `WORKLOAD` string in `gpu_stage` with your actual GPU body.
The string is executed as a standalone Python script under `python3 /tmp/body.py`, so it must
be fully self-contained (all imports inside it).

```python
WORKLOAD = """\
import torch
import nvtx

# Your GPU code here — runs both normally (exec) and under nsys (subprocess)
with nvtx.annotate("my_stage", color="green"):
    result = my_model(inputs)
    torch.cuda.synchronize()

print(f"Result: {result}")
"""
```

Key rules:
- All imports inside the string
- `torch.cuda.synchronize()` at the end of each logical block (required for accurate profiling)
- NVTX annotations around logical sections (`nvtx.annotate` or `nvtx.push_range` / `nvtx.pop_range`)
- The `exec(WORKLOAD)` path in the `else` branch runs in the component's Python process directly

---

## 2. Rename the component (optional)

`gpu_stage` is a placeholder name. Rename it to match your workload:

```python
# pipeline.py
def my_inference_stage(run_id: str, profile: bool = False):
    ...

def pipeline(run_id: str = "run-001", profile: bool = False):
    task = my_inference_stage(run_id=run_id, profile=profile)
    ...
```

---

## 3. Add pipeline parameters (if needed)

Add parameters to both the component and the pipeline function:

```python
def my_stage(run_id: str, model_id: str, profile: bool = False):
    ...

def pipeline(run_id: str = "run-001", model_id: str = "my-model", profile: bool = False):
    task = my_stage(run_id=run_id, model_id=model_id, profile=profile)
    ...
```

Update `scripts/deploy_pipeline.py` to pass any new args in the `arguments={}` dict.

---

## 4. Add more stages (if needed)

Chain multiple components by passing outputs as inputs:

```python
@dsl.component(base_image="nvcr.io/nvidia/pytorch:25.03-py3", ...)
def stage_b(input_path: str, run_id: str) -> float:
    ...

def pipeline(run_id: str = "run-001", profile: bool = False):
    a = stage_a(run_id=run_id, profile=profile)
    a.set_gpu_limit(1).set_memory_limit("64G")
    k8s_ext.mount_pvc(a, pvc_name="nsight-reports", mount_path="/nsight-reports")

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

## 6. Deploy + profile

```bash
# Normal run
python3 scripts/purge_kfp.py
python3 scripts/deploy_pipeline.py --run-name run-001

# With nsys GPU profiling
python3 scripts/purge_kfp.py
python3 scripts/deploy_pipeline.py --run-name run-001 --profile
```

Profile output lands at `~/shared/nsight/{{PROJECT_NAME}}/run-001/main/summaries.csv`.

---

## 7. Update `docs/VALIDATION_STATUS.md`

After each run, update the run table and status section in `docs/VALIDATION_STATUS.md`.
