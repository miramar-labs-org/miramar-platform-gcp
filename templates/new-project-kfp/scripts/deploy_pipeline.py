#!/usr/bin/env python3
"""
Compile pipeline.py and submit a run to KFP.

Usage:
  python3 scripts/deploy_pipeline.py --run-name run-001
  python3 scripts/deploy_pipeline.py --run-name run-002 --profile
  python3 scripts/deploy_pipeline.py --run-name run-003 --profile --profile-stage gpu-stage

Profile flags:
  --profile             Enable nsys GPU profiling for this run.
  --profile-stage NAME  Name of the stage subdir under ~/shared/nsight/<project>/<run>/.
                        Default: "main"

Env vars (override CLI):
  KFP_HOST   - KFP API server URL  (default: http://localhost:8890)
  RUN_NAME   - display name for the run
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-name", default=None)
    parser.add_argument("--host", default=None)
    parser.add_argument("--profile", action="store_true",
                        help="Enable nsys GPU profiling for this run")
    parser.add_argument("--profile-stage", default="main",
                        help="Stage subdir name under the nsight output dir (default: main)")
    args = parser.parse_args()

    host = args.host or os.environ.get("KFP_HOST", "http://localhost:8890")
    run_name = args.run_name or os.environ.get("RUN_NAME", "pipeline-run")

    # ── Pre-create nsight output dir (if profiling) ───────────────────────
    if args.profile:
        project = Path.cwd().name
        nsight_dir = (Path.home() / "shared" / "nsight" / project /
                      run_name / args.profile_stage)
        nsight_dir.mkdir(parents=True, exist_ok=True)
        nsight_dir.chmod(0o777)
        nsight_dir.parent.chmod(0o777)
        print(f"Pre-created nsight dir (0777): {nsight_dir}")

    # ── Compile ───────────────────────────────────────────────────────────
    spec = importlib.util.spec_from_file_location("pipeline", "pipeline.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    pipeline_fn = mod.pipeline

    from kfp import compiler
    pipeline_yaml = "/tmp/compiled-pipeline.yaml"
    pipeline_name = Path.cwd().name
    compiler.Compiler().compile(pipeline_func=pipeline_fn, package_path=pipeline_yaml)
    print(f"Compiled: {pipeline_yaml}")

    # ── Register + submit ─────────────────────────────────────────────────
    import kfp
    client = kfp.Client(host=host)

    try:
        client.upload_pipeline(
            pipeline_package_path=pipeline_yaml,
            pipeline_name=pipeline_name,
        )
        print(f"Pipeline registered: {pipeline_name}")
    except Exception as e:
        print(f"Note: pipeline registration skipped ({type(e).__name__})", file=sys.stderr)

    run_response = client.create_run_from_pipeline_package(
        pipeline_file=pipeline_yaml,
        arguments={"run_id": run_name, "profile": args.profile},
        run_name=run_name,
    )
    run_id = run_response.run_id
    print(f"Run submitted — ID: {run_id}")
    print(f"UI: {host}/#/runs/details/{run_id}")

    # ── Patch Argo Workflow for privileged CUPTI access ───────────────────
    if args.profile:
        # nvidia.com/gpu: "1" ensures the NVIDIA device plugin properly initialises
        # CUPTI and driver capabilities — without this, KFP's set_gpu_limit(1)
        # generates a generic accelerator spec that never requests the GPU resource
        # and CUPTI tracing is silently skipped.
        pod_spec_patch = (
            "containers:\n"
            "- name: main\n"
            "  securityContext:\n"
            "    privileged: true\n"
            "    allowPrivilegeEscalation: true\n"
            "    seccompProfile:\n"
            "      type: Unconfined\n"
            "  env:\n"
            "  - name: NVIDIA_DRIVER_CAPABILITIES\n"
            "    value: \"all\"\n"
            "  - name: NVIDIA_VISIBLE_DEVICES\n"
            "    value: \"all\"\n"
            "  resources:\n"
            "    limits:\n"
            "      nvidia.com/gpu: \"1\"\n"
            "    requests:\n"
            "      nvidia.com/gpu: \"1\"\n"
        )
        patch_payload = json.dumps({"spec": {"podSpecPatch": pod_spec_patch}})
        workflow_name = None
        for _ in range(30):
            result = subprocess.run(
                ["kubectl", "get", "workflows", "-n", "kubeflow",
                 "-l", f"pipeline/runid={run_id}", "-o", "name"],
                capture_output=True, text=True,
            )
            if result.stdout.strip():
                workflow_name = result.stdout.strip().split("/")[-1]
                break
            time.sleep(2)
        if workflow_name:
            subprocess.run(
                ["kubectl", "patch", "workflow", "-n", "kubeflow", workflow_name,
                 "--type=merge", "-p", patch_payload],
                check=True,
            )
            print(f"Patched Argo Workflow {workflow_name}: privileged=true")
        else:
            print("WARNING: could not find Argo Workflow — profiling may lack CUPTI access",
                  file=sys.stderr)

    # ── GHA output ────────────────────────────────────────────────────────
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"run_id={run_id}\n")


if __name__ == "__main__":
    main()
