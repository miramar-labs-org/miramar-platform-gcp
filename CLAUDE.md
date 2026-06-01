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
agx/               # AGX Orin host config and local tooling (mirrors dgx/)
  minikube/        # NeMo hosts file and AGX-specific configs
  ollama/          # Ollama deploy/undeploy scripts (no NIM conflict check — NIM not available on AGX)
wsl2/              # WSL2 host config and bootstrap scripts
  README.md           # Operator quickstart for WSL2 provisioning
  TECHNICAL.md        # Source of truth for template builds, lifecycle, on-demand SSH, and troubleshooting
win/               # Windows SSH tunnel profiles (Bitvise)
  README.md           # How to import and use the tunnel profiles
  dgx.tlp            # Bitvise profile: DGX Spark tunnels (ports 8001/8080/8082/8888/5000/8890/11434)
  agx.tlp            # Bitvise profile: AGX Orin tunnels (+1 offset ports)

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
| `dgx/systemd/install.sh` / `uninstall.sh` | Install or remove the seven systemd user services (used on both DGX and AGX) |
| `wsl2/bootstrap.sh` | One-time setup for a fresh WSL2 template base. Run inside the clean template before exporting. |
| `wsl2/rebuild-template.ps1` | Rebuild the configured template tarball. Params: `-SmbPassword` (required). Run after changing `bootstrap.sh` or rotating the Samba password. |
| `wsl2/firstboot.sh` | One-shot provisioning inside a new distro via `wsl -d NAME --user root -- bash`. Sets hostname, sshd port, calls `setup-shared-ssh.sh`. |
| `wsl2/setup-shared-ssh.sh` | Mounts `//DGX/shared` and symlinks `~/.ssh/` to shared store. All machines share Spark's SSH identity. Idempotent. |
| `wsl2/probe-ssh-ports.ps1` | Find a safe sshd port before provisioning. Usage: `.\probe-ssh-ports.ps1 -Distro dev -StartPort 2222 -EndPort 2299` |

GCP zsh scripts require `gcloud` on `$PATH` with an active authenticated session. `create-miramar-platform.zsh` additionally requires `kubectl`.

Run order for a fresh environment: `bootstrap-miramar-platform.zsh` → set GitHub secrets → run **GCP Platform Create** workflow.

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
| GCP Platform Create | `gcp-platform-create.yaml` | `terraform apply` (GKE + AR) then K8s namespaces + RBAC |
| GCP Platform Destroy | `gcp-platform-destroy.yaml` | `terraform destroy`, gcloud fallback, optionally delete project |
| GKE Expand | `gke-expand.yaml` | Snapshot pool state to GCS, scale up node count |
| GKE Restore | `gke-restore.yaml` | Read saved state from GCS, restore node count |
| GKE Expand GPU | `gke-expand-gpu.yaml` | Add transient GPU node pool via `terraform-gpu/` |
| GKE Restore GPU | `gke-restore-gpu.yaml` | Remove GPU node pool via `terraform destroy` in `terraform-gpu/` |
| Find GPU Capacity | `find-gpu-capacity.yaml` | Probe GPU availability; top 5 cheapest with [USE NOW] / [REQUEST QUOTA FIRST] |
| Minikube Install | `install-minikube.yaml` | Install minikube and start cluster on target machine; update `<RUNNER>_MINIKUBE_KUBECONFIG` secret; writes `{MACHINE}_MINIKUBE_ACTIVE` org var. Inputs: `runner` (dgx/agx) |
| Minikube Uninstall | `uninstall-minikube.yaml` | Delete cluster, purge state, remove binary; clears `{MACHINE}_MINIKUBE_ACTIVE` org var. Inputs: `runner` |
| Minikube Toggle | `toggle-minikube.yaml` | `minikube pause` / `unpause`. Inputs: `action`, `runner` (dgx/agx/wsl2) |
| NeMo Deploy | `deploy-nemo.yaml` | Install NeMo + Volcano via Helm; auto-commits hosts file + doc updates (DGX only); writes `{MACHINE}_NEMO_ACTIVE` org var. Inputs: `runner`, `nemo_version` |
| NeMo Undeploy | `undeploy-nemo.yaml` | Uninstall NeMo + Volcano; deletes postgres PVCs first to prevent password drift; clears `{MACHINE}_NEMO_ACTIVE` org var. Inputs: `runner` |
| NIM Deploy | `deploy-nim.yaml` | Deploy NIM via NeMo API; swaps any different running NIM first; rollback on failure; writes `CURRENT_NIM_MODEL[_AGX]` repo var. Inputs: `runner` |
| NIM Undeploy | `undeploy-nim.yaml` | Undeploy NIM via NeMo API; 404 is a no-op; clears `CURRENT_NIM_MODEL[_AGX]`. Inputs: `runner` |
| Qdrant Deploy | `deploy-qdrant.yaml` | Deploy Qdrant vector database into minikube `qdrant-system` namespace; restarts `qdrant-portfwd` on host; writes `{MACHINE}_QDRANT_ACTIVE` org var. Inputs: `runner` (dgx/agx) |
| Qdrant Undeploy | `undeploy-qdrant.yaml` | Remove Qdrant and delete namespace; clears `{MACHINE}_QDRANT_ACTIVE` org var. Inputs: `runner` |
| MLflow Deploy | `deploy-mlflow.yaml` | Deploy MLflow + MinIO into mlflow-system; writes `{MACHINE}_MLFLOW_ACTIVE` org var. Inputs: `runner` |
| MLflow Undeploy | `undeploy-mlflow.yaml` | Remove MLflow, MinIO, and mlflow-system namespace; clears `{MACHINE}_MLFLOW_ACTIVE` org var. Inputs: `runner` |
| Build KFP arm64 Images | `build-kfp-arm64.yaml` | Build all 13 KFP arm64 images (11 KFP components + 2 MLMD/Bazel) on DGX. Optional `component` input to rebuild a single image. ~45-60 min for MLMD on first run. Images are reusable on AGX (both linux/arm64). |
| Kubeflow Deploy | `deploy-kubeflow.yaml` | Deploy KFP standalone; patches all 13 deployments with native arm64 images; writes `{MACHINE}_KFP_ACTIVE` org var. Prerequisite: Build KFP arm64 Images. Inputs: `runner` |
| Create Project | `create-project.yaml` | Create a new repo under miramar-labs-org pre-wired for the platform. Four types: `default` (generic notebook + platform endpoint reference, new default), `kfp` (KFP v2 pipeline stub + deploy/undeploy workflows), `kfp-finetune` (KFP v2 fine-tuning pipeline — 7 named steps: prepare_data → train → merge_adapter → quantize → evaluate → push_to_gcs → deploy; teal badge; topic tag `miramar-kfp-finetune`), `nemo` (NeMo training job + deploy/undeploy workflows). Defaults to public so the project appears in the dashboard. Tags repo with `miramar-project` + `miramar-<type>`. `host` input (dgx/agx) sets which machine clones the repo and writes `PROJECT_HOST`. Also opens a draft blog post PR to `miramar-labs-org/miramar-labs-org.github.io`. |
| Delete Project | `delete-project.yaml` | Permanently delete a platform repo. Verifies repo exists first (fails fast with clear error if not). Double-entry confirmation guard. Cleans up blog draft PR/branch, local clone on host, and JupyterLab kernel. Triggers dashboard refresh on completion. Requires `delete_repo` scope on `GITHUB_ORG_ADMIN_PAT`. |
| Deploy Platform Dashboard | `deploy-dashboard.yaml` | Build and deploy the GitHub Pages project dashboard. Three status bars: DGX Spark, AGX Orin (NeMo/KFP/Ollama/NIM model+VRAM/Minikube/MLflow), and GCP (GKE cluster link, Zone, Node type, CPU pool node count, GPU pool badge, State bucket, GAR link). Service columns show green/red active-state badges driven by org-level `{MACHINE}_{SERVICE}_ACTIVE` variables. Header includes a + New Project button that opens a form modal and dispatches `create-project.yaml`. Project table includes Host column, JupyterLab links, and a 🗑 delete button per row — clicking opens a confirmation modal that fires `delete-project.yaml` via the GitHub API using `DASHBOARD_DISPATCH_TOKEN` (fine-grained PAT: Actions write on `miramar-platform-gcp` only; baked into HTML at generation time, no browser input required). Runs hourly + on `workflow_run` completion of any state-writing workflow. URL: https://miramar-labs-org.github.io/miramar-platform-gcp/ |
| List Blog Posts | `list-blog-posts.yaml` | List all live posts and open draft PRs in `miramar-labs-org/miramar-labs-org.github.io`. Run before Delete Blog Post to get the exact filename. |
| Delete Blog Post | `delete-blog-post.yaml` | Delete a post from `miramar-labs-org/miramar-labs-org.github.io` by filename; closes any open draft PR and removes the draft branch. GitHub Pages rebuilds in ~60s. |
| Kubeflow Undeploy | `undeploy-kubeflow.yaml` | Remove KFP and cluster-scoped resources; clears `{MACHINE}_KFP_ACTIVE` org var. Inputs: `runner` |
| Ollama Deploy | `deploy-ollama.yaml` | Auto-undeploy existing Ollama model, then pull + load new one; rollback on failure; writes `CURRENT_OLLAMA_MODEL[_AGX]` repo var and `{MACHINE}_OLLAMA_ACTIVE` org var. Inputs: `runner` (dgx/agx) |
| Ollama Undeploy | `undeploy-ollama.yaml` | Unload Ollama model from GPU memory; auto-detects if blank; clears `CURRENT_OLLAMA_MODEL[_AGX]` and `{MACHINE}_OLLAMA_ACTIVE` org var. Inputs: `runner` |
| Ollama Update | `update-ollama.yaml` | Install/upgrade Ollama on target host; writes `OLLAMA_VERSION` repo var. Inputs: `runner` (dgx/agx/wsl2) |
| Setup Shared SSH Store | `setup-shared-ssh.yaml` | One-time: wire DGX + Orin shared SSH store |
| WSL2 Provision | `provision-wsl2.yaml` | Import distro, run firstboot, add to WSL2_DISTROS |
| WSL2 Verify SSH Topology | `verify-ssh-topology.yaml` | Test all SSH paths for active distros in WSL2_DISTROS |
| WSL2 Unprovision | `unprovision-wsl2.yaml` | Unregister distro, remove from WSL2_DISTROS |
| Build MLABS Runner | `build-mlabs-runner.yml` | Build + push multi-arch (`linux/amd64`, `linux/arm64`) mlabs-runner image to GHCR. Triggered on push to `main` when `mlabs-runner/` changes; also manually dispatchable with optional `runner_version` input. |
| Repo Code Quality | `repo-quality-manual.yaml` | Run formatters/linters in check mode (or write mode with `fix_mode=true`). Manually dispatchable. |

**Platform state repo variables** (NIM/Ollama current model + VRAM, read by dashboard):

| Variable | Set by | Cleared by | Default |
|---|---|---|---|
| `CURRENT_NIM_MODEL` | NIM Deploy (dgx) | NIM Undeploy, NIM Deploy rollback | `none` |
| `CURRENT_OLLAMA_MODEL` | Ollama Deploy (dgx) | Ollama Undeploy, Ollama Deploy rollback | `none` |
| `CURRENT_NIM_VRAM_GB` | NIM Deploy (dgx) | NIM Undeploy, NIM Deploy rollback | `0` |
| `CURRENT_OLLAMA_VRAM_GB` | Ollama Deploy (dgx) | Ollama Undeploy, Ollama Deploy rollback | `0` |
| `CURRENT_NIM_MODEL_AGX` | NIM Deploy (agx) | NIM Undeploy (agx), rollback | `none` |
| `CURRENT_OLLAMA_MODEL_AGX` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback | `none` |
| `CURRENT_NIM_VRAM_GB_AGX` | NIM Deploy (agx) | NIM Undeploy (agx), rollback | `0` |
| `CURRENT_OLLAMA_VRAM_GB_AGX` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback | `0` |

**Active state org variables** (drive the green/red dashboard badges; seed with `gh api` on fresh install):

| Variable | Set to `true` by | Set to `false` by |
|---|---|---|
| `DGX_MINIKUBE_ACTIVE` | Minikube Install (dgx) | Minikube Uninstall (dgx) |
| `AGX_MINIKUBE_ACTIVE` | Minikube Install (agx) | Minikube Uninstall (agx) |
| `DGX_NEMO_ACTIVE` | NeMo Deploy (dgx) | NeMo Undeploy (dgx) |
| `AGX_NEMO_ACTIVE` | NeMo Deploy (agx) | NeMo Undeploy (agx) |
| `DGX_MLFLOW_ACTIVE` | MLflow Deploy (dgx) | MLflow Undeploy (dgx) |
| `AGX_MLFLOW_ACTIVE` | MLflow Deploy (agx) | MLflow Undeploy (agx) |
| `DGX_QDRANT_ACTIVE` | Qdrant Deploy (dgx) | Qdrant Undeploy (dgx) |
| `AGX_QDRANT_ACTIVE` | Qdrant Deploy (agx) | Qdrant Undeploy (agx) |
| `DGX_KFP_ACTIVE` | Kubeflow Deploy (dgx) | Kubeflow Undeploy (dgx) |
| `AGX_KFP_ACTIVE` | Kubeflow Deploy (agx) | Kubeflow Undeploy (agx) |
| `DGX_OLLAMA_ACTIVE` | Ollama Deploy (dgx) | Ollama Undeploy (dgx), rollback |
| `AGX_OLLAMA_ACTIVE` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback |
| `GKE_GPU_POOL_ACTIVE` | GKE Expand GPU | GKE Restore GPU |

**GCP pool org variables** (drive the CPU/GPU pool badges on the dashboard):

| Variable | Set by | Cleared by | Default |
|---|---|---|---|
| `GKE_NODE_COUNT` | GKE Expand (value: target node count) | GKE Restore (resets to `1`) | `1` |
| `GKE_GPU_POOL_ACTIVE` | GKE Expand GPU | GKE Restore GPU | `false` |
| `GKE_GPU_TYPE` | GKE Expand GPU (value: accelerator type, e.g. `nvidia-l4`) | GKE Restore GPU | `none` |

**Org-level variables required for AGX:**

| Variable | Value | Notes |
|---|---|---|
| `AGX_HOST_IP` | `<orin IP>` | Parallel to `DGX_HOST_IP` |
| `AGX_HOST_USER` | `aaron` | Parallel to `DGX_HOST_USER` |
| `AGX_VRAM_USEABLE` | `40` | 64 GB total - 24 GB system |

**Org secret used for all SSH:** `HOST_SSH_KEY` — all machines share Spark's SSH identity; replaces the old per-machine `DGX_HOST_SSH_KEY` / `AGX_HOST_SSH_KEY` secrets.

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

## Local AI stack (DGX + AGX)

Both DGX Spark and AGX Orin run the identical seven systemd user services on boot (via linger). All platform workflows accept a `runner` input (`dgx` or `agx`) to target the appropriate machine. See `dgx/systemd/` and `agx/systemd/`.

| Service | Host port | Purpose |
|---|---|---|
| `minikube` | — | Starts/stops minikube; other services depend on it |
| `dashboard` | `8001` | `kubectl proxy --context minikube` |
| `jupyterlab` | `8888` | JupyterLab in the pyJLab Python environment |
| `mlflow-portfwd` | `5000` | `kubectl port-forward svc/mlflow-tracking` |
| `kubeflow-portfwd` | `8080` | `kubectl port-forward svc/ml-pipeline-ui` |
| `kfp-api-portfwd` | `8890` | `kubectl port-forward svc/ml-pipeline:8888` (KFP REST API) |
| `nemo-portfwd` | `8082` | `kubectl port-forward svc/ingress-nginx-controller:80` (NeMo/NIM/Data Store) |
| `qdrant-portfwd` | `6333/6334` | `kubectl port-forward svc/qdrant 6333:6333 6334:6334` (REST + gRPC) |

**SSH tunnels** — DGX and AGX use offset local ports so both tunnels can run simultaneously from the laptop:

| Service | DGX local port | AGX local port |
|---|---|---|
| K8s dashboard | `8001` | `8002` |
| JupyterLab | `8888` | `8887` |
| MLflow | `5000` | `5001` |
| KFP UI | `8080` | `8081` |
| NeMo / NIM | `8082` | `8083` |
| KFP API | `8890` | `8891` |
| Ollama | `11434` | `11435` |
| Qdrant REST | `6333` | `6335` |
| Qdrant gRPC | `6334` | `6336` |

```sh
# DGX Spark (spark-79b7.local)
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 \
    -L 8080:localhost:8080 -L 8082:localhost:8082 -L 8890:localhost:8890 \
    -L 11434:localhost:11434 -L 6333:localhost:6333 -L 6334:localhost:6334 \
    aaron@spark-79b7.local

# AGX Orin (orin.local)
ssh -L 8002:localhost:8001 -L 8887:localhost:8888 -L 5001:localhost:5000 \
    -L 8081:localhost:8080 -L 8083:localhost:8082 -L 8891:localhost:8890 \
    -L 11435:localhost:11434 -L 6335:localhost:6333 -L 6336:localhost:6334 \
    aaron@orin.local
```

**Minikube** is managed exclusively via GHA workflows. Runner container mounts `~/.minikube` and `~/.kube` from the host so cluster state persists.

**Workload stack** (deployment order):
- DGX: Minikube Install → NeMo Deploy → MLflow Deploy → Qdrant Deploy → Kubeflow Deploy → NIM Deploy (or Ollama Deploy)
- AGX: Minikube Install → NeMo Deploy → MLflow Deploy → Qdrant Deploy → Kubeflow Deploy → Ollama Deploy

**NeMo Microservices** (`nemo-microservices` namespace) — exposes `nemo.test` and `nim.test` via ingress. Requires `NVIDIA_API_KEY` secret.

**NIM** — DGX only. Default: `nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark` (Blackwell-optimized). Not available on AGX — all NIM LLM containers on NGC are `linux/amd64`; no `linux/arm64` images exist. See `dgx/minikube/nim/NIM.md` for catalog.

**Ollama** — runs as a systemd service on the host (not in minikube).
- DGX: ~28 GB reserved for platform, **~100 GB for models** (`DGX_VRAM_USEABLE`)
- AGX: ~24 GB reserved for platform, **~40 GB for models** (`AGX_VRAM_USEABLE`)

**MLflow** (`mlflow-system` namespace) — `MLFLOW_TRACKING_URI=http://host.docker.internal:5000` works on both machines (resolves to the local host from inside the runner container).

**Kubeflow Pipelines** (`kubeflow` namespace) — independent of NeMo/MLflow; can deploy on a fresh minikube cluster.

**inotify limits (DGX + AGX)** — the default `fs.inotify.max_user_instances=128` is too low for minikube. Pods like `nvidia-device-plugin` and `volcano-scheduler` will `CrashLoopBackOff` with "too many open files" when the limit is exhausted. Applied on both machines: `/etc/sysctl.d/99-sysctl.conf` with `max_user_instances=1024`, `max_user_watches=1048576`. To diagnose: `docker exec minikube bash -c 'cat /proc/sys/fs/inotify/max_user_instances; find /proc/*/fd -lname "anon_inode:inotify" 2>/dev/null | wc -l'`.

