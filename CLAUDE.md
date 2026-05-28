# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Infrastructure and CI/CD tooling for the Miramar platform on GCP. It provisions a single GCP project (`miramar-platform`) containing a shared GKE Standard cluster, Artifact Registry, Workload Identity Federation for keyless GitHub Actions auth, and supporting resources. It also contains Docker images and a launch script for self-hosted GitHub Actions runners.

## Platform topology

**Physical machines (self-hosted GHA runners):**

- **Windows laptop / WSL2** — Ubuntu 22.04, x86_64 (amd64), AMD CPU, NVIDIA RTX 4060 (sm_89). Runner label: `wsl2`.
- **NVIDIA DGX Spark 128GB** — DGX OS (Ubuntu 24.04), aarch64 (arm64), 20-core Arm CPU (10× Cortex-X925 + 10× Cortex-A725), GB10 Superchip Blackwell GPU (6144 CUDA cores, 5th-gen Tensor Cores). Runner label: `dgx`.
- **NVIDIA Jetson AGX Orin 64GB** — Ubuntu 22.04 (JetPack 6.x), aarch64 (arm64), 12-core Cortex-A78AE, Ampere GPU 2048 CUDA cores (sm_87), CUDA 12.6. Runner label: `agx`.

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
  bootstrap.sh        # One-time clean-template setup (run before first template export)
  rebuild-template.ps1 # Rebuild the configured template tarball (bakes .smbcredentials, removes stale fstab mounts)
  README.md           # Operator quickstart for WSL2 provisioning
  firstboot.sh        # One-shot provisioning run inside a new distro via wsl exec
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

| Script                                                        | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gcp/bootstrap-miramar-platform.zsh`                          | One-time local setup — project creation, billing, APIs, WIF pool/provider, service accounts, IAM bindings                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `gcp/create-miramar-platform.zsh`                             | K8s-only setup — AR IAM bindings for deploy SAs, namespaces, resource quotas, RBAC. GCP resources are managed by Terraform.                                                                                                                                                                                                                                                                                                                                                                                               |
| `gcp/list-miramar-platform.zsh`                               | Enumerate live GCP resources in the project                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| `scripts/gha/sync-github-tf-vars.sh`                          | Sync `gcp/terraform/terraform.tfvars` → GitHub org variables. Run after editing tfvars.                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `scripts/gha/launch-runner.sh` / `scripts/gha/stop-runner.sh` | Start / gracefully stop+deregister the mlabs-runner container. `launch-runner.sh` is idempotent — if the container is already running it prints status and exits 0.                                                                                                                                                                                                                                                                                                                                                       |
| `scripts/gha/flush-queues.sh`                                 | Cancel all in-progress, queued, and waiting workflow runs                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `scripts/ubuntu/install-gcloud.sh`                            | Install `gcloud` via apt on Ubuntu/Debian                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `scripts/ubuntu/install-terraform.sh`                         | Install `terraform` via apt on Ubuntu/Debian                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `scripts/ubuntu/install-gh.sh`                                | Install `gh` (GitHub CLI) via apt on Ubuntu/Debian                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `scripts/ubuntu/install-ollama.sh`                            | Install or upgrade Ollama on the host (run as root); installs `zstd` prerequisite; skips if already at latest version. Deployed to DGX via SCP by the **Ollama Update** workflow.                                                                                                                                                                                                                                                                                                                                         |
| `scripts/gcp/gke/find-gpu-capacity.sh`                        | Probe actual GPU capacity across all GPU types and zones in parallel. Default scope: all US regions (`us-*`). Pass a region to narrow (`us-central1`). Shows top 5 cheapest options split by [USE NOW] / [REQUEST QUOTA FIRST] with ready-to-use GKE Expand GPU settings.                                                                                                                                                                                                                                                 |
| `dgx/ollama/deploy_ollama.sh`                                 | Run on DGX host via SSH to pull an Ollama model and load it into GPU memory. Fails if a NIM or another Ollama model is already using the 128 GB pool. Called by the **Ollama Deploy** workflow.                                                                                                                                                                                                                                                                                                                           |
| `dgx/ollama/undeploy_ollama.sh`                               | Run on DGX host via SSH to unload an Ollama model from GPU memory. Auto-detects the loaded model if no arg given. Called by the **Ollama Undeploy** workflow.                                                                                                                                                                                                                                                                                                                                                             |
| `dgx/systemd/install.sh` / `uninstall.sh`                     | Install or remove the five DGX systemd user services (minikube, dashboard proxy, JupyterLab, MLflow port-forward, Kubeflow Pipelines port-forward).                                                                                                                                                                                                                                                                                                        |
| `wsl2/bootstrap.sh`                                           | One-time setup for a fresh WSL2 template base — installs dev tools, Docker, Kubernetes tooling, pyenv, Miniforge, Go, and baseline SSH tooling. Requires `DGX_SMB_PASSWORD` (baked into `/home/aaron/.smbcredentials`). Installs `setup-shared-ssh.sh` and the `mount-dgx-shared` systemd timer. Run inside the clean template base before exporting the configured template.                                                           |
| `wsl2/rebuild-template.ps1`                                   | Rebuild the configured template tarball from an existing one. Params: `-SmbPassword` (required), `-DistroUser` (default `aaron`), `-TarPath`, `-BuildName`, `-BuildDir`. Imports the current template as a temp distro, removes stale shared-folder `/etc/fstab` entries, keeps `mountFsTab=false`, and writes `.smbcredentials` (baking credentials in so no runtime password delivery is needed), exports back to the same tar path (backs up old tar as `-prev.tar`), then cleans up. Run on Windows PowerShell after changing `bootstrap.sh` or rotating the Samba password. |
| `wsl2/firstboot.sh`                                           | One-shot provisioning script run once inside a new distro via Windows SSH -> `wsl -d NAME --user root -- bash`. Reads `/etc/wsl2-provision.conf` (written by the provision workflow), sets the hostname, configures sshd port via systemd (no TCP connection to drop), then calls `setup-shared-ssh.sh` to mount `//DGX/shared` and symlink `/home/aaron/.ssh/` to `/home/aaron/shared/ssh/`. Using wsl exec avoids WSL2 mirrored-networking issues that break direct port-2222 SSH during provisioning.                                                      |
| `wsl2/setup-shared-ssh.sh`                                    | Installed at `/usr/local/bin/setup-shared-ssh.sh` on WSL2 distros by `bootstrap.sh`; **Setup Shared SSH Store** performs equivalent shared-store wiring for Orin. Mounts `//DGX/shared` at `/home/aaron/shared/` via CIFS (`cifs-utils`) and symlinks all `/home/aaron/.ssh/` files (`config`, `known_hosts`, `authorized_keys`, `id_ed25519`, `id_ed25519.pub`) to `/home/aaron/shared/ssh/`. Also writes the on-demand `wsl2-<name>` host block directly into the shared `config`; that ProxyCommand mounts the shared store before execing `sshd -i`. All machines share Spark's SSH identity — no per-machine keypair and no local per-distro `authorized_keys`. Idempotent. |
| `wsl2/probe-ssh-ports.ps1`                                    | Run on Windows PowerShell before provisioning a new distro to find a safe sshd port. Checks each port in a range against Windows TCP listeners, Windows excluded TCP port ranges, and real `sshd` bindability inside the target WSL distro. Prints contiguous OK ranges. Usage: `.\probe-ssh-ports.ps1 -Distro dev -StartPort 2222 -EndPort 2299`. The distro must already exist. |
| `wsl2/README.md`                                              | Short operator guide for WSL2 workflows, prerequisites, secrets, template refresh, ports, and validation.                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `wsl2/TECHNICAL.md`                                           | Source of truth for WSL2 template build procedures, lifecycle behavior, on-demand ProxyCommand SSH, shared `authorized_keys`, supported verify paths, direct port assignments (`dev` 2222, `test` 2223), and troubleshooting.                                                                                                                                                                                                                                                                                                                                                                    |

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

| Workflow                 | File                            | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------------------ | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Miramar Platform Create  | `miramar-platform-create.yaml`  | `terraform apply` (GKE cluster + AR repo) then K8s namespaces + RBAC via `create-miramar-platform.zsh`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Miramar Platform Destroy | `miramar-platform-destroy.yaml` | `terraform destroy` (GKE + AR), gcloud fallback for pre-Terraform resources, delete state bucket, optionally delete project                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| GKE Expand               | `gke-expand.yaml`               | Snapshot node pool state to GCS, then `terraform apply -var=node_pool_count=N`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| GKE Restore              | `gke-restore.yaml`              | Read saved state from GCS, then `terraform apply -var=node_pool_count=<saved>`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| GKE Expand GPU           | `gke-expand-gpu.yaml`           | `terraform apply` in `gcp/terraform-gpu/` to add a GPU node pool; expands namespace quota                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| GKE Restore GPU          | `gke-restore-gpu.yaml`          | `terraform destroy` in `gcp/terraform-gpu/` to remove the GPU pool; restores namespace quota                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Find GPU Capacity        | `find-gpu-capacity.yaml`        | Probes all GPU types and zones in parallel; shows top 5 cheapest options split by [USE NOW] vs [REQUEST QUOTA FIRST] with exact settings for GKE Expand GPU                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Minikube Install         | `install-minikube.yaml`         | Install minikube on DGX host, start cluster, enable addons (ingress, dashboard, metrics-server), wait for ingress-nginx readiness, update `DGX_MINIKUBE_KUBECONFIG` secret                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| Minikube Uninstall       | `uninstall-minikube.yaml`       | Delete cluster, purge state, remove minikube binary from DGX host                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| Minikube Toggle          | `toggle-minikube.yaml`          | SSH to DGX host and run `minikube pause` / `minikube unpause`. Inputs: `action` (`pause` \| `resume`), `runner` (`dgx` \| `wsl2`, default: `dgx`)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| NeMo Deploy              | `deploy-nemo.yaml`              | Install NeMo Microservices + Volcano via Helm on the DGX minikube cluster; triggers MLflow Deploy on success                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| NeMo Undeploy            | `undeploy-nemo.yaml`            | Uninstall NeMo + Volcano; deletes postgres PVCs before uninstall to prevent password drift on redeploy; input: `delete_namespace` (bool, default true)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| NIM Deploy               | `deploy-nim.yaml`               | Deploy a NIM via the NeMo deployment API; swaps any different running NIM first. Inputs: `nim_name` (default: `nvidia-nemotron-nano-9b-v2-dgx-spark`), `nim_org` (default: `nvidia`), `image_tag` (default: `1.0.0-variant`)                                                                                                                                                                                                                                                                                                                                                                                                                               |
| NIM Undeploy             | `undeploy-nim.yaml`             | Undeploy a NIM via the NeMo deployment API; 404 is a no-op. Inputs: `nim_name`, `nim_org`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| MLflow Deploy            | `deploy-mlflow.yaml`            | Deploy MLflow + MinIO into mlflow-system; integrates with NeMo postgres via pg_hba.conf trust bootstrap (no superuser password needed). Auto-triggered by NeMo Deploy.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| MLflow Undeploy          | `undeploy-mlflow.yaml`          | Remove MLflow and MinIO; always deletes mlflow-system namespace                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| Kubeflow Deploy          | `deploy-kubeflow.yaml`          | Deploy Kubeflow Pipelines standalone into the kubeflow namespace via `kubectl apply -k`; UI at port 8080 via kubeflow-portfwd.service. Input: `pipeline_version` (default `2.5.0`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| Kubeflow Undeploy        | `undeploy-kubeflow.yaml`        | Remove Kubeflow Pipelines and cluster-scoped resources; input: `pipeline_version`, `delete_namespace` (default true).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Ollama Deploy            | `deploy-ollama.yaml`            | SSH to DGX host and pull + load an Ollama model into GPU memory. Fails with an explicit error if a NIM or another Ollama model is already using the 128 GB pool. Input: `model` (default: `llama3.3:70b-instruct-q4_K_M`)                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Ollama Undeploy          | `undeploy-ollama.yaml`          | SSH to DGX host and unload the active Ollama model from GPU memory. Auto-detects loaded model if `model` input is blank. Input: `model` (optional), `delete_model` (bool, default false)                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Ollama Update            | `update-ollama.yaml`            | SSH to DGX host and install/upgrade Ollama; runner choice: `dgx` or `wsl2`. Uses vars `DGX_HOST_IP`, `DGX_HOST_USER` and secret `DGX_HOST_SSH_KEY`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Setup Shared SSH Store   | `setup-shared-ssh.yaml`         | **One-time setup.** Initialises `/home/aaron/shared/ssh/` on DGX, creates `/home/aaron/.ssh` symlinks on DGX, wires Orin (CIFS mount of `//DGX/shared` + symlinks `/home/aaron/.ssh/` to `/home/aaron/shared/ssh/`). Orin setup SSHes to `localhost:22` from the agx runner container (container uses `--network=host`). Requires vars `DGX_HOST_IP`, `DGX_HOST_USER` and secrets `DGX_HOST_SSH_KEY`, `ORIN_HOST_SSH_KEY`, `DGX_SMB_PASSWORD`.                                                                                                                                                                                                                                                        |
| WSL2 Provision           | `provision-wsl2.yaml`           | Full lifecycle: import distro from template, open Windows firewall, run `firstboot.sh` inside the distro via `wsl exec` (sets hostname, sshd port, post-boot CIFS mount, SSH symlinks), authorize DGX key, verify sshd + systemd. On success, adds distro name to `WSL2_DISTROS` repo variable. All per-distro config is done via Windows SSH → PowerShell → `wsl -d NAME --user root` — no direct port-2222 SSH, avoiding WSL2 mirrored-networking issues. `.smbcredentials` is baked into the template by `rebuild-template.ps1`. Secrets: `WSL2_HOST`, `WSL2_HOST_USER`, `WSL2_HOST_SSH_KEY`, `DGX_HOST_SSH_KEY`. Vars: `DGX_HOST_IP`, `DGX_HOST_USER`. |
| WSL2 Verify SSH Topology | `verify-ssh-topology.yaml`      | Validate supported SSH paths. Reads active distros from `WSL2_DISTROS` repo variable and tests: spark/orin core reachability, spark/orin to each `wsl2-<name>`, and each `wsl2-<name>` back to spark/orin. WSL2-to-WSL2 peer checks are intentionally excluded because WSL2 distros are on-demand endpoints reached through Windows `wsl.exe`, not a resident peer mesh. Optional `distros` input overrides `WSL2_DISTROS`; blank input reads the repo variable. Reports pass/fail per path in the workflow summary. |
| WSL2 Unprovision         | `unprovision-wsl2.yaml`         | Unregister a WSL2 distro; optionally delete `C:\wsl\<name>` from disk. Removes distro name from `WSL2_DISTROS` repo variable (sets to `NONE` if none remain).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |

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

**Network:** containers run with `--network=host` so `.local` mDNS names (`spark-79b7.local`, `orin.local`, `msi.local`) resolve correctly. The image includes `libnss-mdns` with `mdns4_minimal` in `/etc/nsswitch.conf`.

Local machine env vars required: `GITHUB_ORG_GHCR_PAT` (pull runner image, needs `read:packages`), `GITHUB_ORG_ADMIN_PAT` (register/deregister runner + write repo variables, needs `admin:org` and `repo` scopes). `HF_TOKEN` is a GitHub org secret — injected by workflows, not needed locally.

**Runner registration tokens** are obtained from GitHub UI or API and expire after 1 hour. The container deregisters cleanly on `SIGTERM`.

To bump the runner version, update `RUNNER_VERSION` in `mlabs-runner/Dockerfile` or trigger `workflow_dispatch` with the `runner_version` input.

## DGX local services

The DGX Spark runs a minikube cluster hosting platform workloads. Five systemd user services start automatically on boot (via linger) — managed via `dgx/systemd/`:

| Service              | Port   | Purpose                                                                    |
| -------------------- | ------ | -------------------------------------------------------------------------- |
| `minikube`           | —      | Starts/stops minikube; other services depend on it                         |
| `dashboard`          | `8001` | `kubectl proxy --context minikube` for the Kubernetes dashboard            |
| `jupyterlab`         | `8888` | JupyterLab in the pyNeMo Python environment                                |
| `mlflow-portfwd`     | `5000` | `kubectl port-forward svc/mlflow-tracking` — org MLflow instance           |
| `kubeflow-portfwd`   | `8080` | `kubectl port-forward svc/ml-pipeline-ui` — Kubeflow Pipelines UI         |

**Minikube lifecycle** is managed exclusively via GHA workflows (`install-minikube`, `uninstall-minikube`, `toggle-minikube`). The minikube binary lives on the DGX host at `/usr/local/bin/minikube` — installed by the Install workflow. The runner container mounts `~/.minikube` and `~/.kube` from the host (DGX-only) so cluster state persists across ephemeral runner containers.

**DGX workload stack** (deployment order): Minikube Install → NeMo Deploy → MLflow Deploy → NIM Deploy (or Ollama Deploy)

**NeMo Microservices** runs in minikube (`nemo-microservices` namespace). Exposes `nemo.test` (deployment API) and `nim.test` (inference) via ingress entries in `/etc/hosts`. Requires `NVIDIA_API_KEY` secret.

**NIM** pods run inside `nemo-microservices`, deployed via the NeMo deployment API. The default NIM is `nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark` (tools enabled). Available NIMs for DGX Spark: `nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark`, `meta/llama-3.1-8b-instruct-dgx-spark`. Scripts in `dgx/minikube/nim/`. See `dgx/minikube/nim/NIM.md` for the full catalog.

**Ollama** runs as a systemd service on the DGX host (not in minikube). Managed via the **Ollama Deploy** / **Ollama Undeploy** / **Ollama Update** workflows. Scripts in `dgx/ollama/`. See `dgx/ollama/README.md` for the model catalog and curl examples. **NIM and Ollama share the 128 GB unified memory pool.** ~28 GB is reserved for system use (minikube, OS), leaving ~100 GB for workloads — they can coexist as long as their combined memory fits within that budget. The deploy scripts check for insufficient headroom and fail with a clear error if there is a conflict.

Ollama API quirks (relevant when editing scripts):

- Unloading is done via `POST /api/generate` with `{"model":"...","prompt":"","keep_alive":0}`. The `prompt` field is required — omitting it causes the request to be silently ignored and the model stays loaded.
- The API call returns before VRAM is actually freed; poll `GET /api/ps` until `.models` is empty (up to ~60s for a 70B model).
- SSH workflows that pass an optional model arg use `printf '%q'` to avoid empty-string args being dropped by SSH arg concatenation — see `undeploy-ollama.yaml` and `DEVELOPER.md`.

**MLflow** runs in minikube (`mlflow-system` namespace). `MLFLOW_TRACKING_URI=http://localhost:5000` — with `--network=host`, the runner container shares the host's network so `localhost` reaches the port-forward directly. The port-forward binds to `0.0.0.0`; all other services bind to `127.0.0.1`.

**Kubeflow Pipelines** runs in minikube (`kubeflow` namespace). UI available at `http://localhost:8080` via `kubeflow-portfwd.service`. Independent of NeMo and MLflow — can be deployed on a fresh minikube cluster. Deployed via `kubectl apply -k` using the official KFP manifests (`env/dev` variant). Scripts in `dgx/minikube/kubeflow/`.

Access all services from a laptop via SSH tunnel:

```sh
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 -L 8080:localhost:8080 <user>@spark-79b7.local
```
