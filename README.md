# miramar-platform-gcp

GCP infrastructure and CI/CD tooling for the Miramar Labs platform.

## Platform Overview

### Physical machines

On-premises machines acting as self-hosted GitHub Actions runners and general compute:

| Machine | OS | Arch | CPU | GPU | CUDA | Runner label |
|---|---|---|---|---|---|---|
| Windows laptop | Ubuntu 24.04 (WSL2) | x86_64 / amd64 | AMD | NVIDIA GeForce RTX 4060 (Ada Lovelace, sm_89) | 12.6 | `wsl2` |
| NVIDIA DGX Spark 128GB | DGX OS (Ubuntu) | aarch64 / arm64 | 20-core Arm (10× Cortex-X925 + 10× Cortex-A725) | GB10 Superchip — Blackwell, 6144 CUDA cores, 5th-gen Tensor Cores | 12.6 | `dgx` |
| NVIDIA Jetson AGX Orin 64GB | Ubuntu (JetPack 6.x) | aarch64 / arm64 | 12-core Cortex-A78AE | Ampere — 2048 CUDA cores, 64 Tensor Cores (sm_87) | 12.6 | `agx` |

All three machines run the [mlabs-runner](mlabs-runner/) Docker image — WSL2 pulls `linux/amd64`, DGX and Orin both pull `linux/arm64`. GPU access inside the container works natively on the DGX (SBSA). On the Orin (Tegra unified memory), it should also work via the NVIDIA container runtime mounting host JetPack libs, but verify with `torch.cuda.is_available()` after first launch.

### Cloud infrastructure (GCP)

| Service | Purpose | Dashboard |
|---|---|---|
| GKE Standard cluster (`miramar-shared-gke`) | Shared Kubernetes cluster for platform workloads | [GKE console](https://console.cloud.google.com/kubernetes/list?project=miramar-platform) |
| Artifact Registry (`apps`) | Docker image registry for built application images | [GAR console](https://console.cloud.google.com/artifacts?project=miramar-platform) |
| GCS buckets | Terraform state + GKE node pool snapshots (see [Storage](#gcp-storage) below) | [GCS console](https://console.cloud.google.com/storage/browser?project=miramar-platform) |
| Workload Identity Federation | Keyless auth from GitHub Actions to GCP — no long-lived service account keys | [WIF console](https://console.cloud.google.com/iam-admin/workload-identity-pools?project=miramar-platform) |
| GCP project | `miramar-platform` — single project for all resources | [Dashboard](https://console.cloud.google.com/home/dashboard?project=miramar-platform) |

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

## GitHub Secrets & Variables

### Org-level secrets — [miramar-labs-org settings](https://github.com/organizations/miramar-labs-org/settings/secrets/actions)

| Secret | Value | Purpose |
|---|---|---|
| `WIF_PROVIDER` | output of `bootstrap-miramar-platform.zsh` | WIF provider resource path — shared by all repos for GCP auth |
| `HF_TOKEN` | Hugging Face API token | Injected into workflow steps via `${{ secrets.HF_TOKEN }}` — no longer set on individual machines |

### Repo-level secrets — [miramar-platform-gcp settings](https://github.com/miramar-labs-org/miramar-platform-gcp/settings/secrets/actions)

| Secret | Value | Purpose |
|---|---|---|
| `GCP_SERVICE_ACCOUNT` | `gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com` | Cluster-ops SA — used by platform lifecycle workflows |

### Org-level variables — [miramar-labs-org settings](https://github.com/organizations/miramar-labs-org/settings/variables/actions)

Shared platform config — available to all repos in the org via `${{ vars.* }}`. **Synced from `gcp/terraform/terraform.tfvars`** — do not edit directly. Run `scripts/gha/sync-github-vars.sh` after changing tfvars.

| Variable | Value |
|---|---|
| `GCP_PROJECT_ID` | `miramar-platform` |
| `GKE_CLUSTER_NAME` | `miramar-shared-gke` |
| `GKE_ZONE` | `us-west1-a` |
| `GCP_REGION` | `us-west1` |
| `GAR_REPO` | `apps` |
| `GKE_STATE_BUCKET` | `miramar-platform-cluster-state` *(set manually — not in tfvars)* |

---

## Required Environment Variables

Two GitHub classic PATs must be set as environment variables on each machine. Create them at [github.com/settings/tokens](https://github.com/settings/tokens) → **Generate new token (classic)**.

| Variable | Scope required | Purpose |
|---|---|---|
| `GITHUB_ORG_GHCR_PAT` | `read:packages` | Pull the `mlabs-runner` image from GHCR |
| `GITHUB_ORG_ADMIN_PAT` | `admin:org` | Manage self-hosted runners (list, unregister, clean deregistration on shutdown) |

Add to `~/.bashrc` or `~/.zshrc` on each machine:

```sh
export GITHUB_ORG_GHCR_PAT=ghp_...
export GITHUB_ORG_ADMIN_PAT=ghp_...
```

`HF_TOKEN` is stored as a GitHub org secret and injected by workflows — it does not need to be set on individual machines.

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

Terraform is installed directly in the image via the Hashicorp apt repo — the `hashicorp/setup-terraform` GitHub Actions action (which requires Node.js) is not used.

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

The [launch-runner.sh](scripts/gha/launch-runner.sh) script pulls the multi-arch image and runs the correct variant for the host. It is **idempotent** — if the container is already running it prints its status and exits cleanly.

```sh
# Org-level runner, foreground (Ctrl+C to stop and deregister)
# Machine label is auto-detected: wsl2 (amd64), dgx or agx (arm64 via /proc/device-tree/model)
./scripts/gha/launch-runner.sh

# Repo-level runner, detached
./scripts/gha/launch-runner.sh \
  --repo miramar-platform-gcp \
  --detach

# Ephemeral (deregisters after one job)
./scripts/gha/launch-runner.sh --ephemeral
```

**All options:**

| Flag | Default | Description |
|---|---|---|
| `--token` | *(auto-fetched)* | Runner registration token — fetched via `GITHUB_ORG_ADMIN_PAT` if not supplied |
| `--name` | hostname | Runner display name |
| `--labels` | `wsl2` / `dgx` / `agx` — auto-detected from arch and `/proc/device-tree/model` | Comma-separated runner labels |
| `--repo` | *(unset — org-level)* | Scope to a specific repo (`owner/repo`) |
| `--group` | `Default` | Runner group |
| `--ephemeral` | false | Deregister after one job |
| `--detach` | false | Run container in background (`docker run -d`) |

Work directory is mounted from `~/runner/_work` on the host into `/home/runner/_work` in the container.

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

**GCP resources (all in `miramar-platform`):**
- Pool: `projects/808481995423/locations/global/workloadIdentityPools/github-actions`
- Provider: `github` (OIDC, issuer `https://token.actions.githubusercontent.com`)
- Service account: `gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com`

### 1. WIF provider attribute condition

Controls which GitHub tokens the provider will accept. Must reference the correct org.

Check the current condition:
```sh
gcloud iam workload-identity-pools providers describe github \
  --project=miramar-platform \
  --location=global \
  --workload-identity-pool=github-actions \
  --format="value(attributeCondition)"
```

Expected: `attribute.repository_owner=='miramar-labs-org'`

Update if wrong:
```sh
gcloud iam workload-identity-pools providers update-oidc github \
  --project=miramar-platform \
  --location=global \
  --workload-identity-pool=github-actions \
  --attribute-condition="attribute.repository_owner=='miramar-labs-org'"
```

### 2. Service account IAM binding

Controls which WIF principal can impersonate the service account. Must reference the correct org.

Check the current binding:
```sh
gcloud iam service-accounts get-iam-policy \
  gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com \
  --project=miramar-platform \
  --format=json
```

Expected member: `principalSet://iam.googleapis.com/projects/808481995423/locations/global/workloadIdentityPools/github-actions/attribute.repository_owner/miramar-labs-org`

Add the correct binding:
```sh
gcloud iam service-accounts add-iam-policy-binding \
  gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com \
  --project=miramar-platform \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/808481995423/locations/global/workloadIdentityPools/github-actions/attribute.repository_owner/miramar-labs-org"
```

Remove any stale binding referencing an old org name:
```sh
gcloud iam service-accounts remove-iam-policy-binding \
  gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com \
  --project=miramar-platform \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/808481995423/locations/global/workloadIdentityPools/github-actions/attribute.repository_owner/OLD_ORG_NAME"
```

> If WIF auth fails with `iam.serviceAccounts.getAccessToken` denied, the SA binding is the most likely culprit — check the member value matches the current GitHub org name exactly.

---

## GCP Storage

All buckets are in project `miramar-platform`, region `us-west1`. → [GCS console](https://console.cloud.google.com/storage/browser?project=miramar-platform)

| Bucket | Purpose | Provisioned by |
|---|---|---|
| `miramar-platform-cluster-state` | Terraform state (`terraform/state/` prefix), GPU pool state (`terraform/gpu-state/` prefix), GKE node pool snapshots (`gke/` prefix) | **Miramar Platform Create** workflow (pre-`terraform init` step) |

The bucket is created before `terraform init` runs — it cannot be managed by the same Terraform config that uses it as a backend.

To create a bucket manually:

```sh
./scripts/gcp/create-bucket.sh \
  --bucket <name> \
  --project miramar-platform \
  --location us-west1
```

---

## Scripts

### `scripts/gha/` — GitHub Actions runner management

#### [launch-runner.sh](scripts/gha/launch-runner.sh)
Pull and start a self-hosted runner container. Idempotent — if the container is already running, prints its status and exits 0. Requires `GITHUB_ORG_GHCR_PAT` and `GITHUB_ORG_ADMIN_PAT` — registration token is fetched automatically.
```sh
# Org-level runner (default)
./scripts/gha/launch-runner.sh

# Repo-level, detached
./scripts/gha/launch-runner.sh --repo miramar-platform-gcp --detach

# Ephemeral (deregisters after one job)
./scripts/gha/launch-runner.sh --ephemeral
```

#### [stop-runner.sh](scripts/gha/stop-runner.sh)
Gracefully stop the mlabs-runner container. Sends SIGTERM, which triggers the entrypoint cleanup trap to deregister the runner from GitHub Actions before the container exits.
```sh
./scripts/gha/stop-runner.sh
```

#### [runners.sh](scripts/gha/runners.sh)
List all runners registered to the org, with status and labels.
```sh
./scripts/gha/runners.sh
```

#### [install-runner.sh](scripts/gha/install-runner.sh)
Install and register a runner directly on the host (no Docker). Useful for the Jetson AGX Orin or any machine where you want the runner running natively. Downloads the correct arch tarball, verifies the SHA256 checksum, configures, and optionally installs as a systemd service.
```sh
# Basic install (org-level, foreground)
./scripts/gha/install-runner.sh --labels "self-hosted,linux,arm64,agx"

# Install and start as a systemd service
./scripts/gha/install-runner.sh --labels "self-hosted,linux,arm64,agx" --service

# Repo-level, ephemeral
./scripts/gha/install-runner.sh --repo miramar-platform-gcp --ephemeral
```

#### [flush-queues.sh](scripts/gha/flush-queues.sh)
Cancel all in-progress, queued, and waiting workflow runs for the repo. Useful for clearing a stuck queue.
```sh
# Default: miramar-labs-org/miramar-platform-gcp
./scripts/gha/flush-queues.sh

# Another repo
./scripts/gha/flush-queues.sh miramar-labs-org/other-repo
```

#### [unregister-runner.sh](scripts/gha/unregister-runner.sh)
Remove a runner from the org via the GitHub API. Lists runners and prompts for ID, or pass a name directly.
```sh
# Interactive
./scripts/gha/unregister-runner.sh

# By name
./scripts/gha/unregister-runner.sh <runner-name>
```

#### [sync-github-vars.sh](scripts/gha/sync-github-vars.sh)
Sync `gcp/terraform/terraform.tfvars` to GitHub org variables. Run after editing tfvars to keep GitHub vars in sync.
```sh
./scripts/gha/sync-github-vars.sh
```

#### [get-github-secrets.sh](scripts/gha/get-github-secrets.sh)
Print the `WIF_PROVIDER` and `GCP_SERVICE_ACCOUNT` values for the platform. Use this after bootstrap to get the values to paste into GitHub secrets.
```sh
./scripts/gha/get-github-secrets.sh
```

---

### `scripts/gcp/` — GCP utilities

#### [resources.sh](scripts/gcp/resources.sh)
Enumerate live GCP resources in the `miramar-platform` project.
```sh
./scripts/gcp/resources.sh
```

#### [create-bucket.sh](scripts/gcp/create-bucket.sh)
Create a GCS bucket idempotently. Optionally grant a service account `storage.admin` on the project.
```sh
./scripts/gcp/create-bucket.sh \
  --bucket <name> \
  --project miramar-platform \
  --location us-west1 \
  --grant-sa <sa@project.iam.gserviceaccount.com>
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
| `gcp/bootstrap-miramar-platform.zsh` | One-time local setup — project, billing, APIs, WIF, service accounts, IAM. Run before any workflow. |
| `gcp/create-miramar-platform.zsh` | K8s setup only — AR IAM bindings + namespaces + RBAC. Called by the **Miramar Platform Create** workflow after `terraform apply`. |
| `gcp/list-miramar-platform.zsh` | Enumerate live GCP resources in the project |

---

## Platform Lifecycle Workflows

### Bootstrap (run locally once)

Before using any workflow, run the bootstrap script locally with an active gcloud session:

```sh
zsh ./gcp/bootstrap-miramar-platform.zsh 2>&1 | tee /tmp/bootstrap.log
```

This creates the GCP project, billing link, APIs, WIF pool/provider, and all service accounts + IAM bindings. The output prints two values to set as GitHub secrets:

| Secret | Scope |
|---|---|
| `WIF_PROVIDER` | Org-level secret (shared across all repos) |
| `GCP_SERVICE_ACCOUNT` | Repo-level secret on `miramar-platform-gcp` |

After setting those secrets, all subsequent workflows authenticate via WIF.

### Configuration (terraform.tfvars)

All platform config lives in `gcp/terraform/terraform.tfvars`. After any change:

```sh
./scripts/gha/sync-github-vars.sh   # push values to GitHub org variables
```

`GKE_STATE_BUCKET` is the only GitHub variable not sourced from tfvars — set it manually if it ever changes.

### [Miramar Platform Create](.github/workflows/miramar-platform-create.yaml)

1. Creates the GCS state bucket if missing
2. Runs `terraform apply -var-file=terraform.tfvars` — provisions GKE cluster + node pool + Artifact Registry repo
3. Runs `gcp/create-miramar-platform.zsh` — applies K8s namespaces, resource quotas, RBAC, and AR IAM bindings

```
Actions → Miramar Platform Create → Run workflow
```

> **First run after migrating from a gcloud-managed cluster** requires a destroy + create cycle. Terraform cannot adopt pre-existing resources without an import.

### [Miramar Platform Destroy](.github/workflows/miramar-platform-destroy.yaml)

**Permanently destroys the platform stack.** Runs `terraform destroy` to remove the GKE cluster, node pool, and AR repo. Falls back to gcloud for any resources not in Terraform state (e.g. pre-migration resources). Deletes the GCS state bucket separately (it cannot be in TF state). Optionally deletes the GCP project itself (30-day undelete window).

Three guards:
1. Type the exact project name (`miramar-platform`) in `confirm_project`
2. Check `i_confirm`
3. Check `delete_project` only if you also want the GCP project gone

```
Actions → Miramar Platform Destroy → Run workflow
```

---

## GKE Cluster Scaling Workflows

Two `workflow_dispatch` workflows let you temporarily expand the cluster for heavier workloads (ML deployments, load testing) and then restore it to its original size automatically. Both use `terraform apply` to resize — Terraform remains the authoritative source of node count.

Before the resize, Expand snapshots the full node pool JSON and the live node count into a GCS state file (`gs://miramar-platform-cluster-state/gke/node-pool-<pool>.json`). Restore reads that file — no manual count needed.

### [GKE Expand](.github/workflows/gke-expand.yaml)

Snapshots the current node pool state (machine type, configured count, live node count) to GCS, then runs `terraform apply -var=node_pool_count=N` and waits for all nodes to reach `Ready`.

1. Go to **Actions → GKE Expand → Run workflow**
2. Set `target_nodes` (default: `2`) and optionally `node_pool` (default: `default-pool`)

### [GKE Restore](.github/workflows/gke-restore.yaml)

Loads the saved state from GCS and runs `terraform apply -var=node_pool_count=<saved>` to scale back. Pass `node_count_override` only if you need to bypass the saved state.

1. Go to **Actions → GKE Restore → Run workflow**
2. Leave `node_count_override` blank (reads from GCS automatically)

Both workflows run on the `wsl2` self-hosted runner and authenticate to GCP via Workload Identity Federation.

---

## GPU Node Pool Workflows

Two `workflow_dispatch` workflows add a temporary GPU node pool for workloads that need a GPU (e.g. Triton Inference Server) and restore the cluster when done. The GPU pool is managed by a separate Terraform module (`gcp/terraform-gpu/`) with its own GCS state at `terraform/gpu-state/` — isolated from the main cluster state so regular expand/restore workflows cannot touch it.

The GPU pool is created in `us-west1-b` (T4/L4/P4 availability; the main cluster is in `us-west1-a`).

### [GKE Expand GPU](.github/workflows/gke-expand-gpu.yaml)

Runs `terraform apply` in `gcp/terraform-gpu/` to create the `gpu-triton-pool` node pool, installs the NVIDIA device plugin DaemonSet, and relaxes the target namespace's resource quota to allow GPU workloads. Snapshots the original quota to GCS before patching so Restore can revert it exactly. Running Expand on an already-running pool is a no-op.

**GPU options (`gpu_type` input):**

| gpu_type | Architecture | VRAM | Paired machine | Zone | Approx cost/hr |
|---|---|---|---|---|---|
| `nvidia-tesla-t4` *(default)* | Turing | 16 GB | `n1-standard-4` | `us-west1-b` | ~$0.54 |
| `nvidia-l4` | Ada Lovelace | 24 GB | `g2-standard-4` | `us-west1-b` | ~$0.74 |
| `nvidia-tesla-p4` | Pascal | 8 GB | `n1-standard-4` | `us-west1-b` | ~$0.42 |

T4 and L4 are recommended for inference workloads. L4 offers better throughput per dollar for larger models and FP8/INT8 serving. P4 is sufficient for lightweight models only.

1. Go to **Actions → GKE Expand GPU → Run workflow**
2. Set `namespace`, `machine_type`, and `gpu_type` as needed

### [GKE Restore GPU](.github/workflows/gke-restore-gpu.yaml)

Restores the namespace quota from the GCS snapshot, then runs `terraform destroy` in `gcp/terraform-gpu/` to delete the GPU node pool. If no pool exists in Terraform state, the destroy step is skipped.

1. Go to **Actions → GKE Restore GPU → Run workflow**
2. Confirm the `namespace` matches what was used in Expand
