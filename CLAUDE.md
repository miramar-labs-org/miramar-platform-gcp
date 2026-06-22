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
  minikube/        # legacy minikube manifests (retained for reference); k3s manifests in dgx/k3s/
  ollama/          # Ollama deploy/undeploy scripts and model catalog
  systemd/         # Systemd user service unit files + install/uninstall scripts
agx/               # AGX Orin host config and local tooling (mirrors dgx/)
  minikube/        # NeMo hosts file and AGX-specific configs
  ollama/          # Ollama deploy/undeploy scripts (NIM conflict check omitted — verify arm64 support per model)
wsl2/              # WSL2 host config and bootstrap scripts
  README.md           # Operator quickstart for WSL2 provisioning
  TECHNICAL.md        # Source of truth for template builds, lifecycle, on-demand SSH, and troubleshooting
win/               # Windows SSH tunnel profiles (Bitvise)
  README.md           # How to import and use the tunnel profiles
  dgx.tlp            # Bitvise profile: DGX Spark tunnels (ports 8001/8080/8082/8888/5000/8890/11434/6333/6334)
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

| Script                                            | Purpose                                                                                                                                       |
| ------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `gcp/bootstrap-miramar-platform.zsh`              | One-time local setup — project creation, billing, APIs, WIF pool/provider, service accounts, IAM                                              |
| `gcp/create-miramar-platform.zsh`                 | K8s-only setup — AR IAM bindings, namespaces, resource quotas, RBAC                                                                           |
| `scripts/gha/sync-github-tf-vars.sh`              | Sync `gcp/terraform/terraform.tfvars` → GitHub org variables. Never edit GitHub vars directly — edit tfvars and re-sync.                      |
| `scripts/gha/launch-runner.sh` / `stop-runner.sh` | Start / gracefully stop+deregister the mlabs-runner container. Idempotent.                                                                    |
| `scripts/gha/flush-queues.sh`                     | Cancel all in-progress, queued, and waiting workflow runs                                                                                     |
| `dgx/systemd/install.sh` / `uninstall.sh`         | Install or remove the nine systemd user services (used on both DGX and AGX)                                                                   |
| `wsl2/bootstrap.sh`                               | One-time setup for a fresh WSL2 template base. Run inside the clean template before exporting.                                                |
| `wsl2/rebuild-template.ps1`                       | Rebuild the configured template tarball. Params: `-SmbPassword` (required). Run after changing `bootstrap.sh` or rotating the Samba password. |
| `wsl2/firstboot.sh`                               | One-shot provisioning inside a new distro via `wsl -d NAME --user root -- bash`. Sets hostname, sshd port, calls `setup-shared-ssh.sh`.       |
| `wsl2/setup-shared-ssh.sh`                        | Mounts `//DGX/shared` and symlinks `~/.ssh/` to shared store. All machines share Spark's SSH identity. Idempotent.                            |
| `wsl2/probe-ssh-ports.ps1`                        | Find a safe sshd port before provisioning. Usage: `.\probe-ssh-ports.ps1 -Distro dev -StartPort 2222 -EndPort 2299`                           |

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

`workflow_dispatch` workflows in `.github/workflows/` — full input/output details in `docs/workflows.md`:

| Workflow                     | File                                | Purpose                                                              |
| ---------------------------- | ----------------------------------- | -------------------------------------------------------------------- |
| GCP Platform Create          | `gcp-platform-create.yaml`          | `terraform apply` (GKE + AR), K8s namespaces + RBAC, Nsight Operator |
| GCP Platform Destroy         | `gcp-platform-destroy.yaml`         | `terraform destroy`, gcloud fallback, optionally delete project       |
| GKE Expand                   | `gke-expand.yaml`                   | Snapshot pool state to GCS, scale up node count                      |
| GKE Restore                  | `gke-restore.yaml`                  | Read saved state from GCS, restore node count                        |
| GKE Expand GPU               | `gke-expand-gpu.yaml`               | Add transient GPU node pool via `terraform-gpu/`                     |
| GKE Restore GPU              | `gke-restore-gpu.yaml`              | Remove GPU node pool via `terraform destroy` in `terraform-gpu/`     |
| Find GPU Capacity            | `find-gpu-capacity.yaml`            | Probe GPU availability; top 5 cheapest with [USE NOW] / [REQUEST QUOTA FIRST] |
| K3s Install                  | `install-k3s.yaml`                  | Install k3s + NVIDIA device plugin + nginx-ingress; sets `{MACHINE}_K3S_ACTIVE` |
| K3s Uninstall                | `uninstall-k3s.yaml`                | Run `k3s-uninstall.sh`, remove kubeconfig; clears `{MACHINE}_K3S_ACTIVE` |
| NeMo Deploy                  | `deploy-nemo.yaml`                  | Install NeMo + Volcano via Helm; sets `{MACHINE}_NEMO_ACTIVE`        |
| NeMo Undeploy                | `undeploy-nemo.yaml`                | Uninstall NeMo + Volcano; deletes postgres PVCs first                |
| NIM Deploy                   | `deploy-nim.yaml`                   | Deploy NIM via NeMo API; swaps existing; rollback on failure         |
| NIM Undeploy                 | `undeploy-nim.yaml`                 | Undeploy NIM; 404 is no-op; clears `CURRENT_NIM_MODEL`               |
| Qdrant Deploy                | `deploy-qdrant.yaml`                | Deploy Qdrant into k3s `qdrant-system`; sets `{MACHINE}_QDRANT_ACTIVE` |
| Qdrant Undeploy              | `undeploy-qdrant.yaml`              | Remove Qdrant namespace; clears `{MACHINE}_QDRANT_ACTIVE`            |
| Open WebUI Deploy            | `deploy-openwebui.yaml`             | Deploy Open WebUI on DGX/AGX/GKE; wires active serving backend      |
| Open WebUI Undeploy          | `undeploy-openwebui.yaml`           | Remove Open WebUI; stops portfwd; clears `{MACHINE}_OPENWEBUI_ACTIVE` |
| Nsight Operator Deploy       | `deploy-nsight-operator.yaml`       | Install Nsight Operator via Helm; sets `{MACHINE}_NSIGHT_OPERATOR_ACTIVE` |
| Nsight Operator Undeploy     | `undeploy-nsight-operator.yaml`     | Helm uninstall Nsight Operator; clears `{MACHINE}_NSIGHT_OPERATOR_ACTIVE` |
| Nsight Operator Deploy GKE   | `deploy-nsight-operator-gke.yaml`   | Install Nsight Operator on GKE; dynamic PVC; wsl2 runner             |
| Nsight Operator Undeploy GKE | `undeploy-nsight-operator-gke.yaml` | Helm uninstall Nsight Operator from GKE; clears `GKE_NSIGHT_OPERATOR_ACTIVE` |
| MLflow Deploy                | `deploy-mlflow.yaml`                | Deploy MLflow + MinIO into mlflow-system; sets `{MACHINE}_MLFLOW_ACTIVE` |
| MLflow Undeploy              | `undeploy-mlflow.yaml`              | Remove MLflow, MinIO, and mlflow-system namespace                    |
| Build KFP arm64 Images       | `build-kfp-arm64.yaml`              | Build 13 KFP arm64 images on DGX; optional single-component rebuild  |
| Kubeflow Deploy              | `deploy-kubeflow.yaml`              | Deploy KFP standalone; patch 13 deployments with arm64 images        |
| Kubeflow Undeploy            | `undeploy-kubeflow.yaml`            | Remove KFP and cluster-scoped resources; clears `{MACHINE}_KFP_ACTIVE` |
| Create Project               | `create-project.yaml`               | Create platform repo (10 types: default/kfp/ft-eval/nemo-ft-eval/serving-vllm/serving-nim/serving-trt-fp8/serving-trt-engine/kfp-rag/kfp-nemo-curator); opens blog draft PR |
| Delete Project               | `delete-project.yaml`               | Permanently delete a platform repo; double-entry confirmation guard  |
| Deploy Platform Dashboard    | `deploy-dashboard.yaml`             | Build + deploy GitHub Pages dashboard; runs hourly + on workflow_run |
| List Blog Posts              | `list-blog-posts.yaml`              | List live posts and open draft PRs in the blog repo                  |
| Delete Blog Post             | `delete-blog-post.yaml`             | Delete a blog post by filename; close draft PR + branch              |
| Ollama Deploy                | `deploy-ollama.yaml`                | Pull + load Ollama model; rollback on failure; sets `{MACHINE}_OLLAMA_ACTIVE` |
| Ollama Undeploy              | `undeploy-ollama.yaml`              | Unload Ollama from GPU; clears `{MACHINE}_OLLAMA_ACTIVE`             |
| Ollama Update                | `update-ollama.yaml`                | Install/upgrade Ollama on target host; writes `OLLAMA_VERSION`       |
| Setup Shared SSH Store       | `setup-shared-ssh.yaml`             | One-time: wire DGX + Orin shared SSH store                           |
| WSL2 Provision               | `provision-wsl2.yaml`               | Import distro, run firstboot, add to WSL2_DISTROS                    |
| WSL2 Verify SSH Topology     | `verify-ssh-topology.yaml`          | Test all SSH paths for active distros in WSL2_DISTROS                |
| WSL2 Unprovision             | `unprovision-wsl2.yaml`             | Unregister distro, remove from WSL2_DISTROS                          |
| Build MLABS Runner           | `build-mlabs-runner.yml`            | Build + push multi-arch mlabs-runner image to GHCR                   |
| Repo Code Quality            | `repo-quality-manual.yaml`          | Run formatters/linters in check mode (or `fix_mode=true`)            |

**Platform state repo variables** (NIM/Ollama current model + VRAM, read by dashboard):

| Variable                     | Set by              | Cleared by                              | Default |
| ---------------------------- | ------------------- | --------------------------------------- | ------- |
| `CURRENT_NIM_MODEL`          | NIM Deploy (dgx)    | NIM Undeploy, NIM Deploy rollback       | `none`  |
| `CURRENT_OLLAMA_MODEL`       | Ollama Deploy (dgx) | Ollama Undeploy, Ollama Deploy rollback, serving-xxx deploy (dgx job) | `none`  |
| `CURRENT_NIM_VRAM_GB`        | NIM Deploy (dgx)    | NIM Undeploy, NIM Deploy rollback       | `0`     |
| `CURRENT_OLLAMA_VRAM_GB`     | Ollama Deploy (dgx) | Ollama Undeploy, Ollama Deploy rollback, serving-xxx deploy (dgx job) | `0`     |
| `CURRENT_NIM_MODEL_AGX`      | NIM Deploy (agx)    | NIM Undeploy (agx), rollback            | `none`  |
| `CURRENT_OLLAMA_MODEL_AGX`   | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback, serving-xxx deploy (agx job) | `none`  |
| `CURRENT_NIM_VRAM_GB_AGX`    | NIM Deploy (agx)    | NIM Undeploy (agx), rollback            | `0`     |
| `CURRENT_OLLAMA_VRAM_GB_AGX` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback, serving-xxx deploy (agx job) | `0`     |

**Active state org variables** (drive the green/red dashboard badges; seed with `gh api` on fresh install):

| Variable                     | Set to `true` by                                | Set to `false` by               |
| ---------------------------- | ----------------------------------------------- | ------------------------------- |
| `DGX_K3S_ACTIVE`             | K3s Install (dgx)                               | K3s Uninstall (dgx)             |
| `AGX_K3S_ACTIVE`             | K3s Install (agx)                               | K3s Uninstall (agx)             |
| `DGX_NEMO_ACTIVE`            | NeMo Deploy (dgx)                               | NeMo Undeploy (dgx)             |
| `AGX_NEMO_ACTIVE`            | NeMo Deploy (agx)                               | NeMo Undeploy (agx)             |
| `DGX_MLFLOW_ACTIVE`          | MLflow Deploy (dgx)                             | MLflow Undeploy (dgx)           |
| `AGX_MLFLOW_ACTIVE`          | MLflow Deploy (agx)                             | MLflow Undeploy (agx)           |
| `DGX_QDRANT_ACTIVE`          | Qdrant Deploy (dgx)                             | Qdrant Undeploy (dgx)           |
| `AGX_QDRANT_ACTIVE`          | Qdrant Deploy (agx)                             | Qdrant Undeploy (agx)           |
| `DGX_KFP_ACTIVE`             | Kubeflow Deploy (dgx)                           | Kubeflow Undeploy (dgx)         |
| `AGX_KFP_ACTIVE`             | Kubeflow Deploy (agx)                           | Kubeflow Undeploy (agx)         |
| `DGX_NSIGHT_OPERATOR_ACTIVE` | Nsight Operator Deploy (dgx)                    | Nsight Operator Undeploy (dgx)  |
| `AGX_NSIGHT_OPERATOR_ACTIVE` | Nsight Operator Deploy (agx)                    | Nsight Operator Undeploy (agx)  |
| `GKE_NSIGHT_OPERATOR_ACTIVE` | Nsight Operator Deploy GKE; GCP Platform Create | Nsight Operator Undeploy GKE    |
| `DGX_OLLAMA_ACTIVE`          | Ollama Deploy (dgx)                             | Ollama Undeploy (dgx), rollback, serving-xxx deploy (dgx job) |
| `AGX_OLLAMA_ACTIVE`          | Ollama Deploy (agx)                             | Ollama Undeploy (agx), rollback, serving-xxx deploy (agx job) |
| `DGX_OPENWEBUI_ACTIVE`       | Open WebUI Deploy (dgx)                         | Open WebUI Undeploy (dgx)       |
| `AGX_OPENWEBUI_ACTIVE`       | Open WebUI Deploy (agx)                         | Open WebUI Undeploy (agx)       |
| `GKE_OPENWEBUI_ACTIVE`       | Open WebUI Deploy (gke)                         | Open WebUI Undeploy (gke)       |
| `GKE_GPU_POOL_ACTIVE`        | GKE Expand GPU                                  | GKE Restore GPU                 |

**Open WebUI backend URL org variables** (set automatically by serving project deploy/undeploy workflows):

| Variable               | Set by                        | Cleared by                             | Default |
| ---------------------- | ----------------------------- | -------------------------------------- | ------- |
| `DGX_OPENWEBUI_API_URL` | serving-xxx deploy (dgx job) | serving-xxx undeploy (dgx job) → `""` | `""`    |
| `AGX_OPENWEBUI_API_URL` | serving-xxx deploy (agx job) | serving-xxx undeploy (agx job) → `""` | `""`    |
| `GKE_OPENWEBUI_API_URL` | serving-xxx deploy (gke job) | serving-xxx undeploy (gke job) → `""` | `""`    |

When a serving project deploys, it sets `{MACHINE}_OPENWEBUI_API_URL` to the in-cluster backend URL and (if `{MACHINE}_OPENWEBUI_ACTIVE=true`) triggers `deploy-openwebui.yaml` to repoint the running UI. When a serving project undeploys, it clears the URL to `""` and triggers a redeploy, reverting Open WebUI to Ollama-only.

**GCP pool org variables** (drive the CPU/GPU pool badges on the dashboard):

| Variable              | Set by                                                     | Cleared by                                        | Default |
| --------------------- | ---------------------------------------------------------- | ------------------------------------------------- | ------- |
| `GKE_CLUSTER_ACTIVE`  | GCP Platform Create                                        | GCP Platform Destroy (resets to `false`)          | `false` |
| `GKE_NODE_COUNT`      | GKE Expand (value: target node count)                      | GKE Restore (resets to `1`), GCP Platform Destroy | `1`     |
| `GKE_GPU_POOL_ACTIVE` | GKE Expand GPU                                             | GKE Restore GPU, GCP Platform Destroy             | `false` |
| `GKE_GPU_TYPE`        | GKE Expand GPU (value: accelerator type, e.g. `nvidia-l4`) | GKE Restore GPU, GCP Platform Destroy             | `none`  |

**Org-level variables required for AGX:**

| Variable           | Value       | Notes                       |
| ------------------ | ----------- | --------------------------- |
| `AGX_HOST_IP`      | `<orin IP>` | Parallel to `DGX_HOST_IP`   |
| `AGX_HOST_USER`    | `aaron`     | Parallel to `DGX_HOST_USER` |
| `AGX_VRAM_USEABLE` | `40`        | 64 GB total - 24 GB system  |

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

Local env vars required: `GITHUB_ORG_GHCR_PAT` (`read:packages`), `GITHUB_ORG_ADMIN_PAT` (`admin:org`, `repo`). Both are also registered as org-level GitHub Actions secrets (`MIRAMAR_ORG_GHCR_PAT`, `MIRAMAR_ORG_ADMIN_PAT`) for use by hosted runners.

To bump the runner version, update `RUNNER_VERSION` in `mlabs-runner/Dockerfile`.

## Local AI stack (DGX + AGX)

Both DGX Spark and AGX Orin run the identical nine systemd user services on boot (via linger). All platform workflows accept a `runner` input (`dgx` or `agx`) to target the appropriate machine. See `dgx/systemd/` and `agx/systemd/`.

| Service            | Host port   | Purpose                                                                      |
| ------------------ | ----------- | ---------------------------------------------------------------------------- |
| `dashboard`        | `8001`      | `kubectl proxy` for the Kubernetes dashboard                                 |
| `jupyterlab`       | `8888`      | JupyterLab in the pyJLab Python environment                                  |
| `mlflow-portfwd`   | `5000`      | `kubectl port-forward svc/mlflow-tracking`                                   |
| `kubeflow-portfwd` | `8080`      | `kubectl port-forward svc/ml-pipeline-ui`                                    |
| `kfp-api-portfwd`  | `8890`      | `kubectl port-forward svc/ml-pipeline:8888` (KFP REST API)                   |
| `nemo-portfwd`     | `8082`      | `kubectl port-forward svc/ingress-nginx-controller:80` (NeMo/NIM/Data Store) |
| `qdrant-portfwd`   | `6333/6334` | `kubectl port-forward svc/qdrant 6333:6333 6334:6334` (REST + gRPC)          |
| `nsight-portfwd`   | `8889`      | `kubectl port-forward svc/nsight-operator-ui:8888` (Nsight Operator UI)      |
| `openwebui-portfwd` | `8084`     | `kubectl port-forward svc/openwebui:8080` (Open WebUI chat over Ollama / vLLM) |

**SSH tunnels** — DGX and AGX use offset local ports so both tunnels can run simultaneously from the laptop:

| Service            | DGX local port | AGX local port |
| ------------------ | -------------- | -------------- |
| K8s dashboard      | `8001`         | `8002`         |
| JupyterLab         | `8888`         | `8887`         |
| MLflow             | `5000`         | `5001`         |
| KFP UI             | `8080`         | `8081`         |
| NeMo / NIM         | `8082`         | `8083`         |
| KFP API            | `8890`         | `8891`         |
| Ollama             | `11434`        | `11435`        |
| Qdrant REST        | `6333`         | `6335`         |
| Qdrant gRPC        | `6334`         | `6336`         |
| Nsight Operator UI | `8889`         | `8892`         |
| Open WebUI         | `8084`         | `8085`         |

```sh
# DGX Spark (spark-79b7.local)
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 \
    -L 8080:localhost:8080 -L 8082:localhost:8082 -L 8890:localhost:8890 \
    -L 11434:localhost:11434 -L 6333:localhost:6333 -L 6334:localhost:6334 \
    -L 8889:localhost:8889 \
    -L 8084:localhost:8084 \
    aaron@spark-79b7.local

# AGX Orin (orin.local)
ssh -L 8002:localhost:8001 -L 8887:localhost:8888 -L 5001:localhost:5000 \
    -L 8081:localhost:8080 -L 8083:localhost:8082 -L 8891:localhost:8890 \
    -L 11435:localhost:11434 -L 6335:localhost:6333 -L 6336:localhost:6334 \
    -L 8892:localhost:8889 \
    -L 8085:localhost:8084 \
    aaron@orin.local
```

**k3s** is managed exclusively via GHA workflows (K3s Install / Uninstall). Kubeconfig is written to `~/.kube/config` on the host and mounted into the runner container.

**Workload stack** (deployment order):
- DGX: K3s Install → NeMo Deploy → MLflow Deploy → Qdrant Deploy → Kubeflow Deploy → NIM Deploy (or Ollama Deploy)
- AGX: K3s Install → NeMo Deploy → MLflow Deploy → Qdrant Deploy → Kubeflow Deploy → Ollama Deploy

**NeMo Microservices** (`nemo-microservices` namespace) — exposes `nemo.test` and `nim.test` via ingress. Requires `NVIDIA_API_KEY` secret.

**NIM** — DGX default: `nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark` (Blackwell-optimized). AGX support: platform variables (`CURRENT_NIM_MODEL_AGX` etc.) are wired; whether a given NIM container image supports `linux/arm64` depends on the model — check NGC before deploying. See `dgx/minikube/nim/NIM.md` for catalog.

**Ollama** — runs as a systemd service on the host (not in k3s).
- DGX: ~28 GB reserved for platform, **~100 GB for models** (`DGX_VRAM_USEABLE`)
- AGX: ~24 GB reserved for platform, **~40 GB for models** (`AGX_VRAM_USEABLE`)

**MLflow** (`mlflow-system` namespace) — `MLFLOW_TRACKING_URI=http://host.docker.internal:5000` works on both machines (resolves to the local host from inside the runner container).

**Qdrant** (`qdrant-system` namespace) — REST API at `http://localhost:6333`, gRPC at `localhost:6334`. Web UI at `http://localhost:6333/dashboard`. `QDRANT_URL=http://host.docker.internal:6333` works from inside the runner container.

**Kubeflow Pipelines** (`kubeflow` namespace) — independent of NeMo/MLflow; can deploy on a fresh k3s cluster.

**inotify limits (DGX + AGX)** — the default `fs.inotify.max_user_instances=128` is too low for k3s. Pods like `nvidia-device-plugin` and `volcano-scheduler` will `CrashLoopBackOff` with "too many open files" when the limit is exhausted. Applied on both machines: `/etc/sysctl.d/99-sysctl.conf` with `max_user_instances=1024`, `max_user_watches=1048576`.
