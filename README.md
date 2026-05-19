# miramar-platform-gcp

GCP infrastructure and CI/CD tooling for the Miramar platform.

## Platform Overview

### Physical machines

On-premises machines acting as self-hosted GitHub Actions runners and general compute:

| Machine | OS | Arch | CPU | GPU | CUDA | Runner label |
|---|---|---|---|---|---|---|
| Windows laptop | Ubuntu 24.04 (WSL2) | x86_64 / amd64 | AMD | NVIDIA GeForce RTX 4060 (Ada Lovelace, sm_89) | 12.6 | `wsl2` |
| NVIDIA DGX Spark 128GB | DGX OS (Ubuntu) | aarch64 / arm64 | 20-core Arm (10× Cortex-X925 + 10× Cortex-A725) | GB10 Superchip — Blackwell, 6144 CUDA cores, 5th-gen Tensor Cores | 12.6 | `dgx` |
| NVIDIA Jetson AGX Orin 64GB | Ubuntu (JetPack 6.x) | aarch64 / arm64 | 12-core Cortex-A78AE | Ampere — 2048 CUDA cores, 64 Tensor Cores (sm_87) | 12.6 | `orin` |

The WSL2 and DGX machines run the [mlabs-runner](mlabs-runner/) Docker image (`nvidia/cuda:12.6`, multi-arch). The Orin uses a separate `mlabs-runner:jetson` image built on L4T — Jetson's Tegra unified-memory GPU requires L4T base images rather than the standard `nvidia/cuda` server images.

### Cloud infrastructure (GCP)

| Service | Purpose | Dashboard |
|---|---|---|
| GKE Standard cluster (`miramar-shared-gke`) | Shared Kubernetes cluster for platform workloads | [GKE console](https://console.cloud.google.com/kubernetes/list?project=miramar-platform) |
| Artifact Registry (`apps`) | Docker image registry for built application images | [GAR console](https://console.cloud.google.com/artifacts?project=miramar-platform) |
| Workload Identity Federation | Keyless auth from GitHub Actions to GCP — no long-lived service account keys | [WIF console](https://console.cloud.google.com/iam-admin/workload-identity-pools?project=miramar-cicd) |
| Two GCP projects | `miramar-cicd` (IAM / WIF) and `miramar-platform` (cluster / workloads) | [miramar-cicd](https://console.cloud.google.com/home/dashboard?project=miramar-cicd) · [miramar-platform](https://console.cloud.google.com/home/dashboard?project=miramar-platform) |

### CI/CD

| Service | Role | Link |
|---|---|---|
| GitHub Actions | Workflow automation — build, test, deploy | [Actions](https://github.com/orgs/miramar-labs-org/actions) |
| GHCR | Docker image hosting for the runner image and future app images | [Packages](https://github.com/orgs/miramar-labs-org/packages) |
| Self-hosted runners | Jobs requiring GPU, local network access, or aarch64 run on the physical machines above | [Runners](https://github.com/organizations/miramar-labs-org/settings/actions/runners) |

GitHub Actions workflows authenticate to GCP keylessly via Workload Identity Federation. Access is restricted to repos under the `miramar-labs-org` org.

---

## MLflow (DGX)

MLflow runs on the NVIDIA Spark DGX out of `~/mlflow`. It is not exposed publicly — access the UI by opening an SSH tunnel from your laptop:

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
```

Then open **[http://localhost:5000](http://localhost:5000)** in your browser. The tunnel stays open for as long as the SSH session is running.

---

## Required Environment Variables

Two GitHub classic PATs must be set as environment variables on each machine. Create them at [github.com/settings/tokens](https://github.com/settings/tokens) → **Generate new token (classic)**.

| Variable | Scope required | Purpose |
|---|---|---|
| `GITHUB_ORG_GHCR_PAT` | `read:packages` | Pull the `mlabs-runner` image from GHCR |
| `GITHUB_ORG_ADMIN_PAT` | `admin:org` | Manage self-hosted runners (list, unregister, clean deregistration on shutdown) |
| `HF_TOKEN` | — | Hugging Face API token — forwarded into the runner container for workflow use |

Add both to `~/.bashrc` or `~/.zshrc` on each machine:

```sh
export GITHUB_ORG_GHCR_PAT=ghp_...
export GITHUB_ORG_ADMIN_PAT=ghp_...
export HF_TOKEN=hf_...
```

---

## GHA Self-Hosted Runners

Docker-based GitHub Actions runners for self-hosted machines. Supports `amd64` (x86_64) and `arm64` (aarch64) via a single multi-arch image.

### Image

Built and pushed to GHCR by the [build-mlabs-runner workflow](.github/workflows/build-mlabs-runner.yml) on every push to `main` that touches `mlabs-runner/**`.

| Image | Architectures |
|---|---|
| [`ghcr.io/miramar-labs-org/mlabs-runner:latest`](https://github.com/orgs/miramar-labs-org/packages/container/package/mlabs-runner) | `linux/amd64`, `linux/arm64` |

Docker automatically pulls the correct variant for the host architecture.

**Base:** `nvidia/cuda:12.6.3-cudnn-runtime-ubuntu22.04` — CUDA 12.6 is available inside the container on both machines (RTX 4060 on WSL2, GB10 on DGX). The launch script passes `--gpus all` automatically.

**Pre-installed tools:**

| Category | Packages |
|---|---|
| CI/CD | `docker-cli`, `kubectl`, `gcloud`, `terraform`, `helm`, `make` |
| PyTorch | `torch`, `torchvision`, `torchaudio` — CUDA 12.6 wheels (amd64: pytorch.org/whl/cu126; arm64: standard PyPI) |
| HuggingFace | `transformers`, `diffusers`, `accelerate`, `peft`, `optimum`, `sentence-transformers`, `timm`, `huggingface_hub`, `evaluate`, `datasets` |
| ML tooling | `mlflow`, `tensorboard`, `bitsandbytes`, `onnx`, `scikit-learn`, `boto3`, `numpy`, `scipy`, `pandas`, `einops` |
| Audio/video | `ffmpeg`, `libsndfile1`, `sox` |

To verify GPU access after pulling a new image:
```sh
docker run --rm --gpus all ghcr.io/miramar-labs-org/mlabs-runner:latest \
  python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

### Prerequisites

- Docker installed on the host machine
- A **runner registration token** is fetched automatically via `GITHUB_ORG_ADMIN_PAT`. To override, pass `--token` manually:
  - **Org-level:** https://github.com/organizations/miramar-labs-org/settings/actions/runners/new
  - **Repo-level:** `https://github.com/miramar-labs-org/<repo>/settings/actions/runners/new`
- **`GITHUB_ORG_GHCR_PAT`** set as an environment variable — see [Required Environment Variables](#required-environment-variables) above.

### Launch

The [launch-runner.sh](scripts/gha/launch-runner.sh) script pulls the multi-arch image and runs the correct variant for the host.

```sh
# Org-level runner, foreground (Ctrl+C to stop and deregister)
./scripts/gha/launch-runner.sh

# Repo-level runner, detached
./scripts/gha/launch-runner.sh \
  --repo miramar-platform-gcp \
  --detach

# Custom labels, ephemeral (deregisters after one job)
./scripts/gha/launch-runner.sh \
  --labels "self-hosted,linux,amd64,gpu" \
  --ephemeral
```

**All options:**

| Flag | Default | Description |
|---|---|---|
| `--token` | *(auto-fetched)* | Runner registration token — fetched via `GITHUB_ORG_ADMIN_PAT` if not supplied |
| `--name` | hostname | Runner display name |
| `--labels` | `self-hosted,linux,amd64,wsl2` or `self-hosted,linux,arm64,dgx` | Comma-separated runner labels |
| `--repo` | *(unset — org-level)* | Scope to a specific repo (`owner/repo`) |
| `--group` | `Default` | Runner group |
| `--ephemeral` | false | Deregister after one job |
| `--detach` | false | Run container in background (`docker run -d`) |

> **Org runner group access** — if jobs queue indefinitely despite the runner showing _Idle_, check that the target repo is allowed to use the runner group: **Org Settings → Actions → Runner groups → Default → Repository access**.

### Rebuilding the image

Triggered automatically on push. To rebuild manually with a specific runner version:

```sh
gh workflow run build-mlabs-runner.yml \
  --field runner_version=2.334.0
```

Or locally (requires `docker buildx`):

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg RUNNER_VERSION=2.334.0 \
  -f mlabs-runner/Dockerfile \
  -t ghcr.io/miramar-labs-org/mlabs-runner:local \
  mlabs-runner/
```

---

## Workload Identity Federation

GitHub Actions workflows authenticate to GCP via WIF — no long-lived service account keys. Two things must be configured correctly for auth to succeed.

**GCP resources:**
- Pool: `projects/423801268174/locations/global/workloadIdentityPools/github-actions`
- Provider: `github` (OIDC, issuer `https://token.actions.githubusercontent.com`)
- Service account: `gh-github-deploy-github-action@miramar-cicd.iam.gserviceaccount.com`

### 1. WIF provider attribute condition

Controls which GitHub tokens the provider will accept. Must reference the correct org.

Check the current condition:
```sh
gcloud iam workload-identity-pools providers describe github \
  --project=miramar-cicd \
  --location=global \
  --workload-identity-pool=github-actions \
  --format="value(attributeCondition)"
```

Expected: `attribute.repository_owner=='miramar-labs-org'`

Update if wrong:
```sh
gcloud iam workload-identity-pools providers update-oidc github \
  --project=miramar-cicd \
  --location=global \
  --workload-identity-pool=github-actions \
  --attribute-condition="attribute.repository_owner=='miramar-labs-org'"
```

### 2. Service account IAM binding

Controls which WIF principal can impersonate the service account. Must reference the correct org.

Check the current binding:
```sh
gcloud iam service-accounts get-iam-policy \
  gh-github-deploy-github-action@miramar-cicd.iam.gserviceaccount.com \
  --project=miramar-cicd \
  --format=json
```

Expected member: `principalSet://iam.googleapis.com/projects/423801268174/locations/global/workloadIdentityPools/github-actions/attribute.repository_owner/miramar-labs-org`

Add the correct binding:
```sh
gcloud iam service-accounts add-iam-policy-binding \
  gh-github-deploy-github-action@miramar-cicd.iam.gserviceaccount.com \
  --project=miramar-cicd \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/423801268174/locations/global/workloadIdentityPools/github-actions/attribute.repository_owner/miramar-labs-org"
```

Remove any stale binding referencing an old org name:
```sh
gcloud iam service-accounts remove-iam-policy-binding \
  gh-github-deploy-github-action@miramar-cicd.iam.gserviceaccount.com \
  --project=miramar-cicd \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/423801268174/locations/global/workloadIdentityPools/github-actions/attribute.repository_owner/OLD_ORG_NAME"
```

> If WIF auth fails with `iam.serviceAccounts.getAccessToken` denied, the SA binding is the most likely culprit — check the member value matches the current GitHub org name exactly.

---

## Scripts

### `scripts/gha/` — GitHub Actions runner management

#### [launch-runner.sh](scripts/gha/launch-runner.sh)
Pull and start a self-hosted runner container. Requires `GITHUB_ORG_GHCR_PAT` and `GITHUB_ORG_ADMIN_PAT` — registration token is fetched automatically.
```sh
# Org-level runner (default)
./scripts/gha/launch-runner.sh

# Repo-level, detached
./scripts/gha/launch-runner.sh --repo miramar-platform-gcp --detach

# Ephemeral (deregisters after one job)
./scripts/gha/launch-runner.sh --ephemeral
```

#### [runners.sh](scripts/gha/runners.sh)
List all runners registered to the org, with status and labels.
```sh
./scripts/gha/runners.sh
```

#### [unregister-runner.sh](scripts/gha/unregister-runner.sh)
Remove a runner from the org via the GitHub API. Lists runners and prompts for ID, or pass a name directly.
```sh
# Interactive
./scripts/gha/unregister-runner.sh

# By name
./scripts/gha/unregister-runner.sh <runner-name>
```

---

### `scripts/gcp/` — GCP utilities

#### [resources.sh](scripts/gcp/resources.sh)
Enumerate live GCP resources in the `miramar-platform` project.
```sh
./scripts/gcp/resources.sh
```

---

### `scripts/ubuntu/` — Host setup

#### [install-gcloud.sh](scripts/ubuntu/install-gcloud.sh)
Install the Google Cloud CLI via apt on Ubuntu/Debian.
```sh
./scripts/ubuntu/install-gcloud.sh
```

#### [install-terraform.sh](scripts/ubuntu/install-terraform.sh)
Install Terraform via apt on Ubuntu/Debian.
```sh
./scripts/ubuntu/install-terraform.sh
```

---

### `gcp/` — GCP provisioning

| Script | Usage |
|---|---|
| `gcp/setup-miramar-gke-cicd.zsh` | Full idempotent bootstrap of projects, APIs, WIF, GKE, and RBAC |
| `gcp/pause-miramar-platform.zsh` | Scale GKE node pool to 0 (cost saving) |
| `gcp/resume-miramar-platform.zsh` | Scale GKE node pool back up |
| `gcp/verify-nuked-miramar-platform.zsh` | Confirm all resources torn down after deletion |
| `gcp/patch-namespace-manager-rbac.zsh` | Patch RBAC after cluster re-create |
