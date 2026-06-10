#!/usr/bin/env python3
"""
Purge all runs and pipeline versions for this project from KFP and MLflow.

Terminates + deletes every KFP run, then deletes all versions, the pipeline,
and all MLflow runs for this project. The MLflow experiment container is
preserved so the next run can call mlflow.set_experiment() without hitting
the "cannot set a deleted experiment" error from a prior soft-delete.
Safe to run before every redeploy. Tutorial pipelines are never touched.

Usage:
  python3 scripts/purge_kfp_mlflow.py

Env vars:
  KFP_API              - KFP REST API base URL  (default: http://localhost:8890/apis/v2beta1)
  MLFLOW_TRACKING_URI  - MLflow tracking URI    (default: http://localhost:5000)
"""
import os
import subprocess
import sys
import urllib.parse
import urllib.request
import urllib.error
import json

KFP_API    = os.environ.get("KFP_API", "http://localhost:8890/apis/v2beta1")
MLFLOW_API = os.environ.get("MLFLOW_TRACKING_URI", "http://localhost:5000") + "/api/2.0/mlflow"

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


def mlflow_api(method, path, body=None):
    url = f"{MLFLOW_API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())
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


def purge_mlflow():
    """Delete all MLflow runs for this project; preserve the experiment container.

    Deleting the experiment with MLflow's soft-delete leaves it in a state where
    mlflow.set_experiment() raises "cannot set a deleted experiment" on the next
    run. The experiment is a stable named scope — only its runs need purging.
    """
    ename = urllib.parse.quote(PIPELINE_NAME, safe="")
    resp = mlflow_api("GET", f"/experiments/get-by-name?experiment_name={ename}")
    exp = resp.get("experiment")
    if not exp:
        print("  No MLflow experiment found — nothing to delete.")
        return
    eid = exp["experiment_id"]
    deleted = 0
    page_token = None
    while True:
        body = {"experiment_ids": [eid], "max_results": 1000}
        if page_token:
            body["page_token"] = page_token
        runs_resp = mlflow_api("POST", "/runs/search", body)
        for run in runs_resp.get("runs", []):
            mlflow_api("POST", "/runs/delete", {"run_id": run["info"]["run_id"]})
            deleted += 1
        page_token = runs_resp.get("next_page_token")
        if not page_token:
            break
    print(f"  Deleted {deleted} MLflow run(s) (experiment container preserved)")


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
print("MLflow:")
purge_mlflow()
print("Done.")
