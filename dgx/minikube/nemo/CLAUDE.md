# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Scripts and notebooks for running the **NVIDIA NeMo Microservices Platform** on a single **Spark DGX** (ARM/GB10 GPU) using **minikube**. The repo handles full platform lifecycle: install, daily resume/pause, NIM inference deployment, MLflow experiment tracking, and LLM fine-tuning/evaluation workflows via Jupyter notebooks.

## Key Commands

### Platform Lifecycle (run from repo root on the Spark DGX)

```bash
# Full install (~30 min first time)
./create-platform.sh

# Tear everything down
./destroy-platform.sh

# After DGX reboot — resume minikube + restart systemd services
./up.sh

# Before putting DGX to sleep
./down.sh
```

### NIM Inference (deploy/undeploy a model)

```bash
# Deploy (uses NeMo deployment API + waits for READY)
source ./deploy_nim.sh && deploy_nim meta llama-3.1-8b-instruct-dgx-spark 1.0.0-variant

# Undeploy
source ./undeploy_nim.sh && undeploy_nim meta llama-3.1-8b-instruct-dgx-spark

# Tail NIM pod logs
./nimlogs.sh
```

### Windows (PowerShell) — port-forward to localhost for browser access

```powershell
./up.ps1   # start port-forwards (dashboard :8001, JupyterLab :8888, MLflow :5000)
./down.ps1 # stop port-forwards
```

### Systemd services (on the Spark DGX, managed via `up.sh`)

```bash
systemctl --user {restart,stop,status} dashboard.service
systemctl --user {restart,stop,status} mlflow-portfwd.service
systemctl --user {restart,stop,status} jupyterlab.service
```

### Ad-hoc API checks

```bash
curl http://nim.test/v1/models
curl http://data-store.test/v1/health
curl http://nemo.test/v1/namespaces
curl http://nemo.test/v1/customization/jobs
```

## Architecture

### Deployment Flow

`create-platform.sh` → `minikube/create-nmp-spark-deployment.sh` (Helm install of NeMo chart with `minikube/values.yaml`) → `mlflow/integrate-mlflow.sh` (deploys MLflow + MinIO into `mlflow-system` namespace) → `up.sh` (starts systemd services).

### Ingress Routing (`minikube/values.yaml`)

All traffic is routed through nginx ingress with three virtual hosts:
- `nemo.test` → NeMo microservices (entity-store, customizer, evaluator, data-designer, deployment-management, core-api)
- `nim.test` → `nemo-nim-proxy` (inference gateway)
- `data-store.test` → `nemo-data-store` (HuggingFace-compatible API)

### NIM Deploy/Undeploy Scripts

`deploy_nim.sh` and `undeploy_nim.sh` are **sourced, not executed** — they define shell functions (`deploy_nim`, `undeploy_nim`, `wait_for_nim`, `verify_nim_endpoint`) intended to be called after sourcing. They POST/DELETE to the NeMo deployment API at `http://nemo.test/v1/deployment/model-deployments`.

### Notebooks (`nb/`)

- `01-NIM-Evaluation.ipynb` — evaluate a NIM endpoint directly
- `02-Evaluator_notebook.ipynb` — NeMo Evaluator microservice workflows
- `03-Customizer.ipynb` — fine-tune via NeMo Customizer microservice
- `nb/custom_dataset/` — training data + config for fine-tuning jobs
- `nb/integrations/` — MLflow and W&B tracking integration examples

### GKE Alternative (`gke/`)

Terraform config to deploy the same platform on Google Kubernetes Engine instead of minikube. Not used in the primary Spark DGX workflow.

## Required Environment Variables

```bash
export NVIDIA_API_KEY="..."   # NGC registry auth (required for NIM image pulls)
export HF_TOKEN="..."         # HuggingFace token (for gated models like Llama 3.1)
export HF_ENDPOINT="http://data-store.test/v1/hf"  # redirect HF downloads through NeMo data store
```

## Spark DGX-Specific Patches

The `minikube/create-nmp-spark-deployment.sh` script applies several patches vs. the upstream NeMo install guide:
- Installs a newer `nvidia-device-plugin` addon (fixes GPU advertisement bug on the GB10)
- Sets `REQUIRED_GPUS=1` (upstream requires 2)
- Disables `guardrails` and `studio` in `values.yaml` (not yet ARM-compatible)
- Patches the GPU allowlist check (GB10 not on upstream's approved list)
- Uses patched NIM image tags that work around a TensorRT bug on Spark DGX

## Python SDK

```bash
pip install -r requirements.txt  # installs nemo-microservices and notebook deps
```

```python
from nemo_microservices import NeMoMicroservices
client = NeMoMicroservices(base_url="http://nemo.test", inference_base_url="http://nim.test")
```
