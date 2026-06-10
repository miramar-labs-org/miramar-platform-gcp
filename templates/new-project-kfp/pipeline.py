"""
KFP v2 pipeline definition.

Edit this file to define your pipeline. The function named `pipeline` is
what deploy-kfp.yaml compiles and submits — keep that name.

Nsight Operator profiling pattern:
  - Add kubernetes.add_pod_label(task, "nvidia-nsight-profile", "enabled")
    to any stage you want profiled — the Nsight Operator injector handles
    the rest at pod creation time. No nsys code needed here.
  - Requires the Nsight Operator deployed and kubeflow namespace labeled:
      gh workflow run deploy-nsight-operator.yaml --repo miramar-labs-org/miramar-platform-gcp
"""

from kfp import dsl
from kfp import kubernetes


@dsl.component(
    base_image="nvcr.io/nvidia/pytorch:26.04-py3",
    packages_to_install=["nvtx"],
)
def gpu_stage(run_id: str):
    import torch
    import nvtx

    # ── Replace this block with your GPU workload ─────────────────────────
    with nvtx.annotate("gpu_stage", color="green"):
        x = torch.randn(2048, 2048, device="cuda")
        result = x @ x.T
        torch.cuda.synchronize()

    print(f"Result norm: {result.norm().item():.4f}")
    # ─────────────────────────────────────────────────────────────────────


@dsl.pipeline(
    name="{{PROJECT_NAME}}",
    description="GPU pipeline — replace gpu_stage with your workload.",
)
def pipeline(run_id: str = "run-001"):
    task = gpu_stage(run_id=run_id)
    task.set_gpu_limit(1).set_memory_limit("64G")
    # Uncomment to enable Nsight Operator profiling for this stage:
    # kubernetes.add_pod_label(task, label_key="nvidia-nsight-profile", label_value="enabled")
