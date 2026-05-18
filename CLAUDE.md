# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure and CI/CD tooling for the Miramar platform on GCP. It provisions two GCP projects (`miramar-cicd` and `miramar-platform`), a shared GKE Standard cluster, Artifact Registry, and Workload Identity Federation for keyless GitHub Actions auth. It also contains Docker images and a launch script for self-hosted GitHub Actions runners.

## Key scripts

| Script | Purpose |
|---|---|
| `setup-miramar-gke-cicd.zsh` | Full idempotent bootstrap — projects, billing, APIs, WIF, GKE, namespaces, RBAC |
| `install-gcloud-terraform.zsh` | Install `gcloud` + `terraform` via apt on Ubuntu/Debian |
| `pause-miramar-platform.zsh` / `resume-miramar-platform.zsh` | Scale GKE node pool to 0 / back up |
| `list-resources-miramar-platform.zsh` | Enumerate live GCP resources |
| `verify-nuked-miramar-platform.zsh` | Confirm everything is torn down after deletion |
| `patch-namespace-manager-rbac.zsh` | Patch RBAC after cluster re-create |

All scripts are zsh (`#!/usr/bin/env zsh`) and require `gcloud` and `kubectl` on `$PATH` with an active authenticated session.

## Terraform

`terraform/` manages the GKE cluster and node pool only (does not manage IAM, WIF, or Artifact Registry — those are handled by `setup-miramar-gke-cicd.zsh`).

```sh
cd terraform
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

`gha-runners/` contains Docker images for running GitHub Actions runners on the two self-hosted machines: an x86_64 laptop (WSL2/Ubuntu) and an aarch64 Spark DGX.

**Build:** triggered automatically by `.github/workflows/build-gha-runners.yml` on push to `main`. Uses QEMU + buildx on GitHub-hosted runners to cross-compile both arches. Images push to GHCR as `ghcr.io/miramar-labs-org/gha-runner-amd64` and `ghcr.io/miramar-labs-org/gha-runner-arm64`.

**Launch:**
```sh
./gha-runners/launch-runner.sh --token <RUNNER_TOKEN>
```
The script auto-detects arch (`uname -m`) and pulls the matching image. By default registers as an org-level runner for `miramar-labs-org`. Use `--repo <name>` for repo-level scope.

**Runner registration tokens** are obtained from GitHub UI or API and expire after 1 hour. The container deregisters cleanly on `SIGTERM`.

To bump the runner version, update `RUNNER_VERSION` in both Dockerfiles or trigger `workflow_dispatch` with the `runner_version` input.
