#!/usr/bin/env python3
"""
Build pipeline.py from notebook, compile, register in KFP, and submit a run.

Usage:
  python3 scripts/deploy_pipeline.py --run-name run-015
  python3 scripts/deploy_pipeline.py --run-name run-016 --profile-baseline --profile-finetune

Profile flags patch config.yaml, rebuild pipeline.py, then compile and submit.
Without profile flags, config.yaml is left as-is (defaults to no profiling).

Env vars (override CLI):
  KFP_HOST   - KFP API server URL  (default: http://localhost:8890)
  RUN_NAME   - display name for the run (default: pipeline-run)
"""
import argparse
import importlib.util
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-name", default=None,
                        help="KFP run display name (also sets run_id pipeline param)")
    parser.add_argument("--host", default=None, help="KFP API server URL")
    parser.add_argument("--profile-baseline", action="store_true",
                        help="Enable nsys profiling for baseline_eval")
    parser.add_argument("--profile-finetune", action="store_true",
                        help="Enable nsys profiling for fine_tune")
    parser.add_argument("--profile-postft", action="store_true",
                        help="Enable nsys profiling for post_finetune_eval")
    parser.add_argument("--profile-safety", action="store_true",
                        help="Enable nsys profiling for safety_eval")
    parser.add_argument("--profile-baseline-safety", action="store_true",
                        help="Enable nsys profiling for baseline_safety_eval")
    parser.add_argument("--profile-nsight", action="store_true",
                        help="Shorthand: enable nsys profiling for all steps")
    args = parser.parse_args()

    host = args.host or os.environ.get("KFP_HOST", "http://localhost:8890")
    run_name = args.run_name or os.environ.get("RUN_NAME", "pipeline-run")

    # ── Patch config.yaml if any profile flag is set ──────────────────────
    any_profile = (
        args.profile_baseline or args.profile_finetune or args.profile_postft
        or args.profile_safety or args.profile_baseline_safety or args.profile_nsight
    )
    if any_profile:
        import yaml, pathlib
        cfg = yaml.safe_load(pathlib.Path("config.yaml").read_text())
        cfg.setdefault("profiling", {})
        nsight = args.profile_nsight
        cfg["profiling"]["baseline"]        = nsight or args.profile_baseline
        cfg["profiling"]["finetune"]        = nsight or args.profile_finetune
        cfg["profiling"]["postft"]          = nsight or args.profile_postft
        cfg["profiling"]["safety"]          = nsight or args.profile_safety
        cfg["profiling"]["baseline_safety"] = nsight or args.profile_baseline_safety
        pathlib.Path("config.yaml").write_text(
            yaml.dump(cfg, default_flow_style=False)
        )
        active = [k for k, v in cfg["profiling"].items() if v is True]
        print(f"Profiling enabled: {active}")

    # ── Always rebuild pipeline.py from notebook ──────────────────────────
    from scripts.build_pipeline import build_pipeline
    build_pipeline()

    # ── Pre-create nsight output dirs on the DGX host (as aaron, UID 1000) ──
    # Done AFTER build so config.yaml reflects the final profiling state whether
    # flags were passed via CLI or patched externally.
    # The profiled pods run as UID 65532. The minikube 9p noextend mount ignores
    # the pod's umask and creates dirs at mode 0755; UID 65532 is "other" and
    # cannot write to 0755. Pre-creating with chmod 777 from the host is the
    # only reliable fix — all writes from inside the pod go through the 9p
    # server as the host UID (1000/aaron), which can write to 0777 dirs.
    import yaml, pathlib
    cfg_data = yaml.safe_load(pathlib.Path("config.yaml").read_text())
    # any_profile must also account for profiling already enabled in config.yaml
    # (not just CLI flags) — the privileged patch is needed whenever any profiling
    # step will run, regardless of how it was enabled.
    any_profile = any_profile or any(
        cfg_data.get("profiling", {}).get(flag, False)
        for flag in ["baseline", "finetune", "postft", "safety", "baseline_safety"]
    )
    nsys_project = cfg_data.get("nsys_project", os.path.basename(os.getcwd()))
    nsight_host_base = pathlib.Path.home() / "shared/nsight" / nsys_project / run_name
    _STAGE_MAP = {
        "baseline":        "baseline-eval",
        "finetune":        "fine-tune",
        "postft":          "post-finetune-eval",
        "safety":          "safety-eval",
        "baseline_safety": "baseline-safety-eval",
    }
    for flag, stage_dir in _STAGE_MAP.items():
        if cfg_data.get("profiling", {}).get(flag, False):
            d = nsight_host_base / stage_dir
            d.mkdir(parents=True, exist_ok=True)
            d.chmod(0o777)
            # chmod run-name parent too — pods need to list it
            d.parent.chmod(0o777)
            print(f"Pre-created nsight dir (0777): {d}")

    # ── Import freshly-built pipeline (dynamic to avoid stale cache) ──────
    spec = importlib.util.spec_from_file_location("pipeline", "pipeline.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    pipeline_fn = mod.pipeline

    # ── Compile ───────────────────────────────────────────────────────────
    from kfp import compiler
    pipeline_yaml = "/tmp/compiled-pipeline.yaml"
    pipeline_name = os.path.basename(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )
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
        print(f"Note: pipeline registration skipped ({type(e).__name__})",
              file=sys.stderr)

    run_response = client.create_run_from_pipeline_package(
        pipeline_file=pipeline_yaml,
        arguments={"run_id": run_name},
        run_name=run_name,
    )
    run_id = run_response.run_id
    print(f"Run submitted — ID: {run_id}")
    print(f"UI: {host}/#/runs/details/{run_id}")

    # ── Patch Argo Workflow for profiling runs ────────────────────────────
    # KFP compiler enforces drop:ALL on all containers.  For nsys profiling,
    # the main container needs privileged=true so CUPTI can access the NVIDIA
    # performance-counter device nodes.  We patch the Argo Workflow CRD that
    # KFP creates (labelled pipeline/runid=<run_id>) immediately after
    # submission — before the profiled pod is scheduled.
    if any_profile:
        import subprocess, time as _time
        import json as _json
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
        patch_payload = _json.dumps({"spec": {"podSpecPatch": pod_spec_patch}})
        workflow_name = None
        for attempt in range(30):
            result = subprocess.run(
                ["kubectl", "get", "workflows", "-n", "kubeflow",
                 "-l", f"pipeline/runid={run_id}", "-o", "name"],
                capture_output=True, text=True,
            )
            if result.stdout.strip():
                workflow_name = result.stdout.strip().split("/")[-1]
                break
            _time.sleep(2)
        if workflow_name:
            subprocess.run(
                ["kubectl", "patch", "workflow", "-n", "kubeflow", workflow_name,
                 "--type=merge", "-p", patch_payload],
                check=True,
            )
            print(f"Patched Argo Workflow {workflow_name}: privileged=true podSpecPatch applied")
        else:
            print("WARNING: could not find Argo Workflow for run — profiling may lack capabilities",
                  file=sys.stderr)

    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"run_id={run_id}\n")


if __name__ == "__main__":
    main()
