# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure and CI/CD tooling for the Miramar platform on GCP. It provisions a single GCP project (`miramar-platform`) containing a shared GKE Standard cluster, Artifact Registry, Workload Identity Federation for keyless GitHub Actions auth, and supporting resources. It also contains Docker images and a launch script for self-hosted GitHub Actions runners.

## Platform topology

**Physical machines (self-hosted GHA runners):**
- **Windows laptop / WSL2** — Ubuntu 24.04, x86_64 (amd64), AMD CPU, NVIDIA RTX 4060 (sm_89). Runner label: `wsl2`.
- **NVIDIA DGX Spark 128GB** — DGX OS (Ubuntu), aarch64 (arm64), 20-core Arm CPU (10× Cortex-X925 + 10× Cortex-A725), GB10 Superchip Blackwell GPU (6144 CUDA cores, 5th-gen Tensor Cores). Runner label: `dgx`.
- **NVIDIA Jetson AGX Orin 64GB** — Ubuntu JetPack 6.x, aarch64 (arm64), 12-core Cortex-A78AE, Ampere GPU 2048 CUDA cores (sm_87), CUDA 12.6. Runner label: `agx`. Uses `mlabs-runner:jetson` (L4T-based) — Tegra unified-memory GPU is incompatible with standard `nvidia/cuda` server images.

**GCP:**
- `miramar-platform` — single project hosting GKE Standard cluster (`miramar-shared-gke`), Artifact Registry (`apps`), WIF pool/provider, and deploy service accounts.
- WIF provides keyless GitHub Actions → GCP auth; no long-lived service account keys.

**CI/CD:**
- GitHub Actions workflows on both GitHub-hosted and the two self-hosted runners above.
- GHCR (`ghcr.io/miramar-labs-org`) hosts the `mlabs-runner` image and future app images.

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
| `gcp/bootstrap-miramar-project.zsh` | One-time project setup — project creation, billing, APIs, WIF pool/provider, service accounts, IAM bindings |
| `gcp/create-miramar-platform.zsh` | Platform resource provisioning — Artifact Registry, GKE cluster, GCS state bucket, K8s namespaces + RBAC |
| `gcp/pause-miramar-platform.zsh` / `gcp/resume-miramar-platform.zsh` | Scale GKE node pool to 0 / back up |
| `gcp/verify-nuked-miramar-platform.zsh` | Confirm everything is torn down after deletion |
| `gcp/patch-namespace-manager-rbac.zsh` | Patch RBAC after cluster re-create |
| `scripts/gcp/list-resources-miramar-platform.zsh` | Enumerate live GCP resources |
| `scripts/ubuntu/install-gcloud.sh` | Install `gcloud` via apt on Ubuntu/Debian |
| `scripts/ubuntu/install-terraform.sh` | Install `terraform` via apt on Ubuntu/Debian |

GCP zsh scripts require `gcloud` on `$PATH` with an active authenticated session. `create-miramar-platform.zsh` additionally requires `kubectl`.

Run order for a fresh environment: `bootstrap-miramar-project.zsh` → set GitHub secrets → `create-miramar-platform.zsh`.

## GKE cluster scaling workflows

Two `workflow_dispatch` workflows in `.github/workflows/` temporarily expand the cluster for heavier workloads and then restore it:

| Workflow | File | Purpose |
|---|---|---|
| Bootstrap Project | `bootstrap-project.yaml` | One-time project setup — billing, APIs, WIF, service accounts. Cold-start aware; prints secrets to set after first run |
| Miramar Platform Create | `miramar-platform-create.yaml` | Provision/re-provision platform resources — Artifact Registry, GKE cluster, GCS bucket, namespaces, RBAC |
| Miramar Platform Destroy | `miramar-platform-destroy.yaml` | Tear down cluster, AR, state bucket, optionally the project — requires typed project name + checkbox |
| GKE Cluster Expand | `gke-cluster-expand.yaml` | Scale `e2-medium-pool` to N nodes; saves full state to GCS |
| GKE Cluster Restore | `gke-cluster-restore.yaml` | Scale back to the original node count from the Expand summary |

Typical sequence: run **Expand** → deploy workload → run **Restore**. Both run on `[self-hosted, wsl2]` and authenticate via WIF. Expand saves the full node pool JSON plus live node count to `gs://miramar-platform-cluster-state/gke/node-pool-<pool>.json`; Restore reads from it automatically — no manual count needed. `node_count_override` on Restore is available as a fallback. Requires a one-time bucket create + SA IAM grant (see README).

## Terraform

`gcp/terraform/` manages the GKE cluster and node pool only (does not manage IAM, WIF, or Artifact Registry — those are handled by the bootstrap and create scripts).

```sh
cd gcp/terraform
terraform init -backend-config="bucket=<STATE_BUCKET>"
terraform plan -var="project_id=miramar-platform"
terraform apply -var="project_id=miramar-platform"
```

State is stored in GCS (bucket configured at init time). Default variables: `us-west1-a`, `e2-medium`, 1 node.

## GCP project structure

Single project: **`miramar-platform`** — GKE cluster (`miramar-shared-gke`), Artifact Registry repo (`apps`), WIF pool/provider, deploy service accounts, and workloads.

GitHub Actions authenticate keylessly via Workload Identity Federation. The WIF attribute condition restricts access to repos under the `miramar-labs-org` GitHub org.

## Cost-control constraints

The cluster is intentionally minimized. These constraints must be preserved:
- Node type: `e2-medium`, single node, `pd-standard` disk
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
