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


def purge_runs():
    runs = api("GET", "/runs").get("runs") or []
    if not runs:
        print("No runs found.")
        return
    for run in runs:
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


def purge_pipeline():
    pipelines = api("GET", "/pipelines").get("pipelines") or []
    match = [p for p in pipelines if p["display_name"] == PIPELINE_NAME]
    if not match:
        print(f"Pipeline '{PIPELINE_NAME}' not found — nothing to delete.")
        return
    pid = match[0]["pipeline_id"]
    versions = api("GET", f"/pipelines/{pid}/versions").get("pipeline_versions") or []
    for v in versions:
        vid = v["pipeline_version_id"]
        api("DELETE", f"/pipelines/{pid}/versions/{vid}")
        print(f"  Deleted version: {vid}")
    api("DELETE", f"/pipelines/{pid}")
    print(f"  Deleted pipeline: {PIPELINE_NAME} ({pid})")


print(f"Purging KFP state for '{PIPELINE_NAME}'...")
print("Runs:")
purge_runs()
print("Pipeline:")
purge_pipeline()
print("Done.")
