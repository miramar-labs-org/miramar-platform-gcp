# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure and CI/CD tooling for the Miramar platform on GCP. It provisions a single GCP project (`miramar-platform`) containing a shared GKE Standard cluster, Artifact Registry, Workload Identity Federation for keyless GitHub Actions auth, and supporting resources. It also contains Docker images and a launch script for self-hosted GitHub Actions runners.

## Platform topology

Runner labels: `wsl2` (amd64 laptop), `dgx` (arm64 DGX Spark), `agx` (arm64 AGX Orin). See global CLAUDE.md for hardware specs.

**GCP:** single project `miramar-platform` — GKE cluster (`miramar-shared-gke`), Artifact Registry (`apps`), WIF for keyless GitHub Actions auth.
**GHCR:** `ghcr.io/miramar-labs-org` — hosts `mlabs-runner` and app images.

## Directory layout

```
gcp/               # GCP provisioning scripts
  terraform/       # GKE cluster + node pool + Artifact Registry (Terraform)
  terraform-gpu/   # Transient GPU node pool (separate Terraform root module)
scripts/
  gcp/             # Utility GCP scripts
  gha/             # GHA runner launch script
  ubuntu/          # Host setup scripts
  security/        # scan-actions-risk.sh, repo-security-check.sh
  dashboard/       # generate-dashboard.sh (GitHub Pages platform dashboard)
mlabs-runner/      # Docker image for self-hosted GHA runners
dgx/               # DGX Spark host config and local tooling
  minikube/        # GHA workflows for minikube lifecycle + NeMo deployment
  ollama/          # Ollama deploy/undeploy scripts and model catalog
  systemd/         # Systemd user service unit files + install/uninstall scripts
wsl2/              # WSL2 host config and bootstrap scripts
  README.md           # Operator quickstart for WSL2 provisioning
  TECHNICAL.md        # Source of truth for template builds, lifecycle, on-demand SSH, and troubleshooting

docs/              # Architecture and runbooks
  index.md         # Source-of-truth map for docs and runbooks
  configuration.md # GitHub secrets, variables, and host env vars
  runners.md       # Self-hosted runner image and launch scripts
  gcp.md           # GCP bootstrap, Terraform, WIF, and state storage
  workflows.md     # Workflow catalog
  dgx.md           # DGX local AI stack operations
  ssh-runbook.md   # Full SSH mesh topology and troubleshooting
.github/workflows/ # CI/CD workflows
```

## Key scripts

| Script | Purpose |
|--------|---------|
| `gcp/bootstrap-miramar-platform.zsh` | One-time local setup — project creation, billing, APIs, WIF pool/provider, service accounts, IAM |
| `gcp/create-miramar-platform.zsh` | K8s-only setup — AR IAM bindings, namespaces, resource quotas, RBAC |
| `scripts/gha/sync-github-tf-vars.sh` | Sync `gcp/terraform/terraform.tfvars` → GitHub org variables. Never edit GitHub vars directly — edit tfvars and re-sync. |
| `scripts/gha/launch-runner.sh` / `stop-runner.sh` | Start / gracefully stop+deregister the mlabs-runner container. Idempotent. |
| `scripts/gha/flush-queues.sh` | Cancel all in-progress, queued, and waiting workflow runs |
| `dgx/systemd/install.sh` / `uninstall.sh` | Install or remove the five DGX systemd user services |
| `wsl2/bootstrap.sh` | One-time setup for a fresh WSL2 template base. Run inside the clean template before exporting. |
| `wsl2/rebuild-template.ps1` | Rebuild the configured template tarball. Params: `-SmbPassword` (required). Run after changing `bootstrap.sh` or rotating the Samba password. |
| `wsl2/firstboot.sh` | One-shot provisioning inside a new distro via `wsl -d NAME --user root -- bash`. Sets hostname, sshd port, calls `setup-shared-ssh.sh`. |
| `wsl2/setup-shared-ssh.sh` | Mounts `//DGX/shared` and symlinks `~/.ssh/` to shared store. All machines share Spark's SSH identity. Idempotent. |
| `wsl2/probe-ssh-ports.ps1` | Find a safe sshd port before provisioning. Usage: `.\probe-ssh-ports.ps1 -Distro dev -StartPort 2222 -EndPort 2299` |

GCP zsh scripts require `gcloud` on `$PATH` with an active authenticated session. `create-miramar-platform.zsh` additionally requires `kubectl`.

Run order for a fresh environment: `bootstrap-miramar-platform.zsh` → set GitHub secrets → run **Miramar Platform Create** workflow.

## Terraform

Two root modules — keep them separate, they must never share state.

**`gcp/terraform/`** — manages the GKE cluster, node pool (`default-pool`), and Artifact Registry repo. IAM and WIF are handled by the bootstrap script and are intentionally outside Terraform.

**Source of truth: `gcp/terraform/terraform.tfvars`** — all platform config values live here. GitHub org variables are synced from this file via `scripts/gha/sync-github-tf-vars.sh`. Never edit GitHub vars directly; edit tfvars and re-sync.

```sh
# After editing terraform.tfvars:
./scripts/gha/sync-github-tf-vars.sh

# Local plan/apply (bucket must exist first):
cd gcp/terraform
terraform init -backend-config="bucket=miramar-platform-cluster-state"
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

State is stored in GCS at `gs://miramar-platform-cluster-state/terraform/state/`. `GKE_STATE_BUCKET` is the one GitHub variable not in tfvars (it is the backend config itself).

**`gcp/terraform-gpu/`** — manages the transient `gpu-pool` GPU node pool only. Separate state at `gs://miramar-platform-cluster-state/terraform/gpu-state/`. Config in `gcp/terraform-gpu/gpu.tfvars`.

**Note:** the mlabs-runner Docker image has Terraform pre-installed via the Hashicorp apt repo. The `hashicorp/setup-terraform` action is intentionally not used (requires Node.js).

## Platform lifecycle workflows

Bootstrap is run **locally** (not via workflow) — requires an active gcloud session:

```sh
zsh ./gcp/bootstrap-miramar-platform.zsh 2>&1 | tee /tmp/bootstrap.log
```

Output includes `WIF_PROVIDER` (org-level secret) and `GCP_SERVICE_ACCOUNT` (repo-level secret). All workflows use WIF from that point on.

Org-level variables synced from `terraform.tfvars`: `GCP_PROJECT_ID`, `GKE_CLUSTER_NAME`, `GKE_ZONE`, `GCP_REGION`, `GAR_REPO`. `GKE_STATE_BUCKET` is set manually.

`workflow_dispatch` workflows in `.github/workflows/`:

| Workflow | File | Purpose |
|---|---|---|
| Miramar Platform Create | `miramar-platform-create.yaml` | `terraform apply` (GKE + AR) then K8s namespaces + RBAC |
| Miramar Platform Destroy | `miramar-platform-destroy.yaml` | `terraform destroy`, gcloud fallback, optionally delete project |
| GKE Expand | `gke-expand.yaml` | Snapshot pool state to GCS, scale up node count |
| GKE Restore | `gke-restore.yaml` | Read saved state from GCS, restore node count |
| GKE Expand GPU | `gke-expand-gpu.yaml` | Add transient GPU node pool via `terraform-gpu/` |
| GKE Restore GPU | `gke-restore-gpu.yaml` | Remove GPU node pool via `terraform destroy` in `terraform-gpu/` |
| Find GPU Capacity | `find-gpu-capacity.yaml` | Probe GPU availability; top 5 cheapest with [USE NOW] / [REQUEST QUOTA FIRST] |
| Minikube Install | `install-minikube.yaml` | Install minikube on DGX, start cluster, enable addons, update kubeconfig secret |
| Minikube Uninstall | `uninstall-minikube.yaml` | Delete cluster, purge state, remove binary |
| Minikube Toggle | `toggle-minikube.yaml` | `minikube pause` / `unpause`. Inputs: `action`, `runner` |
| NeMo Deploy | `deploy-nemo.yaml` | Install NeMo + Volcano via Helm; `nemo_version` input (default `25.12.1`); auto-commits doc/hosts/SDK updates; writes `NEMO_VERSION` repo var |
| NeMo Undeploy | `undeploy-nemo.yaml` | Uninstall NeMo + Volcano; deletes postgres PVCs first to prevent password drift |
| NIM Deploy | `deploy-nim.yaml` | Deploy NIM via NeMo API; swaps any different running NIM first; rollback on failure; writes `CURRENT_NIM_MODEL` repo var |
| NIM Undeploy | `undeploy-nim.yaml` | Undeploy NIM via NeMo API; 404 is a no-op; clears `CURRENT_NIM_MODEL` |
| MLflow Deploy | `deploy-mlflow.yaml` | Deploy MLflow + MinIO into mlflow-system |
| MLflow Undeploy | `undeploy-mlflow.yaml` | Remove MLflow, MinIO, and mlflow-system namespace |
| Build KFP arm64 Images | `build-kfp-arm64.yaml` | Build all 13 KFP arm64 images (11 KFP components + 2 MLMD/Bazel) on DGX. Optional `component` input to rebuild a single image. ~45-60 min for MLMD on first run. |
| Kubeflow Deploy | `deploy-kubeflow.yaml` | Deploy KFP standalone; patches all 13 deployments with native arm64 images; writes `KFP_VERSION` repo var. Prerequisite: Build KFP arm64 Images. |
| Create Project | `create-project.yaml` | Create a new repo under miramar-labs-org pre-wired for the platform. Three types: `default` (generic notebook + platform endpoint reference, new default), `kfp` (KFP v2 pipeline stub + deploy/undeploy workflows), `nemo` (NeMo training job + deploy/undeploy workflows). Defaults to public so the project appears in the dashboard. Tags repo with `miramar-project` + `miramar-<type>`. |
| Delete Project | `delete-project.yaml` | Permanently delete a platform repo. Double-entry confirmation guard. Triggers dashboard refresh on completion. Requires `delete_repo` scope on `GITHUB_ORG_ADMIN_PAT`. |
| Deploy Platform Dashboard | `deploy-dashboard.yaml` | Build and deploy the GitHub Pages project dashboard. Reads platform state repo vars (see below). Runs hourly + on completion of any state-writing workflow (NeMo/KFP/Ollama/NIM deploy-undeploy). URL: https://miramar-labs-org.github.io/miramar-platform-gcp/ |
| Kubeflow Undeploy | `undeploy-kubeflow.yaml` | Remove KFP and cluster-scoped resources |
| Ollama Deploy | `deploy-ollama.yaml` | Auto-undeploy existing Ollama model, then pull + load new one; rollback on failure; writes `CURRENT_OLLAMA_MODEL` repo var. Fails if NIM loaded or model > 100 GB. |
| Ollama Undeploy | `undeploy-ollama.yaml` | Unload Ollama model from GPU memory; auto-detects if blank; clears `CURRENT_OLLAMA_MODEL` |
| Ollama Update | `update-ollama.yaml` | Install/upgrade Ollama on DGX or WSL2 host; writes `OLLAMA_VERSION` repo var |
| Setup Shared SSH Store | `setup-shared-ssh.yaml` | One-time: wire DGX + Orin shared SSH store |
| WSL2 Provision | `provision-wsl2.yaml` | Import distro, run firstboot, add to WSL2_DISTROS |
| WSL2 Verify SSH Topology | `verify-ssh-topology.yaml` | Test all SSH paths for active distros in WSL2_DISTROS |
| WSL2 Unprovision | `unprovision-wsl2.yaml` | Unregister distro, remove from WSL2_DISTROS |

**Platform state repo variables** (written by workflows, read by dashboard):

| Variable | Set by | Cleared by | Default |
|---|---|---|---|
| `NEMO_VERSION` | NeMo Deploy | — | `25.12.1` |
| `KFP_VERSION` | Kubeflow Deploy | — | `2.16.1` |
| `OLLAMA_VERSION` | Ollama Update | — | set by `update-ollama.yaml` |
| `CURRENT_NIM_MODEL` | NIM Deploy | NIM Undeploy, NIM Deploy rollback | `none` |
| `CURRENT_OLLAMA_MODEL` | Ollama Deploy | Ollama Undeploy, Ollama Deploy rollback | `none` |

Variables must exist before the dashboard reads them. On a fresh install, create missing variables via the GitHub API (PATCH→POST upsert using `GITHUB_ORG_ADMIN_PAT`) or the GitHub UI (`Settings → Secrets and variables → Actions → Variables`).

Typical node-count sequence: **GKE Expand** → deploy workload → **GKE Restore**. Restore reads saved state automatically — no manual count needed.

Typical GPU sequence: **GKE Expand GPU** → deploy GPU workload → **GKE Restore GPU**.

## Cost-control constraints

The cluster is intentionally minimized. These constraints must be preserved:

- Node type: `e2-medium`, single node, `pd-standard` disk
- No `LoadBalancer` Services — use `ClusterIP` + `kubectl port-forward` for testing
- No PersistentVolumeClaims, Cloud NAT, or regional clusters

## Self-hosted GHA runners

`mlabs-runner/` contains the Dockerfile and entrypoint for running GitHub Actions runners.

**Build:** triggered on push to `main`. Uses QEMU + buildx for a multi-arch manifest (`linux/amd64`, `linux/arm64`). Image: `ghcr.io/miramar-labs-org/mlabs-runner`.

**Launch:** `./scripts/gha/launch-runner.sh` — fetches token via `GITHUB_ORG_ADMIN_PAT`. Idempotent.

**Network:** containers run with `--network=host` so `.local` mDNS names (`spark-79b7.local`, `orin.local`, `msi.local`) resolve correctly.

Local env vars required: `GITHUB_ORG_GHCR_PAT` (`read:packages`), `GITHUB_ORG_ADMIN_PAT` (`admin:org`, `repo`).

To bump the runner version, update `RUNNER_VERSION` in `mlabs-runner/Dockerfile`.

## DGX local services

Seven systemd user services start on boot (via linger) — managed via `dgx/systemd/`:

| Service | Port | Purpose |
|---|---|---|
| `minikube` | — | Starts/stops minikube; other services depend on it |
| `dashboard` | `8001` | `kubectl proxy --context minikube` |
| `jupyterlab` | `8888` | JupyterLab in the pyJLab Python environment (see `dgx/jupyterlab/`) |
| `mlflow-portfwd` | `5000` | `kubectl port-forward svc/mlflow-tracking` |
| `kubeflow-portfwd` | `8080` | `kubectl port-forward svc/ml-pipeline-ui` |
| `kfp-api-portfwd` | `8890` | `kubectl port-forward svc/ml-pipeline:8888` (KFP REST API) |
| `nemo-portfwd` | `8082` | `kubectl port-forward svc/ingress-nginx-controller:80` (NeMo/NIM/Data Store) |

**Minikube** is managed exclusively via GHA workflows. Runner container mounts `~/.minikube` and `~/.kube` from the DGX host so cluster state persists. The shared SSH store (`~/shared/ssh`) is also mounted, enabling workflows to SSH back to the DGX host as the local user (used by e.g. **Open in JupyterLab**).

**DGX workload stack** (deployment order): Minikube Install → NeMo Deploy → MLflow Deploy → NIM Deploy (or Ollama Deploy)

**NeMo Microservices** (`nemo-microservices` namespace) — exposes `nemo.test` and `nim.test` via ingress. Requires `NVIDIA_API_KEY` secret.

**NIM** — default: `nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark`. See `dgx/minikube/nim/NIM.md` for catalog. Available DGX Spark NIMs: https://docs.nvidia.com/nim/large-language-models/latest/supported-models.html

**Ollama** — runs as a systemd service on the DGX host (not in minikube). **NIM and Ollama share the 128 GB unified memory pool** — ~28 GB reserved for the platform, leaving **~100 GB for AI models**. No single deployed model may exceed this budget. See `dgx/ollama/README.md` for model catalog. Browse available models: https://ollama.com/library

**MLflow** (`mlflow-system` namespace) — port-forward binds to `0.0.0.0`; all other services bind to `127.0.0.1`.

**Kubeflow Pipelines** (`kubeflow` namespace) — independent of NeMo/MLflow; can deploy on a fresh minikube cluster.

**DGX inotify limits** — the default `fs.inotify.max_user_instances=128` is too low for minikube. Pods like `nvidia-device-plugin` and `volcano-scheduler` will `CrashLoopBackOff` with "too many open files" when the limit is exhausted. Current values set in `/etc/sysctl.d/99-sysctl.conf`: `max_user_instances=1024`, `max_user_watches=1048576`. To diagnose: `docker exec minikube bash -c 'cat /proc/sys/fs/inotify/max_user_instances; find /proc/*/fd -lname "anon_inode:inotify" 2>/dev/null | wc -l'`.

