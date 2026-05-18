# miramar-platform-gcp

GCP infrastructure and CI/CD tooling for the Miramar platform.

## Platform Overview

### Physical machines

Two on-premises machines act as self-hosted GitHub Actions runners and general compute:

| Machine | OS | Arch | Notes |
|---|---|---|---|
| Windows laptop | Ubuntu 24.04 (WSL2) | x86_64 / amd64 | AMD CPU |
| NVIDIA Spark DGX | Ubuntu | aarch64 / arm64 | GB10 Superchip GPU |

Both run the [mlabs-runner](mlabs-runner/) Docker image. The WSL2 machine carries the `wsl2` runner label; the DGX carries `dgx`.

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

GitHub Actions workflows authenticate to GCP keylessly via Workload Identity Federation. Access is restricted to repos under the `miramar-labs` org.

---

## MLflow (DGX)

MLflow runs on the NVIDIA Spark DGX out of `~/mlflow`. It is not exposed publicly — access the UI by opening an SSH tunnel from your laptop:

```sh
ssh -L 5000:localhost:5000 aaron@spark-79b7.local
```

Then open **[http://localhost:5000](http://localhost:5000)** in your browser. The tunnel stays open for as long as the SSH session is running.

---

## Required Environment Variables

Two GitHub classic PATs must be set as environment variables on each machine. Create them at [github.com/settings/tokens](https://github.com/settings/tokens) → **Generate new token (classic)**.

| Variable | Scope required | Purpose |
|---|---|---|
| `GITHUB_ORG_PAT` | `read:packages` | Pull the `mlabs-runner` image from GHCR |
| `GITHUB_ADMIN_PAT` | `admin:org` | Manage self-hosted runners (list, unregister, clean deregistration on shutdown) |

Add both to `~/.bashrc` or `~/.zshrc` on each machine:

```sh
export GITHUB_ORG_PAT=ghp_...
export GITHUB_ADMIN_PAT=ghp_...
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

### Prerequisites

- Docker installed on the host machine
- A **runner registration token** — obtain one from:
  - **Org-level:** https://github.com/organizations/miramar-labs-org/settings/actions/runners/new
  - **Repo-level:** `https://github.com/miramar-labs-org/<repo>/settings/actions/runners/new`
  - Tokens expire after 1 hour and are single-use
- **`GITHUB_ORG_PAT`** set as an environment variable — see [Required Environment Variables](#required-environment-variables) above.

### Launch

The [launch-runner.sh](scripts/gha/launch-runner.sh) script pulls the multi-arch image and runs the correct variant for the host.

```sh
# Org-level runner, foreground (Ctrl+C to stop and deregister)
./scripts/gha/launch-runner.sh --token <RUNNER_TOKEN>

# Repo-level runner, detached
./scripts/gha/launch-runner.sh --token <RUNNER_TOKEN> \
  --repo miramar-platform-gcp \
  --detach

# Custom labels, ephemeral (deregisters after one job)
./scripts/gha/launch-runner.sh --token <RUNNER_TOKEN> \
  --labels "self-hosted,linux,amd64,gpu" \
  --ephemeral
```

**All options:**

| Flag | Default | Description |
|---|---|---|
| `--token` | *(required)* | Runner registration token |
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

## Scripts

### `scripts/gha/` — GitHub Actions runner management

#### [launch-runner.sh](scripts/gha/launch-runner.sh)
Pull and start a self-hosted runner container. Requires `GITHUB_ORG_PAT` and a registration token.
```sh
# Org-level runner (default)
./scripts/gha/launch-runner.sh --token <RUNNER_TOKEN>

# Repo-level, detached
./scripts/gha/launch-runner.sh --token <RUNNER_TOKEN> --repo miramar-platform-gcp --detach

# Ephemeral (deregisters after one job)
./scripts/gha/launch-runner.sh --token <RUNNER_TOKEN> --ephemeral
```

#### [list-runners.sh](scripts/gha/list-runners.sh)
List all runners registered to the org, with status and labels.
```sh
./scripts/gha/list-runners.sh
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

#### [list-resources-miramar-platform.zsh](scripts/gcp/list-resources-miramar-platform.zsh)
Enumerate live GCP resources in the `miramar-platform` project.
```sh
./scripts/gcp/list-resources-miramar-platform.zsh
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
