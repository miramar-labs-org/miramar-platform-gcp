# Self-Hosted Runners

The repo uses a Docker-based GitHub Actions runner image for WSL2, DGX Spark,
and Jetson Orin.

| Image | Architectures |
| --- | --- |
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

| Flag | Default | Description |
| --- | --- | --- |
| `--token` | auto-fetched | Runner registration token |
| `--name` | hostname | Runner display name |
| `--labels` | auto-detected | `wsl2`, `dgx`, or `agx` plus standard labels |
| `--repo` | org-level | Scope to a repo |
| `--group` | `Default` | Runner group |
| `--ephemeral` | false | Deregister after one job |
| `--detach` | false | Run container in background |

If jobs queue while a runner is idle, check org runner group access:
**Org Settings -> Actions -> Runner groups -> Default -> Repository access**.

## Runner Scripts

| Script | Purpose |
| --- | --- |
| `scripts/gha/launch-runner.sh` | Pull and start the runner container |
| `scripts/gha/stop-runner.sh` | Stop and deregister the runner container |
| `scripts/gha/runners.sh` | List org runners |
| `scripts/gha/install-runner.sh` | Install a native runner without Docker |
| `scripts/gha/flush-queues.sh` | Cancel in-progress, queued, and waiting runs |
| `scripts/gha/unregister-runner.sh` | Remove a runner through the GitHub API |
| `scripts/gha/sync-github-tf-vars.sh` | Sync Terraform variables to GitHub org variables |
| `scripts/gha/get-github-secrets.sh` | Print WIF/GCP secret values after bootstrap |

## DGX volume mounts

`launch-runner.sh` adds these mounts when running on the DGX (`dgx` label):

| Host path | Container path | Purpose |
|---|---|---|
| `~/.minikube` | `/home/runner/.minikube` | Minikube state persists across container restarts |
| `~/.kube` | `/home/runner/.kube` | kubeconfig for minikube cluster access |
| `/usr/local/bin` | `/host-bin` | Workflows can install binaries to the host (e.g. minikube) |
| `~/shared/ssh` | `/home/runner/.ssh` | Shared SSH identity (if set up via **Setup Shared SSH Store**); enables workflows to SSH to the DGX host as the host user |
| `/run/avahi-daemon/socket` | `/run/avahi-daemon/socket` | `.local` mDNS resolution via host avahi daemon |

After any change to volume mounts in `launch-runner.sh`, restart the runner to apply:

```sh
./scripts/gha/stop-runner.sh && ./scripts/gha/launch-runner.sh --detach
```

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
