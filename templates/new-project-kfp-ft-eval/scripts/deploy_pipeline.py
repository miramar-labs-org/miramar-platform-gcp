#!/usr/bin/env python3
"""
Compile pipeline.py, register it in KFP (best-effort), and submit a run.

Required env vars:
  KFP_HOST   - KFP API server URL  (default: http://localhost:8080)
  RUN_NAME   - display name for the run
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from kfp import compiler
import kfp

from pipeline import pipeline

host = os.environ.get("KFP_HOST", "http://localhost:8080")
run_name = os.environ.get("RUN_NAME", "pipeline-run")
pipeline_yaml = "/tmp/compiled-pipeline.yaml"

# Derive pipeline name from the project directory
pipeline_name = os.path.basename(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

compiler.Compiler().compile(pipeline_func=pipeline, package_path=pipeline_yaml)
print(f"Compiled: {pipeline_yaml}")

client = kfp.Client(host=host)

# Register / update the pipeline in the KFP registry (best-effort — run always proceeds)
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
    arguments={},
    run_name=run_name,
)
run_id = run_response.run_id
print(f"Run submitted — ID: {run_id}")
print(f"UI: {host}/#/runs/details/{run_id}")

# Emit run_id as a GHA output for downstream steps
output_file = os.environ.get("GITHUB_OUTPUT")
if output_file:
    with open(output_file, "a") as f:
        f.write(f"run_id={run_id}\n")
