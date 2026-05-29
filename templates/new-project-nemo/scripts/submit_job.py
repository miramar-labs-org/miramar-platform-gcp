#!/usr/bin/env python3
"""
Submit a NeMo training job from job_config.yaml.

Required env vars:
  NEMO_HOST  - NeMo API base URL (default: http://nemo.test:8082)
  JOB_NAME   - override the job name from config (optional)
"""
import os, sys, json, urllib.request, urllib.error
try:
    import yaml
except ImportError:
    sys.exit("pip install pyyaml required")

config_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "job_config.yaml")
with open(config_path) as f:
    config = yaml.safe_load(f)

host = os.environ.get("NEMO_HOST", "http://nemo.test:8082")
job_name = os.environ.get("JOB_NAME") or config["name"]

payload = json.dumps({
    "name": job_name,
    "config": {
        "training_config": {
            "model": config["model"],
            "num_epochs": config["training"]["num_epochs"],
            "batch_size": config["training"].get("batch_size", 8),
            "learning_rate": config["training"].get("learning_rate", 1e-4),
        },
        "dataset": {
            "file_path": config["training"].get("dataset_path", ""),
        },
    },
}).encode()

req = urllib.request.Request(
    f"{host}/v1/customization/jobs",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read())
        job_id = result.get("id", "unknown")
        print(f"Job submitted — name: {job_name}  id: {job_id}")
        output_file = os.environ.get("GITHUB_OUTPUT")
        if output_file:
            with open(output_file, "a") as f:
                f.write(f"job_id={job_id}\n")
                f.write(f"job_name={job_name}\n")
except urllib.error.HTTPError as e:
    sys.exit(f"HTTP {e.code}: {e.read().decode()}")
