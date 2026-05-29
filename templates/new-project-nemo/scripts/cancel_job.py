#!/usr/bin/env python3
"""
Cancel a NeMo training job by name.

Required env vars:
  JOB_NAME   - the job name to cancel
  NEMO_HOST  - NeMo API base URL (default: http://nemo.test:8082)
"""
import os, sys, urllib.request, urllib.error

host = os.environ.get("NEMO_HOST", "http://nemo.test:8082")
job_name = os.environ.get("JOB_NAME", "").strip()

if not job_name:
    sys.exit("JOB_NAME env var is required")

req = urllib.request.Request(
    f"{host}/v1/customization/jobs/{job_name}",
    method="DELETE",
)
try:
    with urllib.request.urlopen(req) as resp:
        print(f"Job '{job_name}' cancelled (HTTP {resp.status})")
except urllib.error.HTTPError as e:
    if e.code == 404:
        print(f"Job '{job_name}' not found — already deleted or never started")
    else:
        sys.exit(f"HTTP {e.code}: {e.read().decode()}")
