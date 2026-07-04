#!/usr/bin/env python3
"""Compile, register, and submit a KFP sequence-classify pipeline run.

Usage:
  python3 scripts/deploy_pipeline.py [--run-name run-001]

Env vars:
  KFP_HOST             — KFP API server URL  (default: http://localhost:8890)
  MLFLOW_TRACKING_URI  — MLflow tracking URI (default: http://localhost:5000)
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).parent.parent


def _build() -> None:
    result = subprocess.run(
        [sys.executable, str(HERE / "scripts" / "build_pipeline.py")],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"build_pipeline.py failed:\n{result.stderr}")
    print(result.stdout.strip())


def _next_run_name() -> str:
    runs_dir = HERE / "runs"
    runs_dir.mkdir(exist_ok=True)
    existing = sorted(runs_dir.glob("run-[0-9][0-9][0-9].md"))
    if existing:
        last_n = int(existing[-1].stem.split("-")[1])
        return f"run-{last_n + 1:03d}"
    return "run-001"


def main() -> None:
    parser = argparse.ArgumentParser(description="Deploy sequence-classify KFP run")
    parser.add_argument("--run-name", default=None, help="Run name (e.g. run-002)")
    args = parser.parse_args()

    cfg = yaml.safe_load((HERE / "config.yaml").read_text())

    run_name = args.run_name or _next_run_name()
    print(f"Deploying {run_name}...")

    _build()

    from kfp import compiler
    sys.path.insert(0, str(HERE))
    from pipeline import pipeline as pipe  # noqa: E402 (built above)

    compiled_path = "/tmp/pipeline_compiled.yaml"
    compiler.Compiler().compile(pipe, compiled_path)
    print(f"Compiled → {compiled_path}")

    import kfp

    host = os.environ.get("KFP_HOST", "http://localhost:8890")
    client = kfp.Client(host=host)

    project_name = HERE.name
    pipeline_name = project_name

    # Register or version the pipeline
    try:
        kfp_pipeline = client.upload_pipeline(compiled_path, pipeline_name=pipeline_name)
        pipeline_id = kfp_pipeline.pipeline_id
        print(f"Registered pipeline: {pipeline_id}")
    except Exception:
        try:
            pipelines = client.list_pipelines(
                filter=json.dumps({"predicates": [
                    {"key": "name", "op": "EQUALS", "string_value": pipeline_name}
                ]})
            )
            pipeline_id = pipelines.pipelines[0].pipeline_id
            pv = client.upload_pipeline_version(
                compiled_path,
                pipeline_version_name=run_name,
                pipeline_id=pipeline_id,
            )
            print(f"Uploaded pipeline version: {pv.pipeline_version_id}")
        except Exception as e:
            print(f"Warning: pipeline registration: {e}")

    # Create or fetch experiment
    experiment_name = project_name
    try:
        experiment = client.create_experiment(experiment_name)
    except Exception:
        experiment = client.get_experiment(experiment_name=experiment_name)

    # Ensure MLflow experiment exists
    mlflow_uri = os.environ.get("MLFLOW_TRACKING_URI", "http://localhost:5000")
    try:
        import mlflow
        mlflow.set_tracking_uri(mlflow_uri)
        if mlflow.get_experiment_by_name(experiment_name) is None:
            mlflow.create_experiment(experiment_name)
            print(f"Created MLflow experiment: {experiment_name}")
    except Exception as e:
        print(f"MLflow experiment setup: {e}")

    config_yaml_str = (HERE / "config.yaml").read_text()
    model_id = cfg["model"]["id"]
    dataset_id = cfg["dataset"]["id"]

    run = client.create_run_from_pipeline_package(
        pipeline_file=compiled_path,
        arguments={
            "model_id": model_id,
            "dataset_id": dataset_id,
            "config_yaml": config_yaml_str,
        },
        run_name=run_name,
        experiment_name=experiment_name,
        enable_caching=False,
    )

    print(f"Run submitted — ID: {run.run_id}")
    print(f"Run name:         {run_name}")
    print(f"KFP UI:           {host}/#/runs/details/{run.run_id}")
    print(f"MLflow UI:        {mlflow_uri}")


if __name__ == "__main__":
    main()
