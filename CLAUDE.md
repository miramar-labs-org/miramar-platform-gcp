# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure and CI/CD tooling for the Miramar platform on GCP. It provisions a single GCP project (`miramar-platform`) containing a shared GKE Standard cluster, Artifact Registry, Workload Identity Federation for keyless GitHub Actions auth, and supporting resources. It also contains Docker images and a launch script for self-hosted GitHub Actions runners.

## Platform topology

**Physical machines (self-hosted GHA runners):**
- **Windows laptop / WSL2** — Ubuntu 24.04, x86_64 (amd64), AMD CPU, NVIDIA RTX 4060 (sm_89). Runner label: `wsl2`.
- **NVIDIA DGX Spark 128GB** — DGX OS (Ubuntu), aarch64 (arm64), 20-core Arm CPU (10× Cortex-X925 + 10× Cortex-A725), GB10 Superchip Blackwell GPU (6144 CUDA cores, 5th-gen Tensor Cores). Runner label: `dgx`.
- **NVIDIA Jetson AGX Orin 64GB** — Ubuntu JetPack 6.x, aarch64 (arm64), 12-core Cortex-A78AE, Ampere GPU 2048 CUDA cores (sm_87), CUDA 12.6. Runner label: `agx`.

**GCP:**
- `miramar-platform` — single project hosting GKE Standard cluster (`miramar-shared-gke`), Artifact Registry (`apps`), WIF pool/provider, and deploy service accounts.
- WIF provides keyless GitHub Actions → GCP auth; no long-lived service account keys.

**CI/CD:**
- GitHub Actions workflows on both GitHub-hosted and the two self-hosted runners above.
- GHCR (`ghcr.io/miramar-labs-org`) hosts the `mlabs-runner` image and future app images.

## Directory layout

```
gcp/               # GCP provisioning scripts
  terraform/       # GKE cluster + node pool + Artifact Registry (Terraform)
  terraform-gpu/   # Transient GPU node pool (separate Terraform root module)
scripts/
  gcp/             # Utility GCP scripts
  gha/             # GHA runner launch script
  ubuntu/          # Host setup scripts
mlabs-runner/      # Docker image for self-hosted GHA runners
dgx/               # DGX Spark host config and local tooling
  minikube/        # GHA workflows for minikube lifecycle + NeMo deployment
  ollama/          # Ollama deploy/undeploy scripts and model catalog
  systemd/         # Systemd user service unit files + install/uninstall scripts
wsl2/              # WSL2 host config and bootstrap scripts
  bootstrap.sh     # One-time distro setup (run before template export)
  post-provision.ps1 # Windows-side SSH mesh setup (run by WSL2 Post-Provision workflow)
  post-bootstrap.md  # Manual fallback steps (automated via GHA workflows)
docs/              # Architecture and runbooks
  ssh-runbook.md   # Full SSH mesh topology and troubleshooting
.github/workflows/ # CI/CD workflows
```

## Key scripts

| Script | Purpose |
|---|---|
| `gcp/bootstrap-miramar-platform.zsh` | One-time local setup — project creation, billing, APIs, WIF pool/provider, service accounts, IAM bindings |
| `gcp/create-miramar-platform.zsh` | K8s-only setup — AR IAM bindings for deploy SAs, namespaces, resource quotas, RBAC. GCP resources are managed by Terraform. |
| `gcp/list-miramar-platform.zsh` | Enumerate live GCP resources in the project |
| `scripts/gha/sync-github-tf-vars.sh` | Sync `gcp/terraform/terraform.tfvars` → GitHub org variables. Run after editing tfvars. |
| `scripts/gha/launch-runner.sh` / `scripts/gha/stop-runner.sh` | Start / gracefully stop+deregister the mlabs-runner container. `launch-runner.sh` is idempotent — if the container is already running it prints status and exits 0. |
| `scripts/gha/flush-queues.sh` | Cancel all in-progress, queued, and waiting workflow runs |
| `scripts/ubuntu/install-gcloud.sh` | Install `gcloud` via apt on Ubuntu/Debian |
| `scripts/ubuntu/install-terraform.sh` | Install `terraform` via apt on Ubuntu/Debian |
| `scripts/ubuntu/install-gh.sh` | Install `gh` (GitHub CLI) via apt on Ubuntu/Debian |
| `scripts/ubuntu/install-ollama.sh` | Install or upgrade Ollama on the host (run as root); installs `zstd` prerequisite; skips if already at latest version. Deployed to DGX via SCP by the **Ollama Update** workflow. |
| `scripts/gcp/gke/find-gpu-capacity.sh` | Probe actual GPU capacity across all GPU types and zones in parallel. Default scope: all US regions (`us-*`). Pass a region to narrow (`us-central1`). Shows top 5 cheapest options split by [USE NOW] / [REQUEST QUOTA FIRST] with ready-to-use GKE Expand GPU settings. |
| `dgx/ollama/deploy_ollama.sh` | Run on DGX host via SSH to pull an Ollama model and load it into GPU memory. Fails if a NIM or another Ollama model is already using the 128 GB pool. Called by the **Ollama Deploy** workflow. |
| `dgx/ollama/undeploy_ollama.sh` | Run on DGX host via SSH to unload an Ollama model from GPU memory. Auto-detects the loaded model if no arg given. Called by the **Ollama Undeploy** workflow. |
| `dgx/systemd/install.sh` / `uninstall.sh` | Install or remove the four DGX systemd user services (minikube, dashboard proxy, JupyterLab, MLflow port-forward). |
| `wsl2/bootstrap.sh` | One-time setup for a fresh WSL2 distro — installs dev tools, Docker, Kubernetes tooling, pyenv, Miniforge, Go, Java, and configures SSH (sshd on port 2222, ed25519 key, mDNS, `~/.ssh/config` for lab hosts). Run inside the distro before exporting the template. |
| `wsl2/post-provision.ps1` | PowerShell script run on the Windows host by the **WSL2 Post-Provision** workflow. Params: `-Name` (distro), `-User`, `-Port` (default 2222). Handles `.wslconfig`, per-distro firewall rule (`WSL2 SSH <Port> Inbound`), sshd port inside the distro, WSL2 pubkey → `administrators_authorized_keys`, runner pubkey injection into WSL2 `authorized_keys`, and Windows SSH client config (`Host wsl2-<Name>` → `localhost:<Port>`). |

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

**`gcp/terraform-gpu/`** — manages the transient `gpu-pool` GPU node pool only. Separate state at `gs://miramar-platform-cluster-state/terraform/gpu-state/`. Used exclusively by the **GKE Expand GPU** / **GKE Restore GPU** workflows — regular expand/restore never touch it. Config in `gcp/terraform-gpu/gpu.tfvars`.

**Note:** the mlabs-runner Docker image has Terraform pre-installed via the Hashicorp apt repo. The `hashicorp/setup-terraform` GitHub Actions action is intentionally not used (it requires Node.js).

## Platform lifecycle workflows

Bootstrap is run **locally** (not via workflow) — requires an active gcloud session:

```sh
zsh ./gcp/bootstrap-miramar-platform.zsh 2>&1 | tee /tmp/bootstrap.log
```

Output includes `WIF_PROVIDER` (set as org-level secret) and `GCP_SERVICE_ACCOUNT` (set as repo-level secret on `miramar-platform-gcp`). All workflows use WIF from that point on.

Org-level variables are synced from `terraform.tfvars` via `sync-github-tf-vars.sh`:
`GCP_PROJECT_ID`, `GKE_CLUSTER_NAME`, `GKE_ZONE`, `GCP_REGION`, `GAR_REPO` — all workflows read these via `${{ vars.* }}`. `GKE_STATE_BUCKET` is set manually.

`workflow_dispatch` workflows in `.github/workflows/`:

| Workflow | File | Purpose |
|---|---|---|
| Miramar Platform Create | `miramar-platform-create.yaml` | `terraform apply` (GKE cluster + AR repo) then K8s namespaces + RBAC via `create-miramar-platform.zsh` |
| Miramar Platform Destroy | `miramar-platform-destroy.yaml` | `terraform destroy` (GKE + AR), gcloud fallback for pre-Terraform resources, delete state bucket, optionally delete project |
| GKE Expand | `gke-expand.yaml` | Snapshot node pool state to GCS, then `terraform apply -var=node_pool_count=N` |
| GKE Restore | `gke-restore.yaml` | Read saved state from GCS, then `terraform apply -var=node_pool_count=<saved>` |
| GKE Expand GPU | `gke-expand-gpu.yaml` | `terraform apply` in `gcp/terraform-gpu/` to add a GPU node pool; expands namespace quota |
| GKE Restore GPU | `gke-restore-gpu.yaml` | `terraform destroy` in `gcp/terraform-gpu/` to remove the GPU pool; restores namespace quota |
| Find GPU Capacity | `find-gpu-capacity.yaml` | Probes all GPU types and zones in parallel; shows top 5 cheapest options split by [USE NOW] vs [REQUEST QUOTA FIRST] with exact settings for GKE Expand GPU |
| Minikube Install | `install-minikube.yaml` | Install minikube on DGX host, start cluster, enable addons (ingress, dashboard, metrics-server), wait for ingress-nginx readiness, update `DGX_MINIKUBE_KUBECONFIG` secret |
| Minikube Uninstall | `uninstall-minikube.yaml` | Delete cluster, purge state, remove minikube binary from DGX host |
| Minikube Toggle | `toggle-minikube.yaml` | SSH to DGX host and run `minikube pause` / `minikube unpause`. Inputs: `action` (`pause` \| `resume`), `runner` (`dgx` \| `wsl2`, default: `dgx`) |
| NeMo Deploy | `deploy-nemo.yaml` | Install NeMo Microservices + Volcano via Helm on the DGX minikube cluster; triggers MLflow Deploy on success |
| NeMo Undeploy | `undeploy-nemo.yaml` | Uninstall NeMo + Volcano; deletes postgres PVCs before uninstall to prevent password drift on redeploy; input: `delete_namespace` (bool, default true) |
| NIM Deploy | `deploy-nim.yaml` | Deploy a NIM via the NeMo deployment API; swaps any different running NIM first. Inputs: `nim_name` (default: `nvidia-nemotron-nano-9b-v2-dgx-spark`), `nim_org` (default: `nvidia`), `image_tag` (default: `1.0.0-variant`) |
| NIM Undeploy | `undeploy-nim.yaml` | Undeploy a NIM via the NeMo deployment API; 404 is a no-op. Inputs: `nim_name`, `nim_org` |
| MLflow Deploy | `deploy-mlflow.yaml` | Deploy MLflow + MinIO into mlflow-system; integrates with NeMo postgres via pg_hba.conf trust bootstrap (no superuser password needed). Auto-triggered by NeMo Deploy. |
| MLflow Undeploy | `undeploy-mlflow.yaml` | Remove MLflow and MinIO; always deletes mlflow-system namespace |
| Ollama Deploy | `deploy-ollama.yaml` | SSH to DGX host and pull + load an Ollama model into GPU memory. Fails with an explicit error if a NIM or another Ollama model is already using the 128 GB pool. Input: `model` (default: `llama3.3:70b-instruct-q4_K_M`) |
| Ollama Undeploy | `undeploy-ollama.yaml` | SSH to DGX host and unload the active Ollama model from GPU memory. Auto-detects loaded model if `model` input is blank. Input: `model` (optional), `delete_model` (bool, default false) |
| Ollama Update | `update-ollama.yaml` | SSH to DGX host and install/upgrade Ollama; runner choice: `dgx` or `wsl2`. Uses vars `DGX_HOST`, `DGX_HOST_USER` and secret `DGX_HOST_SSH_KEY`. |
| Setup Shared SSH Store | `setup-shared-ssh.yaml` | **One-time setup.** Initialises `~/shared/ssh/` on DGX (canonical config/known_hosts/authorized_keys), creates `~/.ssh` symlinks on DGX and Orin, wires Orin CIFS mount. Run before first WSL2 Post-Provision. Requires vars `DGX_HOST`, `DGX_HOST_USER` and secrets `DGX_HOST_SSH_KEY`, `DGX_SMB_PASSWORD`. |
| WSL2 Provision | `provision-wsl2.yaml` | Import a new WSL2 distro from `C:\wsl-templates\ubuntu-22.04-configured-template.tar` on the Windows host. |
| WSL2 Post-Provision | `post-provision-wsl2.yaml` | Per-distro SSH mesh setup: `.wslconfig`, firewall, sshd port, CIFS mount of `~/shared` in WSL2, `~/.ssh` symlinks, key distribution into shared store, `wsl2-<name>` host block in shared config, Windows SSH hardlink. Requires `DGX_SMB_PASSWORD`. |
| WSL2 Verify SSH Topology | `verify-ssh-topology.yaml` | Validate every SSH path in the lab mesh using `wsl2-<distro_name>` alias; checks `~/.ssh/config` host blocks on each machine; reports ✅/❌ per path. Inputs: `distro_name`, `ssh_port`. |
| WSL2 Unprovision | `unprovision-wsl2.yaml` | Unregister a WSL2 distro; optionally delete `C:\wsl\<name>` from disk. |

Typical node-count sequence: run **GKE Expand** → deploy workload → run **GKE Restore**. Expand saves the full node pool JSON plus live node count to `gs://miramar-platform-cluster-state/gke/node-pool-<pool>.json`; Restore reads from it automatically — no manual count needed. `node_count_override` on Restore is available as a fallback.

Typical GPU sequence: run **GKE Expand GPU** → deploy GPU workload → run **GKE Restore GPU**.

The node pool is named `default-pool` (created by `gcloud container clusters create` default behaviour, preserved in Terraform).

## GCP project structure

Single project: **`miramar-platform`** — GKE cluster (`miramar-shared-gke`), Artifact Registry repo (`apps`), WIF pool/provider, deploy service accounts, and workloads.

GitHub Actions authenticate keylessly via Workload Identity Federation. The WIF attribute condition restricts access to repos under the `miramar-labs-org` GitHub org.

The cluster operations SA (`gh-gke-cluster-ops@miramar-platform.iam.gserviceaccount.com`) holds:
`roles/container.admin`, `roles/storage.admin`, `roles/artifactregistry.admin`,
`roles/serviceusage.serviceUsageConsumer`, `roles/compute.viewer` (required by Terraform to read instance group state after node pool operations), `roles/compute.instanceAdmin` (required by the **Find GPU Capacity** workflow to create+delete probe instances), and `roles/iam.serviceAccountUser` on the default Compute SA.

## Cost-control constraints

The cluster is intentionally minimized. These constraints must be preserved:
- Node type: `e2-medium`, single node, `pd-standard` disk
- No `LoadBalancer` Services — use `ClusterIP` + `kubectl port-forward` for testing
- No PersistentVolumeClaims, Cloud NAT, or regional clusters

## Self-hosted GHA runners

`mlabs-runner/` contains the Dockerfile and entrypoint for running GitHub Actions runners on the self-hosted machines.

**Build:** triggered automatically by `.github/workflows/build-mlabs-runner.yml` on push to `main`. Uses QEMU + buildx to produce a single multi-arch manifest (`linux/amd64`, `linux/arm64`). Image pushes to GHCR as `ghcr.io/miramar-labs-org/mlabs-runner`.

**Launch:**
```sh
./scripts/gha/launch-runner.sh
```
Token is fetched automatically via `GITHUB_ORG_ADMIN_PAT`. Idempotent — re-running while the container is already up just prints status. Work directory is mounted from `~/runner/_work` on the host into `/home/runner/_work` in the container.

Local machine env vars required: `GITHUB_ORG_GHCR_PAT` (pull runner image), `GITHUB_ORG_ADMIN_PAT` (register/deregister runner). `HF_TOKEN` is a GitHub org secret — injected by workflows, not needed locally.

**Runner registration tokens** are obtained from GitHub UI or API and expire after 1 hour. The container deregisters cleanly on `SIGTERM`.

To bump the runner version, update `RUNNER_VERSION` in `mlabs-runner/Dockerfile` or trigger `workflow_dispatch` with the `runner_version` input.

## DGX local services

The DGX Spark runs a minikube cluster hosting platform workloads. Four systemd user services start automatically on boot (via linger) — managed via `dgx/systemd/`:

| Service | Port | Purpose |
|---|---|---|
| `minikube` | — | Starts/stops minikube; other services depend on it |
| `dashboard` | `8001` | `kubectl proxy --context minikube` for the Kubernetes dashboard |
| `jupyterlab` | `8888` | JupyterLab in the pyNeMo Python environment |
| `mlflow-portfwd` | `5000` | `kubectl port-forward svc/mlflow-tracking` — org MLflow instance |

**Minikube lifecycle** is managed exclusively via GHA workflows (`install-minikube`, `uninstall-minikube`, `toggle-minikube`). The minikube binary lives on the DGX host at `/usr/local/bin/minikube` — installed by the Install workflow. The runner container mounts `~/.minikube` and `~/.kube` from the host (DGX-only) so cluster state persists across ephemeral runner containers.

**DGX workload stack** (deployment order): Minikube Install → NeMo Deploy → MLflow Deploy → NIM Deploy (or Ollama Deploy)

**NeMo Microservices** runs in minikube (`nemo-microservices` namespace). Exposes `nemo.test` (deployment API) and `nim.test` (inference) via ingress entries in `/etc/hosts`. Requires `NVIDIA_API_KEY` secret.

**NIM** pods run inside `nemo-microservices`, deployed via the NeMo deployment API. The default NIM is `nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark` (tools enabled). Available NIMs for DGX Spark: `nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark`, `meta/llama-3.1-8b-instruct-dgx-spark`. Scripts in `dgx/minikube/nim/`. See `dgx/minikube/nim/NIM.md` for the full catalog.

**Ollama** runs as a systemd service on the DGX host (not in minikube). Managed via the **Ollama Deploy** / **Ollama Undeploy** / **Ollama Update** workflows. Scripts in `dgx/ollama/`. See `dgx/ollama/README.md` for the model catalog and curl examples. **NIM and Ollama share the 128 GB unified memory pool.** ~28 GB is reserved for system use (minikube, OS), leaving ~100 GB for workloads — they can coexist as long as their combined memory fits within that budget. The deploy scripts check for insufficient headroom and fail with a clear error if there is a conflict.

Ollama API quirks (relevant when editing scripts):
- Unloading is done via `POST /api/generate` with `{"model":"...","prompt":"","keep_alive":0}`. The `prompt` field is required — omitting it causes the request to be silently ignored and the model stays loaded.
- The API call returns before VRAM is actually freed; poll `GET /api/ps` until `.models` is empty (up to ~60s for a 70B model).
- SSH workflows that pass an optional model arg use `printf '%q'` to avoid empty-string args being dropped by SSH arg concatenation — see `undeploy-ollama.yaml` and `DEVELOPER.md`.

**MLflow** runs in minikube (`mlflow-system` namespace). `MLFLOW_TRACKING_URI=http://host.docker.internal:5000` — works from inside the mlabs-runner container because the port-forward binds to `0.0.0.0`. All other services bind to `127.0.0.1`.

Access all services from a laptop via SSH tunnel:
```sh
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 <user>@spark-79b7.local
```
