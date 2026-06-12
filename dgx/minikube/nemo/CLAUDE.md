# CLAUDE.md — dgx/minikube/nemo

NeMo Microservices deployment for the DGX Spark minikube cluster.

## Platform lifecycle — GHA workflows only

| Workflow                                   | Purpose                                                                     |
| ------------------------------------------ | --------------------------------------------------------------------------- |
| **NeMo Deploy** (`deploy-nemo.yaml`)       | Helm install — namespace, secrets, Volcano, chart, pod wait, /etc/hosts DNS |
| **NeMo Undeploy** (`undeploy-nemo.yaml`)   | Helm uninstall, optional namespace delete, /etc/hosts cleanup               |
| **Minikube Setup** (`setup-minikube.yaml`) | Start cluster, enable addons, update kubeconfig secret                      |
| **Minikube Stop/Pause/Resume**             | Cluster lifecycle                                                           |

No local shell scripts manage the platform lifecycle. Trigger all of the above from the GitHub Actions UI.

## NIM inference (local, on the DGX)

NIM scripts live in [../nim/](../nim/):

```bash
source ../nim/deploy_nim.sh && deploy_nim meta llama-3.1-8b-instruct-dgx-spark 1.0.0-variant
source ../nim/undeploy_nim.sh && undeploy_nim meta llama-3.1-8b-instruct-dgx-spark
../nim/nimlogs.sh   # tail NIM pod logs
```

## Systemd services

Same services run on both DGX and AGX — managed via `dgx/systemd/` and `agx/systemd/`.

| Service            | Port   | What it does                                                                                                |
| ------------------ | ------ | ----------------------------------------------------------------------------------------------------------- |
| `minikube`         | —      | Starts minikube on boot                                                                                     |
| `dashboard`        | `8001` | `kubectl proxy` → Kubernetes dashboard                                                                      |
| `jupyterlab`       | `8888` | JupyterLab                                                                                                  |
| `mlflow-portfwd`   | `5000` | `kubectl port-forward svc/mlflow-tracking`                                                                  |
| `kubeflow-portfwd` | `8080` | `kubectl port-forward svc/ml-pipeline-ui` (KFP UI)                                                          |
| `kfp-api-portfwd`  | `8890` | `kubectl port-forward svc/ml-pipeline:8888` (KFP REST API)                                                  |
| `nemo-portfwd`     | `8082` | `kubectl port-forward svc/ingress-nginx-controller:80` — exposes `nemo.test`, `nim.test`, `data-store.test` |

Access from laptop via SSH tunnel (DGX and AGX can run simultaneously on different local ports):

```bash
# DGX Spark
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 \
    -L 8080:localhost:8080 -L 8082:localhost:8082 -L 8890:localhost:8890 \
    -L 11434:localhost:11434 $USER@spark-79b7.local

# AGX Orin
ssh -L 8002:localhost:8001 -L 8887:localhost:8888 -L 5001:localhost:5000 \
    -L 8081:localhost:8080 -L 8083:localhost:8082 -L 8891:localhost:8890 \
    -L 11435:localhost:11434 $USER@orin.local
```

Add to laptop `/etc/hosts`: `127.0.0.1 nemo.test nim.test data-store.test`

## Required secrets

`NVIDIA_API_KEY` and `HF_TOKEN` are stored as GitHub org secrets — injected by workflows. Not needed locally unless running NIM scripts directly.

## Ad-hoc API checks

```bash
curl http://nim.test/v1/models
curl http://data-store.test/v1/health
curl http://nemo.test/v1/namespaces
curl http://nemo.test/v1/customization/jobs
```

## Ingress routing (`install/values.yaml`)

- `nemo.test` → NeMo microservices (entity-store, customizer, evaluator, data-designer, deployment-management, core-api)
- `nim.test` → `nemo-nim-proxy` (inference gateway)
- `data-store.test` → `nemo-data-store` (HuggingFace-compatible API)

## DGX-specific patches (applied by deploy-nemo workflow)

- Newer `nvidia-device-plugin` addon — fixes GPU advertisement bug on GB10
- `REQUIRED_GPUS=1` (upstream requires 2)
- `guardrails` and `studio` disabled in `install/values.yaml` (not ARM-compatible)
- GB10 patched past the upstream GPU allowlist check
- Patched NIM image tags that work around a TensorRT bug on Spark DGX

## Python SDK

```bash
pip install nemo-microservices
```

```python
from nemo_microservices import NeMoMicroservices
client = NeMoMicroservices(base_url="http://nemo.test", inference_base_url="http://nim.test")
```
