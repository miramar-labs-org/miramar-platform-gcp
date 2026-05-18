# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure and CI/CD tooling for the Miramar platform on GCP. It provisions two GCP projects (`miramar-cicd` and `miramar-platform`), a shared GKE Standard cluster, Artifact Registry, and Workload Identity Federation for keyless GitHub Actions auth. It also contains Docker images and a launch script for self-hosted GitHub Actions runners.

## Directory layout

```
gcp/               # GCP provisioning scripts + Terraform
  terraform/       # GKE cluster / node pool
scripts/
  gcp/             # Utility GCP scripts
  gha/             # GHA runner launch script
  ubuntu/          # Host setup scripts
mlabs-runner/      # Docker image for self-hosted GHA runners
.github/workflows/ # CI — builds mlabs-runner image
```

## Key scripts

| Script | Purpose |
|---|---|
| `gcp/setup-miramar-gke-cicd.zsh` | Full idempotent bootstrap — projects, billing, APIs, WIF, GKE, namespaces, RBAC |
| `gcp/pause-miramar-platform.zsh` / `gcp/resume-miramar-platform.zsh` | Scale GKE node pool to 0 / back up |
| `gcp/verify-nuked-miramar-platform.zsh` | Confirm everything is torn down after deletion |
| `gcp/patch-namespace-manager-rbac.zsh` | Patch RBAC after cluster re-create |
| `scripts/gcp/list-resources-miramar-platform.zsh` | Enumerate live GCP resources |
| `scripts/ubuntu/install-gcloud.sh` | Install `gcloud` via apt on Ubuntu/Debian |
| `scripts/ubuntu/install-terraform.sh` | Install `terraform` via apt on Ubuntu/Debian |

GCP zsh scripts require `gcloud` and `kubectl` on `$PATH` with an active authenticated session.

## Terraform

`gcp/terraform/` manages the GKE cluster and node pool only (does not manage IAM, WIF, or Artifact Registry — those are handled by `gcp/setup-miramar-gke-cicd.zsh`).

```sh
cd gcp/terraform
terraform init -backend-config="bucket=<STATE_BUCKET>"
terraform plan -var="project_id=miramar-platform"
terraform apply -var="project_id=miramar-platform"
```

State is stored in GCS (bucket configured at init time). Default variables: `us-west1-a`, `e2-micro`, 1 node.

## GCP project structure

- **`miramar-cicd`** — IAM, WIF pool/provider, deploy service accounts. Acts as the billing-project for API calls.
- **`miramar-platform`** — GKE cluster (`miramar-shared-gke`), Artifact Registry repo (`apps`), workloads.

GitHub Actions authenticate keylessly via Workload Identity Federation. The WIF attribute condition restricts access to repos under the `miramar-labs` GitHub org.

## Cost-control constraints

The cluster is intentionally minimized. These constraints must be preserved:
- Node type: `e2-micro`, single node, `pd-standard` disk
- No `LoadBalancer` Services — use `ClusterIP` + `kubectl port-forward` for testing
- No PersistentVolumeClaims, Cloud NAT, or regional clusters

## Self-hosted GHA runners

`mlabs-runner/` contains the Dockerfile and entrypoint for running GitHub Actions runners on the two self-hosted machines: an x86_64 laptop (WSL2/Ubuntu) and an aarch64 Spark DGX.

**Build:** triggered automatically by `.github/workflows/build-mlabs-runner.yml` on push to `main`. Uses QEMU + buildx to produce a single multi-arch manifest (`linux/amd64`, `linux/arm64`). Image pushes to GHCR as `ghcr.io/miramar-labs-org/mlabs-runner`.

**Launch:**
```sh
./scripts/gha/launch-runner.sh --token <RUNNER_TOKEN>
```
Docker pulls the correct arch variant automatically. By default registers as an org-level runner for `miramar-labs-org`. Use `--repo <name>` for repo-level scope.

**Runner registration tokens** are obtained from GitHub UI or API and expire after 1 hour. The container deregisters cleanly on `SIGTERM`.

To bump the runner version, update `RUNNER_VERSION` in `mlabs-runner/Dockerfile` or trigger `workflow_dispatch` with the `runner_version` input.
