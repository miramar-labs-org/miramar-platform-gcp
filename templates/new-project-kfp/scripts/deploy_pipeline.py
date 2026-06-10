#!/usr/bin/env python3
"""
Compile pipeline.py and submit a run to KFP.

Usage:
  python3 scripts/deploy_pipeline.py --run-name run-001

Env vars (override CLI):
  KFP_HOST   - KFP API server URL  (default: http://localhost:8890)
  RUN_NAME   - display name for the run
"""
import argparse
import importlib.util
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-name", default=None)
    parser.add_argument("--host", default=None)
    args = parser.parse_args()

    host = args.host or os.environ.get("KFP_HOST", "http://localhost:8890")
    run_name = args.run_name or os.environ.get("RUN_NAME", "pipeline-run")

    # ── Compile ───────────────────────────────────────────────────────────
    spec = importlib.util.spec_from_file_location("pipeline", "pipeline.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    pipeline_fn = mod.pipeline

    from kfp import compiler
    import yaml as _yaml
    pipeline_yaml = "/tmp/compiled-pipeline.yaml"
    pipeline_name = Path.cwd().name
    compiler.Compiler().compile(pipeline_func=pipeline_fn, package_path=pipeline_yaml)
    print(f"Compiled: {pipeline_yaml}")

    # ── Load project description ──────────────────────────────────────────
    _cfg_path = Path("config.yaml")
    pipeline_description = None
    if _cfg_path.exists():
        pipeline_description = (_yaml.safe_load(_cfg_path.read_text()) or {}).get("description") or None

    # ── Register + submit ─────────────────────────────────────────────────
    import kfp
    client = kfp.Client(host=host)

    try:
        client.upload_pipeline(
            pipeline_package_path=pipeline_yaml,
            pipeline_name=pipeline_name,
            description=pipeline_description,
        )
        print(f"Pipeline registered: {pipeline_name}")
    except Exception as e:
        print(f"Note: pipeline registration skipped ({type(e).__name__})", file=sys.stderr)

    try:
        client.create_experiment(pipeline_name, description=pipeline_description)
        print(f"KFP experiment created: {pipeline_name}")
    except Exception:
        pass  # already exists

    run_response = client.create_run_from_pipeline_package(
        pipeline_file=pipeline_yaml,
        arguments={"run_id": run_name},
        run_name=run_name,
        experiment_name=pipeline_name,
    )
    run_id = run_response.run_id
    print(f"Run submitted — ID: {run_id}")
    print(f"UI: {host}/#/runs/details/{run_id}")

    # ── GHA output ────────────────────────────────────────────────────────
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            f.write(f"run_id={run_id}\n")


if __name__ == "__main__":
    main()
