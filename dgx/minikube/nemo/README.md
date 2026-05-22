# NeMo Microservices on DGX Spark (minikube)

Installs the NVIDIA NeMo Microservices platform into the DGX Spark's local minikube cluster using the official Helm chart, with Spark DGX-specific patches.

Source repo: [miramar-labs-org/nemo-k8s-spark-dgx](https://github.com/miramar-labs-org/nemo-k8s-spark-dgx)

## Prerequisites

**Software** (all must be on `$PATH`):

| Tool | Min version |
|---|---|
| minikube | 1.33.0 |
| Docker | 27.0.0 |
| kubectl | any recent |
| helm | any recent |
| NVIDIA Container Toolkit | 1.16.2 |
| jq | any |
| Python + `huggingface_hub` | 3.11.14+ |

**Credentials:**

| Variable | Where to get it |
|---|---|
| `NVIDIA_API_KEY` | [build.nvidia.com](https://build.nvidia.com) → API Keys |
| `HF_TOKEN` | [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) |

**System:**
- NVIDIA GPU driver ≥ 560.35.03
- ≥ 200 GB free disk space

## DGX Spark-specific patches

The upstream NeMo Microservices chart has three incompatibilities with the Spark DGX that the `nemo-k8s-spark-dgx` scripts patch automatically:

1. **`REQUIRED_GPUS=1`** — upstream requires 2 GPUs; patched to 1 for the single GB10 Superchip.
2. **nvidia-device-plugin pinned to v0.18.0** — fixes a GPU advertisement bug on the GB10 architecture.
3. **GB10 GPU allowlist patch** — GB10 is not on the upstream approved GPU list; the check is patched out.
4. **`guardrails.enabled: false`** and **`studio.enabled: false`** — these components do not have ARM-compatible images.

## Installation

All steps are handled by `create-platform.sh` in the `nemo-k8s-spark-dgx` repo. The sequence below documents what it does.

### 1. Start minikube

```sh
minikube start --driver=docker --gpus=all
minikube addons enable ingress
minikube addons enable dashboard
minikube addons enable metrics-server
# Pin nvidia-device-plugin to v0.18.0 (GB10 fix)
minikube addons enable nvidia-device-plugin
kubectl label node minikube feature.node.kubernetes.io/pci-10de.present=true
```

### 2. Create Kubernetes secrets

```sh
# Image pull secret for nvcr.io
kubectl create secret docker-registry nvcrimagepullsecret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password="${NVIDIA_API_KEY}"

# NGC / NVIDIA API key secrets
kubectl create secret generic ngc-api \
  --from-literal=NGC_API_KEY="${NVIDIA_API_KEY}"

kubectl create secret generic nvidia-api \
  --from-literal=NVIDIA_API_KEY="${NVIDIA_API_KEY}"

# HuggingFace token (required for gated models e.g. Llama 3.1)
kubectl create secret generic hf-token \
  --from-literal=HF_TOKEN="${HF_TOKEN}"
```

All four secrets are created in the `default` namespace.

### 3. Install Volcano scheduler

Volcano provides the gang-scheduling backend required by NeMo Customizer jobs.

```sh
kubectl apply -f https://raw.githubusercontent.com/volcano-sh/volcano/v1.9.0/installer/volcano-development.yaml
sleep 15
```

### 4. Install the NeMo Microservices Helm chart

```sh
helm repo add nmp https://helm.ngc.nvidia.com/nvidia/nemo-microservices \
  --username='$oauthtoken' \
  --password="${NVIDIA_API_KEY}"
helm repo update

helm install nemo nmp/nemo-microservices-helm-chart \
  --namespace default \
  -f minikube/values.yaml \
  --timeout 30m
```

**Key values overrides** (`minikube/values.yaml`):

```yaml
guardrails:
  enabled: false   # no ARM image
studio:
  enabled: false   # no ARM image
ingress:
  # nginx ingress with three virtual hosts:
  #   nemo.test       → core API / all microservices
  #   nim.test        → NIM inference proxy
  #   data-store.test → HuggingFace-compatible data store
```

### 5. Wait for pods

All pods in the `default` namespace should reach `Running` or `Completed`. This takes up to 30 minutes on first install (image pulls). Check progress:

```sh
kubectl get pods -n default -w
```

### 6. Configure DNS

```sh
MINIKUBE_IP=$(minikube ip)   # typically 192.168.49.2
sudo tee -a /etc/hosts <<EOF
${MINIKUBE_IP} nemo.test
${MINIKUBE_IP} nim.test
${MINIKUBE_IP} data-store.test
EOF
```

## Deployed microservices

| Pod | Role |
|---|---|
| `nemo-core-api` | REST API gateway |
| `nemo-core-controller` | Workflow orchestrator |
| `nemo-entity-store` | Namespace / project / model metadata (+ PostgreSQL) |
| `nemo-data-store` | HuggingFace-compatible artifact server |
| `nemo-data-designer` | Synthetic data generation |
| `nemo-customizer` | Fine-tuning microservice (+ PostgreSQL) |
| `nemo-evaluator` | Evaluation microservice (+ PostgreSQL) |
| `nemo-nim-proxy` | Inference gateway |
| `nemo-nim-operator` | NIM lifecycle management |
| `nemo-deployment-management` | Model deployment API |
| `nemo-postgresql` | Shared PostgreSQL instance |
| `nemo-opentelemetry-collector` | Observability |

## API endpoints (from DGX)

| URL | Service |
|---|---|
| `http://nemo.test` | NeMo core API |
| `http://nim.test` | NIM inference gateway |
| `http://data-store.test` | HuggingFace-compatible data API |

## Deploying a NIM model

```sh
# Llama 3.1 8B Instruct (Spark DGX variant)
source ./deploy_nim.sh
deploy_nim meta llama-3.1-8b-instruct-dgx-spark 1.0.0-variant

# NVIDIA Nemotron Nano 9B v2 (Spark DGX variant, tools enabled)
deploy_nim nvidia nvidia-nemotron-nano-9b-v2-dgx-spark 1.0.0-variant
```

NIM pods appear in the `default` namespace and take up to 30 minutes on first pull. Monitor:

```sh
kubectl get pods -n default -l app=<nim_name> -w
```

Undeploy:

```sh
source ./undeploy_nim.sh
undeploy_nim meta llama-3.1-8b-instruct-dgx-spark
```

## MLflow integration

MLflow is deployed into a separate `mlflow-system` namespace and reuses NeMo's PostgreSQL instance. The `mlflow/integrate-mlflow.sh` script in the `nemo-k8s-spark-dgx` repo handles this automatically as part of `create-platform.sh`. See the MLflow port-forward in [../../../systemd/](../systemd/) for the DGX systemd service that exposes it on port `5000`.

## Daily start / stop

The DGX systemd services restart automatically. The minikube cluster itself must be started manually after a reboot:

```sh
# Start (from nemo-k8s-spark-dgx repo)
./up.sh

# Stop
./down.sh
```

`up.sh` starts minikube and restarts the `dashboard`, `mlflow-portfwd`, and `jupyterlab` systemd services. `down.sh` stops them and halts minikube.

## Python SDK

```python
from nemo_microservices import NeMoMicroservices

client = NeMoMicroservices(
    base_url="http://nemo.test",
    inference_base_url="http://nim.test"
)

namespaces = client.namespaces.list()
```

Install: `pip install nemo-microservices`

## Teardown

```sh
# Full destruction (from nemo-k8s-spark-dgx repo)
./destroy-platform.sh
```

Stops all systemd services, removes MLflow and MinIO, deletes minikube, and removes the `/etc/hosts` DNS entries.
