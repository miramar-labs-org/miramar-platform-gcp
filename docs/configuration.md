# Configuration Reference

GitHub Actions uses a mix of org secrets, repo secrets, org variables, and repo
variables. GCP variables are synced from `gcp/terraform/terraform.tfvars`; lab
host values are set manually.

## GitHub Secrets

### Org-Level Secrets

| Secret | Value | Purpose |
| --- | --- | --- |
| `WIF_PROVIDER` | output of `bootstrap-miramar-platform.zsh` | WIF provider resource path shared by repos for GCP auth |
| `HF_TOKEN` | Hugging Face API token | Injected into KFP pods via `mlabs-api-keys` K8s secret; also used directly in workflow steps |
| `NVIDIA_API_KEY` | NVIDIA NGC API key | Required by NeMo Microservices and NIM workflows; also injected into KFP pods via `mlabs-api-keys` |
| `NGC_API_KEY` | NVIDIA NGC API key (pipeline use) | Injected into KFP pods via `mlabs-api-keys` K8s secret |
| `OPENAI_API_KEY` | OpenAI API key | Injected into KFP pods via `mlabs-api-keys` K8s secret (e.g. GPT-4o judge in clinical pipelines) |
| `ANTHROPIC_API_KEY` | Anthropic API key | Injected into KFP pods via `mlabs-api-keys` K8s secret |
| `WANDB_API_KEY` | Weights & Biases API key | Injected into KFP pods via `mlabs-api-keys` K8s secret |
| `LANGCHAIN_API_KEY` | LangChain / LangSmith API key | Injected into KFP pods via `mlabs-api-keys` K8s secret |
| `HOST_SSH_KEY` | Private SSH key | SSH into DGX, AGX, or WSL2 hosts from runners (all machines share Spark's identity) |
| `DGX_SMB_PASSWORD` | Samba password for DGX `aaron` | Used by **Setup Shared SSH Store**; not needed by WSL2 Provision |
| `DGX_MINIKUBE_KUBECONFIG` | base64 kubeconfig | Written by **Minikube Install** (runner=dgx); used by minikube workflows |
| `AGX_MINIKUBE_KUBECONFIG` | base64 kubeconfig | Written by **Minikube Install** (runner=agx) on first run |

### Repo-Level Secrets

| Secret | Value | Purpose |
| --- | --- | --- |
| `GCP_SERVICE_ACCOUNT` | `gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com` | Cluster-ops service account used by platform lifecycle workflows |
| `WSL2_HOST_USER` | Windows SSH user | SSH login for WSL2 workflows |
| `WSL2_HOST_SSH_KEY` | Private SSH key | SSH into Windows; public key must be authorized in Windows OpenSSH |
| `DASHBOARD_DISPATCH_TOKEN` | Fine-grained PAT | Baked into the dashboard HTML at build time; used by the browser to trigger `delete-project.yaml` via workflow dispatch. Fine-grained PAT — **Actions: read and write** on `miramar-platform-gcp` only. No other permissions needed. Rotate by creating a new token at github.com/settings/personal-access-tokens and running `gh secret set DASHBOARD_DISPATCH_TOKEN --repo miramar-labs-org/miramar-platform-gcp`, then re-running **Deploy Platform Dashboard**. |

## GitHub Variables

### Org-Level Variables

Sync GCP variables from Terraform after changing `gcp/terraform/terraform.tfvars`:

```sh
./scripts/gha/sync-github-tf-vars.sh
```

| Variable | Value | Notes |
| --- | --- | --- |
| `GCP_PROJECT_ID` | `miramar-platform` | synced from tfvars |
| `GKE_CLUSTER_NAME` | `miramar-shared-gke` | synced from tfvars |
| `GKE_ZONE` | `us-central1-b` | synced from tfvars |
| `GCP_REGION` | `us-central1` | synced from tfvars |
| `GAR_REPO` | `apps` | synced from tfvars |
| `GKE_STATE_BUCKET` | `miramar-platform-cluster-state` | set manually |
| `DGX_HOST_IP` | `192.168.1.200` | static IP of DGX Spark |
| `DGX_HOST_USER` | `aaron` | SSH user on DGX |
| `AGX_HOST_IP` | `192.168.1.202` | static IP of AGX Orin |
| `AGX_HOST_USER` | `aaron` | SSH user on AGX |
| `AGX_VRAM_USEABLE` | `40` | GB available for AI models on AGX (64 GB total − 24 GB system) |
| `WSL2_HOST` | `192.168.1.201` | static IP of Windows (MSI) machine — shared by all WSL2 distros |
| `MLFLOW_TRACKING_URI` | `http://host.docker.internal:5000` | MLflow endpoint inside runner containers (resolves to local host on both DGX and AGX) |
| `QDRANT_URL` | `http://host.docker.internal:6333` | Qdrant REST endpoint inside runner containers (resolves to local host on both DGX and AGX) |
| `DGX_VRAM_USEABLE` | `100` | GB available for AI models on DGX (128 GB total − ~28 GB platform) |

### Org-Level Active State Variables

Drive the green/red dashboard badges. Set by deploy workflows, cleared by undeploy workflows. Seed on fresh install with `gh api` PATCH→POST upserts using `GITHUB_ORG_ADMIN_PAT`.

| Variable | Set to `true` by | Set to `false` by |
| --- | --- | --- |
| `DGX_MINIKUBE_ACTIVE` | Minikube Install (dgx) | Minikube Uninstall (dgx) |
| `AGX_MINIKUBE_ACTIVE` | Minikube Install (agx) | Minikube Uninstall (agx) |
| `DGX_NEMO_ACTIVE` | NeMo Deploy (dgx) | NeMo Undeploy (dgx) |
| `AGX_NEMO_ACTIVE` | NeMo Deploy (agx) | NeMo Undeploy (agx) |
| `DGX_MLFLOW_ACTIVE` | MLflow Deploy (dgx) | MLflow Undeploy (dgx) |
| `AGX_MLFLOW_ACTIVE` | MLflow Deploy (agx) | MLflow Undeploy (agx) |
| `DGX_QDRANT_ACTIVE` | Qdrant Deploy (dgx) | Qdrant Undeploy (dgx) |
| `AGX_QDRANT_ACTIVE` | Qdrant Deploy (agx) | Qdrant Undeploy (agx) |
| `DGX_KFP_ACTIVE` | Kubeflow Deploy (dgx) | Kubeflow Undeploy (dgx) |
| `AGX_KFP_ACTIVE` | Kubeflow Deploy (agx) | Kubeflow Undeploy (agx) |
| `DGX_OLLAMA_ACTIVE` | Ollama Deploy (dgx) | Ollama Undeploy (dgx), rollback |
| `AGX_OLLAMA_ACTIVE` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback |

### Repo-Level Variables

| Variable | Initial value | Purpose |
| --- | --- | --- |
| `WSL2_DISTROS` | `NONE` | Active WSL2 distro names; updated by WSL2 Provision/Unprovision |
| `OLLAMA_VERSION` | `—` | Ollama binary version; written by Ollama Update |
| `CURRENT_NIM_MODEL` | `none` | NIM currently loaded on DGX |
| `CURRENT_OLLAMA_MODEL` | `none` | Ollama model currently loaded on DGX |
| `CURRENT_NIM_VRAM_GB` | `0` | VRAM used by NIM on DGX |
| `CURRENT_OLLAMA_VRAM_GB` | `0` | VRAM used by Ollama on DGX |
| `CURRENT_NIM_MODEL_AGX` | `none` | NIM currently loaded on AGX |
| `CURRENT_OLLAMA_MODEL_AGX` | `none` | Ollama model currently loaded on AGX |
| `CURRENT_NIM_VRAM_GB_AGX` | `0` | VRAM used by NIM on AGX |
| `CURRENT_OLLAMA_VRAM_GB_AGX` | `0` | VRAM used by Ollama on AGX |

## Host Environment Variables

Each self-hosted runner machine needs classic GitHub PATs in its shell
environment:

| Variable | Scope required | Purpose |
| --- | --- | --- |
| `GITHUB_ORG_GHCR_PAT` | `read:packages` | Pull `mlabs-runner` from GHCR |
| `GITHUB_ORG_ADMIN_PAT` | `admin:org`, `repo`, `workflow` | Manage self-hosted runners, update `WSL2_DISTROS`, push `.github/workflows/` files to new repos. The `workflow` scope is required by GitHub whenever a push includes files under `.github/workflows/` — e.g. the **Create Project** workflow. Also used by **Delete Project** (`delete_repo` scope required). |

**Dashboard dispatch token** — `DASHBOARD_DISPATCH_TOKEN` is injected into the dashboard HTML when **Deploy Platform Dashboard** runs, so the 🗑 delete button works without any browser input. It is a fine-grained PAT scoped to Actions write on this repo only — safe to embed in public HTML because it can only trigger workflow dispatches, not delete repos directly. The actual deletion is performed by `delete-project.yaml` using the runner's `GITHUB_ORG_ADMIN_PAT`.

Example:

```sh
export GITHUB_ORG_GHCR_PAT=ghp_...
export GITHUB_ORG_ADMIN_PAT=ghp_...
```

`HF_TOKEN` and all other API keys are GitHub org secrets and do not need to be
set on individual machines — they are synced into the cluster automatically.

## Kubernetes Secret — `mlabs-api-keys`

The **Kubeflow Deploy** workflow creates (or updates) a Kubernetes Secret named
`mlabs-api-keys` in the `kubeflow` namespace immediately after the smoke-test
passes. This secret is the bridge from GHA org secrets into KFP component pods.

| Key in secret | Source GHA secret |
| --- | --- |
| `OPENAI_API_KEY` | `OPENAI_API_KEY` |
| `HF_TOKEN` | `HF_TOKEN` |
| `ANTHROPIC_API_KEY` | `ANTHROPIC_API_KEY` |
| `WANDB_API_KEY` | `WANDB_API_KEY` |
| `LANGCHAIN_API_KEY` | `LANGCHAIN_API_KEY` |
| `NGC_API_KEY` | `NGC_API_KEY` |
| `NVIDIA_API_KEY` | `NVIDIA_API_KEY` |

**To use in a KFP pipeline**, install `kfp-kubernetes` and add to the pipeline
function (after each task is constructed):

```python
from kfp import kubernetes as k8s_ext

SECRET = "mlabs-api-keys"
SECRET_KEYS = [
    "OPENAI_API_KEY", "HF_TOKEN", "ANTHROPIC_API_KEY",
    "WANDB_API_KEY", "LANGCHAIN_API_KEY", "NGC_API_KEY", "NVIDIA_API_KEY",
]
for task in [task1, task2, ...]:
    k8s_ext.use_secret_as_env(task, SECRET, {k: k for k in SECRET_KEYS})
```

The secret is idempotent — re-running **Kubeflow Deploy** updates it with the
current secret values. To verify on DGX:

```sh
kubectl get secret mlabs-api-keys -n kubeflow
```
