"""
KFP v2 pipeline definition.

Edit this file to define your pipeline. The function named `pipeline` is
what deploy-kfp.yaml compiles and submits — keep that name.

GPU + nsys profiling pattern:
  - Replace the WORKLOAD string with your GPU body (imports included).
  - Deploy normally:          python3 scripts/deploy_pipeline.py --run-name run-001
  - Deploy with profiling:    python3 scripts/deploy_pipeline.py --run-name run-001 --profile
  - Profiling output:         ~/shared/nsight/{{PROJECT_NAME}}/<run-name>/main/
  - Interpret results:        /nsight-interpret run-001
"""

from kfp import dsl
from kfp import kubernetes as k8s_ext


@dsl.component(
    base_image="nvcr.io/nvidia/pytorch:26.04-py3",
    packages_to_install=["nvtx"],
)
def gpu_stage(run_id: str, profile: bool = False):
    import os
    import subprocess
    from pathlib import Path

    NSIGHT_DIR = Path(f"/nsight-reports/{{PROJECT_NAME}}/{run_id}/main")

    # ── Replace this block with your GPU workload ─────────────────────────
    WORKLOAD = """\
import torch
import nvtx

with nvtx.annotate("gpu_stage", color="green"):
    x = torch.randn(2048, 2048, device="cuda")
    result = x @ x.T
    torch.cuda.synchronize()

print(f"Result norm: {result.norm().item():.4f}")
"""
    # ─────────────────────────────────────────────────────────────────────

    if profile:
        os.environ["NVIDIA_DRIVER_CAPABILITIES"] = "all"
        os.environ["NVIDIA_VISIBLE_DEVICES"] = "all"
        Path("/tmp/body.py").write_text(WORKLOAD)
        proc = subprocess.run(
            [
                "nsys", "profile",
                "--trace=cuda,nvtx,cublas,cudnn",
                "--sample=none",
                "--cuda-flush-interval=10000",
                "--force-overwrite=true",
                "-o", "/tmp/profile",
                "python3", "/tmp/body.py",
            ],
            capture_output=True, text=True,
        )
        print(proc.stdout)
        if proc.returncode != 0:
            print("nsys stderr:", proc.stderr)
        # Copy report even if workload crashed — nsys generates it regardless
        rep = Path("/tmp/profile.nsys-rep")
        if not rep.exists():
            raise RuntimeError("nsys did not generate a .nsys-rep — profiling failed entirely")
        subprocess.run(
            ["cp", "/tmp/profile.nsys-rep", str(NSIGHT_DIR / "profile.nsys-rep")],
            check=True,
        )
        lines = []
        for r in ["cuda_gpu_kern_sum", "cuda_api_sum", "cuda_gpu_mem_time_sum", "nvtx_sum"]:
            lines.append(f"=== {r} ===\n")
            res = subprocess.run(
                ["nsys", "stats", "--report", r,
                 str(NSIGHT_DIR / "profile.nsys-rep")],
                capture_output=True, text=True,
            )
            lines.append(res.stdout if res.returncode == 0 else f"(exit {res.returncode}): {res.stderr[:200]}\n")
        (NSIGHT_DIR / "summaries.csv").write_text("".join(lines))
        print(f"Profiling output: {NSIGHT_DIR}")
    else:
        exec(WORKLOAD)


@dsl.pipeline(
    name="{{PROJECT_NAME}}",
    description="GPU pipeline — replace gpu_stage with your workload.",
)
def pipeline(run_id: str = "run-001", profile: bool = False):
    task = gpu_stage(run_id=run_id, profile=profile)
    task.set_gpu_limit(1).set_memory_limit("64G")
    k8s_ext.mount_pvc(task, pvc_name="nsight-reports", mount_path="/nsight-reports")
