# Workflow Catalog

All workflows are manually dispatchable unless noted otherwise.

## Platform Lifecycle

| Workflow | File | Purpose |
| --- | --- | --- |
| Miramar Platform Create | `miramar-platform-create.yaml` | Create state bucket, run Terraform, then apply Kubernetes setup |
| Miramar Platform Destroy | `miramar-platform-destroy.yaml` | Destroy GKE/Artifact Registry/state bucket; optional project deletion |

Destroy has three guards: exact project name, `i_confirm`, and optional
`delete_project`.

## GKE Scaling

| Workflow | File | Purpose |
| --- | --- | --- |
| GKE Expand | `gke-expand.yaml` | Snapshot node pool state, then resize CPU node pool |
| GKE Restore | `gke-restore.yaml` | Restore node count from the saved GCS snapshot |
| GKE Expand GPU | `gke-expand-gpu.yaml` | Add isolated GPU node pool, device plugin, and quota changes |
| GKE Restore GPU | `gke-restore-gpu.yaml` | Delete GPU node pool and restore namespace quota |
| Find GPU Capacity | `find-gpu-capacity.yaml` | Probe GPU availability and print usable workflow settings |

CPU and GPU expansion are independent. A typical heavy-workload sequence is:

```text
GKE Expand -> GKE Expand GPU -> deploy workload -> GKE Restore GPU -> GKE Restore
```

## Local AI Stack (DGX + AGX)

All workflows accept a `runner` input (`dgx` or `agx`) to target either machine.

| Workflow | File | Purpose |
| --- | --- | --- |
| Minikube Install | `install-minikube.yaml` | Install/start minikube and update kubeconfig secret; writes `DGX_MINIKUBE_VERSION` or `AGX_MINIKUBE_VERSION`. Inputs: `runner` |
| Minikube Uninstall | `uninstall-minikube.yaml` | Delete cluster and purge minikube state. Inputs: `runner` |
| Minikube Toggle | `toggle-minikube.yaml` | Pause/resume minikube. Inputs: `action`, `runner` |
| NeMo Deploy | `deploy-nemo.yaml` | Install NeMo Microservices and Volcano; `nemo_version` input; auto-commits doc/SDK updates; writes `NEMO_VERSION`. Inputs: `runner`, `nemo_version` |
| NeMo Undeploy | `undeploy-nemo.yaml` | Remove NeMo, Volcano, DNS entries, and postgres PVCs. Inputs: `runner` |
| MLflow Deploy | `deploy-mlflow.yaml` | Deploy MLflow + MinIO into minikube; writes `MLFLOW_VERSION` or `MLFLOW_VERSION_AGX`. Inputs: `runner` |
| MLflow Undeploy | `undeploy-mlflow.yaml` | Remove MLflow namespace. Inputs: `runner` |
| NIM Deploy | `deploy-nim.yaml` | Deploy a NIM via NeMo API; swaps conflicting NIM; rollback on failure; writes `CURRENT_NIM_MODEL[_AGX]` + `CURRENT_NIM_VRAM_GB[_AGX]`. Inputs: `runner` |
| NIM Undeploy | `undeploy-nim.yaml` | Remove a NIM deployment; clears `CURRENT_NIM_MODEL[_AGX]` + `CURRENT_NIM_VRAM_GB[_AGX]`. Inputs: `runner` |
| Ollama Deploy | `deploy-ollama.yaml` | Auto-undeploy existing model, pull + load new one; NIM co-deployment allowed if free memory ≥ 15 GB; rollback on failure; writes `CURRENT_OLLAMA_MODEL[_AGX]` + `CURRENT_OLLAMA_VRAM_GB[_AGX]`. Inputs: `runner` |
| Ollama Undeploy | `undeploy-ollama.yaml` | Unload/delete an Ollama model; clears `CURRENT_OLLAMA_MODEL[_AGX]` + `CURRENT_OLLAMA_VRAM_GB[_AGX]`. Inputs: `runner` |
| Ollama Update | `update-ollama.yaml` | Install or upgrade Ollama on target host; writes `OLLAMA_VERSION`. Inputs: `runner` |

| Build KFP arm64 Images | `build-kfp-arm64.yaml` | Build all 13 KFP arm64 images on DGX; optional `component` input to rebuild one. Images are reusable on AGX (both `linux/arm64`). |
| Kubeflow Deploy | `deploy-kubeflow.yaml` | Deploy KFP standalone with native arm64 images; writes `KFP_VERSION`. Inputs: `runner` |
| Kubeflow Undeploy | `undeploy-kubeflow.yaml` | Remove KFP and cluster-scoped resources. Inputs: `runner` |

Stack deployment order (same for both machines):

```text
Minikube Install -> NeMo Deploy -> MLflow Deploy -> NIM Deploy (or Ollama Deploy)
```

**Platform state repo variables** written by workflows and displayed in the dashboard status bars:

| Variable | Written by | Cleared by | Default |
| --- | --- | --- | --- |
| `NEMO_VERSION` | NeMo Deploy | — | `25.12.1` |
| `KFP_VERSION` | Kubeflow Deploy | — | `2.16.1` |
| `OLLAMA_VERSION` | Ollama Update | — | set by workflow |
| `CURRENT_NIM_MODEL` | NIM Deploy (dgx) | NIM Undeploy, rollback | `none` |
| `CURRENT_OLLAMA_MODEL` | Ollama Deploy (dgx) | Ollama Undeploy, rollback | `none` |
| `CURRENT_NIM_VRAM_GB` | NIM Deploy (dgx) | NIM Undeploy, rollback | `0` |
| `CURRENT_OLLAMA_VRAM_GB` | Ollama Deploy (dgx) | Ollama Undeploy, rollback | `0` |
| `CURRENT_NIM_MODEL_AGX` | NIM Deploy (agx) | NIM Undeploy (agx), rollback | `none` |
| `CURRENT_OLLAMA_MODEL_AGX` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback | `none` |
| `CURRENT_NIM_VRAM_GB_AGX` | NIM Deploy (agx) | NIM Undeploy (agx), rollback | `0` |
| `CURRENT_OLLAMA_VRAM_GB_AGX` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback | `0` |
| `DGX_MINIKUBE_VERSION` | Minikube Install (dgx) | — | `—` |
| `AGX_MINIKUBE_VERSION` | Minikube Install (agx) | — | `—` |
| `MLFLOW_VERSION` | MLflow Deploy (dgx) | — | `—` |
| `MLFLOW_VERSION_AGX` | MLflow Deploy (agx) | — | `—` |

Variables must exist before the dashboard reads them. On a fresh install, seed them via the GitHub UI (`Settings → Secrets and variables → Actions → Variables`) or with the PATCH→POST upsert pattern using `GITHUB_ORG_ADMIN_PAT`.

See [dgx.md](dgx.md), [../dgx/minikube/](../dgx/minikube/), and
[../dgx/ollama/README.md](../dgx/ollama/README.md).

## Projects and Dashboard

| Workflow | File | Purpose |
| --- | --- | --- |
| Create Project | `create-project.yaml` | Create a new org repo pre-wired for the platform. Type `default` (generic notebook + endpoint reference, default), `kfp` (KFP v2 pipeline stub + deploy/undeploy), or `nemo` (NeMo training job + deploy/undeploy). `host` input (dgx/agx) sets affinity — clones repo on correct machine and writes `PROJECT_HOST` repo variable. Tags repo `miramar-project` + `miramar-<type>` so it appears in the dashboard. |
| Delete Project | `delete-project.yaml` | Permanently delete a platform repo (double-entry guard); triggers dashboard refresh |
| Deploy Platform Dashboard | `deploy-dashboard.yaml` | Build and publish the GitHub Pages project dashboard. Three status bars: DGX Spark, AGX Orin (NeMo/KFP/Ollama/NIM/Ollama model/VRAM/Minikube/MLflow), and GCP (GKE cluster link, GAR link). Project table includes Host column and JupyterLab links. Runs hourly + on completion of any state-writing workflow. |

## WSL2 and SSH

| Workflow | File | Purpose |
| --- | --- | --- |
| Setup Shared SSH Store | `setup-shared-ssh.yaml` | Initialize Spark shared SSH store and wire Orin |
| WSL2 Provision | `provision-wsl2.yaml` | Import a WSL2 distro from template and wire SSH |
| WSL2 Verify SSH Topology | `verify-ssh-topology.yaml` | Test supported Spark/Orin/WSL2 paths |
| WSL2 Unprovision | `unprovision-wsl2.yaml` | Unregister a distro and update `WSL2_DISTROS` |

See [../wsl2/README.md](../wsl2/README.md),
[../wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md), and
[ssh-runbook.md](ssh-runbook.md).
