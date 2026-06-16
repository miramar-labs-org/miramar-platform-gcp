#!/usr/bin/env python3
"""
Terminate a KFP run by ID via the REST API.

Required env vars:
  RUN_ID   - the run ID to terminate
  KFP_HOST - KFP API server URL (default: http://localhost:8080)
"""
import os
import sys
import urllib.request
import urllib.error

host = os.environ.get("KFP_HOST", "http://localhost:8080")
run_id = os.environ.get("RUN_ID", "").strip()

if not run_id:
    sys.exit("RUN_ID env var is required")

url = f"{host}/apis/v2beta1/runs/{run_id}:terminate"
req = urllib.request.Request(url, method="POST", data=b"")
try:
    with urllib.request.urlopen(req) as resp:
        print(f"Run {run_id} terminated (HTTP {resp.status})")
except urllib.error.HTTPError as e:
    if e.code == 404:
        print(f"Run {run_id} not found — already deleted or never existed")
    else:
        sys.exit(f"HTTP {e.code} terminating run: {e.read().decode()}")
