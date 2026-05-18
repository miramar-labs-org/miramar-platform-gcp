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

| Service | Purpose |
|---|---|
| GKE Standard cluster (`miramar-shared-gke`) | Shared Kubernetes cluster for platform workloads |
| Artifact Registry (`apps`) | Docker image registry for built application images |
| Workload Identity Federation | Keyless auth from GitHub Actions to GCP — no long-lived service account keys |
| Two GCP projects | `miramar-cicd` (IAM / WIF) and `miramar-platform` (cluster / workloads) |

### CI/CD

| Service | Role |
|---|---|
| GitHub Actions | Workflow automation — build, test, deploy |
| GHCR (`ghcr.io/miramar-labs-org`) | Docker image hosting for the runner image and future app images |
| Self-hosted runners | Jobs requiring GPU, local network access, or aarch64 run on the physical machines above |

GitHub Actions workflows authenticate to GCP keylessly via Workload Identity Federation. Access is restricted to repos under the `miramar-labs` org.

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
- A **GitHub PAT** with `read:packages` scope for pulling images from GHCR:
  - https://github.com/settings/tokens → **Generate new token (classic)** → check `read:packages`
  - Pass via `--pat <token>` or the `GITHUB_ORG_PAT` env var
  - Or log in once via `gh` CLI: `gh auth token | docker login ghcr.io -u $(gh api user -q .login) --password-stdin`
  - Or log in once via PAT: `echo $GITHUB_ORG_PAT | docker login ghcr.io -u miramar-labs-org --password-stdin`

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
