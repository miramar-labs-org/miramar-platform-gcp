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

    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"run_id={run_id}\n")


if __name__ == "__main__":
    main()
