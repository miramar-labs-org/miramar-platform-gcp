# Configuration Reference

GitHub Actions uses a mix of org secrets, repo secrets, org variables, and repo
variables. GCP variables are synced from `gcp/terraform/terraform.tfvars`; lab
host values are set manually.

## GitHub Secrets

### Org-Level Secrets

| Secret | Value | Purpose |
| --- | --- | --- |
| `WIF_PROVIDER` | output of `bootstrap-miramar-platform.zsh` | WIF provider resource path shared by repos for GCP auth |
| `HF_TOKEN` | Hugging Face API token | Injected into workflow steps; not set on individual machines |
| `NVIDIA_API_KEY` | NVIDIA NGC API key | Required by NeMo Microservices and NIM workflows |
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
| `DGX_HOST_IP` | `192.0.2.10` | static IP of DGX Spark |
| `DGX_HOST_USER` | `aaron` | SSH user on DGX |
| `MLFLOW_TRACKING_URI` | `http://localhost:5000` | used by ML workflows |

### Repo-Level Variables

| Variable | Initial value | Purpose |
| --- | --- | --- |
| `WSL2_DISTROS` | `NONE` | Active WSL2 distro names; updated by WSL2 Provision/Unprovision |

## Host Environment Variables

Each self-hosted runner machine needs classic GitHub PATs in its shell
environment:

| Variable | Scope required | Purpose |
| --- | --- | --- |
| `GITHUB_ORG_GHCR_PAT` | `read:packages` | Pull `mlabs-runner` from GHCR |
| `GITHUB_ORG_ADMIN_PAT` | `admin:org`, `repo`, `workflow` | Manage self-hosted runners, update `WSL2_DISTROS`, push `.github/workflows/` files to new repos. The `workflow` scope is required by GitHub whenever a push includes files under `.github/workflows/` — e.g. the **Create Project** workflow. |

Example:

```sh
export GITHUB_ORG_GHCR_PAT=ghp_...
export GITHUB_ORG_ADMIN_PAT=ghp_...
```

`HF_TOKEN` is a GitHub org secret and does not need to be set on individual
machines.
