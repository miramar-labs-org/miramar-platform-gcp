#!/usr/bin/env python3
"""
Compile pipeline.py and submit a run to KFP.

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

compiler.Compiler().compile(pipeline_func=pipeline, package_path=pipeline_yaml)

client = kfp.Client(host=host)
run_response = client.create_run_from_pipeline_package(
    pipeline_file=pipeline_yaml,
    arguments={},
    run_name=run_name,
)
run_id = run_response.run_id
print(f"Run submitted — ID: {run_id}")
print(f"UI: {host}/#/runs/details/{run_id}")

# Emit as GHA output so the run_id can be referenced by later steps/jobs
output_file = os.environ.get("GITHUB_OUTPUT")
if output_file:
    with open(output_file, "a") as f:
        f.write(f"run_id={run_id}\n")
