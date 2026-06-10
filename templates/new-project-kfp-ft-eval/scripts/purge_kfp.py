#!/usr/bin/env python3
"""
Purge all runs and pipeline versions for this project from KFP.

Terminates + deletes every run, then deletes all versions and the pipeline itself.
Safe to run before every redeploy. Tutorial pipelines are never touched.

Usage:
  python3 scripts/purge_kfp.py

Env vars:
  KFP_API   - KFP REST API base URL  (default: http://localhost:8890/apis/v2beta1)
"""
import os
import subprocess
import sys
import urllib.request
import urllib.error
import json

KFP_API = os.environ.get("KFP_API", "http://localhost:8890/apis/v2beta1")

# Derive pipeline name from the project directory (same logic as deploy_pipeline.py)
PIPELINE_NAME = os.path.basename(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def api(method, path, *, ok=(200,)):
    url = f"{KFP_API}{path}"
    req = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read()) if resp.status in ok else {}
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {}
        raise


def _find_pipeline_id():
    pipelines = api("GET", "/pipelines").get("pipelines") or []
    match = [p for p in pipelines if p["display_name"] == PIPELINE_NAME]
    return match[0]["pipeline_id"] if match else None


def purge_runs(pipeline_id):
    """Delete only runs belonging to this project's pipeline."""
    runs = api("GET", "/runs").get("runs") or []
    mine = [
        r for r in runs
        if r.get("pipeline_version_reference", {}).get("pipeline_id") == pipeline_id
    ]
    if not mine:
        print("  No runs found for this pipeline.")
        return
    for run in mine:
        rid = run["run_id"]
        name = run["display_name"]
        state = run.get("state", "")
        if state not in ("SUCCEEDED", "FAILED", "CANCELED", "SKIPPED"):
            try:
                api("POST", f"/runs/{rid}:terminate")
                print(f"  Terminated: {name} ({rid})")
            except Exception as e:
                print(f"  Terminate failed for {name}: {e}", file=sys.stderr)
        api("DELETE", f"/runs/{rid}")
        print(f"  Deleted run: {name} ({rid})")


def purge_pipeline(pipeline_id):
    if not pipeline_id:
        print(f"Pipeline '{PIPELINE_NAME}' not found — nothing to delete.")
        return
    versions = api("GET", f"/pipelines/{pipeline_id}/versions").get("pipeline_versions") or []
    for v in versions:
        vid = v["pipeline_version_id"]
        api("DELETE", f"/pipelines/{pipeline_id}/versions/{vid}")
        print(f"  Deleted version: {vid}")
    api("DELETE", f"/pipelines/{pipeline_id}")
    print(f"  Deleted pipeline: {PIPELINE_NAME} ({pipeline_id})")


def purge_experiment():
    exps = api("GET", "/experiments").get("experiments") or []
    match = [e for e in exps if e.get("display_name") == PIPELINE_NAME]
    if not match:
        print("  No experiment found — nothing to delete.")
        return
    for exp in match:
        eid = exp["experiment_id"]
        api("DELETE", f"/experiments/{eid}")
        print(f"  Deleted experiment: {PIPELINE_NAME} ({eid})")


def purge_argo_workflows():
    prefix = PIPELINE_NAME.replace("_", "-")
    result = subprocess.run(
        ["kubectl", "get", "workflows", "-n", "kubeflow",
         "--no-headers", "-o", "custom-columns=NAME:.metadata.name"],
        capture_output=True, text=True,
    )
    workflows = [w for w in result.stdout.splitlines() if w.startswith(prefix)]
    if not workflows:
        print("No orphaned Argo workflows found.")
        return
    for wf in workflows:
        subprocess.run(["kubectl", "delete", "workflow", "-n", "kubeflow", wf], check=True)
        print(f"  Deleted Argo workflow: {wf}")


print(f"Purging KFP state for '{PIPELINE_NAME}'...")
pid = _find_pipeline_id()
print("Runs:")
purge_runs(pid)
print("Pipeline:")
purge_pipeline(pid)
print("Argo workflows:")
purge_argo_workflows()
print("Experiment:")
purge_experiment()
print("Done.")
