# Self-Hosted Runners

The repo uses a Docker-based GitHub Actions runner image for WSL2, DGX Spark,
and Jetson Orin.

| Image                                          | Architectures                |
| ---------------------------------------------- | ---------------------------- |
| `ghcr.io/miramar-labs-org/mlabs-runner:latest` | `linux/amd64`, `linux/arm64` |

The image is built by
[build-mlabs-runner.yml](../.github/workflows/build-mlabs-runner.yml) when
`mlabs-runner/**` changes on `main`.

## Image Contents

Base image: `nvidia/cuda:12.6.3-cudnn-runtime-ubuntu22.04`.

Included tooling:

- CI/CD: `docker-cli`, `kubectl`, `gcloud`, `terraform`, `gh`, `helm`, `ngc`,
  `make`, `openssh-client`, `zstd`
- ML: PyTorch, Hugging Face tooling, MLflow, TensorBoard, ONNX, scikit-learn,
  common scientific Python packages
- Audio/video: `ffmpeg`, `libsndfile1`, `sox`

Terraform is installed directly through the Hashicorp apt repo. The
`hashicorp/setup-terraform` action is intentionally not used.

Verify GPU access:

```sh
docker run --rm --gpus all ghcr.io/miramar-labs-org/mlabs-runner:latest \
  python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

## Launch

The launcher pulls the correct image variant for the host architecture and is
idempotent.

```sh
./scripts/gha/launch-runner.sh
./scripts/gha/launch-runner.sh --repo miramar-platform-gcp --detach
./scripts/gha/launch-runner.sh --ephemeral
```

Key options:

| Flag          | Default       | Description                                  |
| ------------- | ------------- | -------------------------------------------- |
| `--token`     | auto-fetched  | Runner registration token                    |
| `--name`      | hostname      | Runner display name                          |
| `--labels`    | auto-detected | `wsl2`, `dgx`, or `agx` plus standard labels |
| `--repo`      | org-level     | Scope to a repo                              |
| `--group`     | `Default`     | Runner group                                 |
| `--ephemeral` | false         | Deregister after one job                     |
| `--detach`    | false         | Run container in background                  |

If jobs queue while a runner is idle, check org runner group access:
**Org Settings -> Actions -> Runner groups -> Default -> Repository access**.

## Runner Scripts

| Script                               | Purpose                                          |
| ------------------------------------ | ------------------------------------------------ |
| `scripts/gha/launch-runner.sh`       | Pull and start the runner container              |
| `scripts/gha/stop-runner.sh`         | Stop and deregister the runner container         |
| `scripts/gha/runners.sh`             | List org runners                                 |
| `scripts/gha/install-runner.sh`      | Install a native runner without Docker           |
| `scripts/gha/flush-queues.sh`        | Cancel in-progress, queued, and waiting runs     |
| `scripts/gha/unregister-runner.sh`   | Remove a runner through the GitHub API           |
| `scripts/gha/sync-github-tf-vars.sh` | Sync Terraform variables to GitHub org variables |
| `scripts/gha/get-github-secrets.sh`  | Print WIF/GCP secret values after bootstrap      |

## Environment variables injected into the runner container

`launch-runner.sh` passes these env vars to every runner container:

| Variable               | Source                  | Purpose                                                   |
| ---------------------- | ----------------------- | --------------------------------------------------------- |
| `GITHUB_PAT`           | `$GITHUB_ORG_GHCR_PAT`  | GHCR login in the entrypoint (`read:packages`)            |
| `GITHUB_ORG_GHCR_PAT`  | `$GITHUB_ORG_GHCR_PAT`  | Available to workflow scripts (e.g. `deploy-kubeflow.sh`) |
| `GITHUB_ORG_ADMIN_PAT` | `$GITHUB_ORG_ADMIN_PAT` | Org variable/secret writes in workflow steps              |
| `HF_TOKEN`             | `$HF_TOKEN`             | Hugging Face model downloads (optional)                   |

These are host shell env vars, **not** GitHub Actions secrets — use `${VAR}` in `run:` blocks, not `${{ secrets.VAR }}`.

## DGX volume mounts

`launch-runner.sh` adds these mounts when running on the DGX (`dgx` label):

| Host path                  | Container path             | Purpose                                                                                                                   |
| -------------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `~/.kube`                  | `/home/runner/.kube`       | kubeconfig for k3s cluster access                                                                                         |
| `/usr/local/bin`           | `/host-bin`                | Workflows can install binaries to the host (e.g. kubectl, helm)                                                           |
| `~/shared/ssh`             | `/home/runner/.ssh`        | Shared SSH identity (if set up via **Setup Shared SSH Store**); enables workflows to SSH to the DGX host as the host user |
| `/run/avahi-daemon/socket` | `/run/avahi-daemon/socket` | `.local` mDNS resolution via host avahi daemon                                                                            |

## AGX volume mounts

`launch-runner.sh` adds the same mounts when running on AGX (`agx` label):

| Host path                  | Container path             | Purpose                                    |
| -------------------------- | -------------------------- | ------------------------------------------ |
| `~/.kube`                  | `/home/runner/.kube`       | kubeconfig for k3s cluster access          |
| `/usr/local/bin`           | `/host-bin`                | Workflows can install binaries to the host |
| `~/shared/ssh`             | `/home/runner/.ssh`        | Shared SSH identity                        |
| `/run/avahi-daemon/socket` | `/run/avahi-daemon/socket` | `.local` mDNS resolution                   |

After any change to volume mounts in `launch-runner.sh`, restart the runner to apply:

```sh
# If managed by systemd (DGX / AGX):
systemctl --user restart mlabs-runner

# If running manually:
./scripts/gha/stop-runner.sh && ./scripts/gha/launch-runner.sh
```

## Persistent runner via systemd (DGX and AGX)

`mlabs-runner.service` keeps the runner alive across reboots on DGX Spark and AGX Orin. It is installed by `dgx/systemd/install.sh` (AGX: `agx/systemd/install.sh`) as part of the standard user service stack.

```sh
# Status
systemctl --user status mlabs-runner

# Live logs (runner registration, job pickup, deregistration)
journalctl --user -u mlabs-runner -f

# Manual restart (e.g. after rotating PATs)
systemctl --user restart mlabs-runner
```

PATs are loaded from `~/.config/systemd/user/mlabs-runner.env` (chmod 600), created automatically by `install.sh` with values seeded from the current session. Edit and restart if you rotate tokens:

```sh
vi ~/.config/systemd/user/mlabs-runner.env
# GITHUB_ORG_ADMIN_PAT=ghp_...
# GITHUB_ORG_GHCR_PAT=ghp_...
# HF_TOKEN=hf_...
systemctl --user restart mlabs-runner
```

`ExecStop` runs `stop-runner.sh` on service stop/reboot — the runner deregisters gracefully from GitHub before the container exits (`TimeoutStopSec=40`). `ExecStartPre` stops any stale container before launch, which means **`systemctl --user restart mlabs-runner` will interrupt any in-flight job** — avoid restarting while a workflow is running.

## Rebuild

```sh
gh workflow run build-mlabs-runner.yml \
  --field runner_version=2.334.0
```

Local multi-arch build:

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg RUNNER_VERSION=2.334.0 \
  -f mlabs-runner/Dockerfile \
  -t ghcr.io/miramar-labs-org/mlabs-runner:local \
  mlabs-runner/
```
