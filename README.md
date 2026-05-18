# miramar-platform-gcp

GCP infrastructure and CI/CD tooling for the Miramar platform.

## GHA Self-Hosted Runners

Docker-based GitHub Actions runners for self-hosted machines. Supports `amd64` (x86_64) and `arm64` (aarch64).

### Images

Images are built and pushed to GHCR by the [build-gha-runners workflow](.github/workflows/build-gha-runners.yml) on every push to `main` that touches `gha-runners/**`.

| Architecture | Image |
|---|---|
| amd64 (x86_64) | [`ghcr.io/miramar-labs-org/gha-runner-amd64:latest`](https://github.com/orgs/miramar-labs-org/packages/container/package/gha-runner-amd64) |
| arm64 (aarch64) | [`ghcr.io/miramar-labs-org/gha-runner-arm64:latest`](https://github.com/orgs/miramar-labs-org/packages/container/package/gha-runner-arm64) |

### Prerequisites

- Docker installed on the host machine
- A runner registration token — obtain one from:
  - **Org-level:** `https://github.com/organizations/miramar-labs-org/settings/actions/runners/new`
  - **Repo-level:** `https://github.com/miramar-labs-org/<repo>/settings/actions/runners/new`
- `docker login ghcr.io -u <github-username> --password-stdin` (use a PAT with `read:packages`)

### Launch

The [launch-runner.sh](gha-runners/launch-runner.sh) script detects the host architecture and runs the correct image.

```sh
# Org-level runner, foreground (Ctrl+C to stop and deregister)
./gha-runners/launch-runner.sh --token <RUNNER_TOKEN>

# Repo-level runner, detached
./gha-runners/launch-runner.sh --token <RUNNER_TOKEN> \
  --repo miramar-platform-gcp \
  --detach

# Custom labels, ephemeral (deregisters after one job)
./gha-runners/launch-runner.sh --token <RUNNER_TOKEN> \
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

### Rebuilding images

Triggered automatically on push. To rebuild manually with a specific runner version:

```sh
gh workflow run build-gha-runners.yml \
  --field runner_version=2.334.0
```

Or locally:

```sh
# amd64
docker build --build-arg RUNNER_VERSION=2.334.0 \
  -f gha-runners/Dockerfile.amd64 \
  -t ghcr.io/miramar-labs-org/gha-runner-amd64:local \
  gha-runners/

# arm64
docker build --build-arg RUNNER_VERSION=2.334.0 \
  -f gha-runners/Dockerfile.arm64 \
  -t ghcr.io/miramar-labs-org/gha-runner-arm64:local \
  gha-runners/
```
