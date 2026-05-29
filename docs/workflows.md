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

## DGX Local AI Stack

| Workflow | File | Purpose |
| --- | --- | --- |
| Minikube Install | `install-minikube.yaml` | Install/start DGX minikube and update kubeconfig secret |
| Minikube Uninstall | `uninstall-minikube.yaml` | Delete cluster and purge minikube state |
| Minikube Toggle | `toggle-minikube.yaml` | Pause/resume DGX minikube |
| NeMo Deploy | `deploy-nemo.yaml` | Install NeMo Microservices and Volcano; `nemo_version` input; auto-commits doc/SDK updates; writes `NEMO_VERSION` |
| NeMo Undeploy | `undeploy-nemo.yaml` | Remove NeMo, Volcano, DNS entries, and postgres PVCs |
| MLflow Deploy | `deploy-mlflow.yaml` | Deploy MLflow + MinIO into minikube |
| MLflow Undeploy | `undeploy-mlflow.yaml` | Remove MLflow namespace |
| NIM Deploy | `deploy-nim.yaml` | Deploy a NIM via NeMo API; swaps conflicting NIM; rollback on failure; writes `CURRENT_NIM_MODEL` |
| NIM Undeploy | `undeploy-nim.yaml` | Remove a NIM deployment; clears `CURRENT_NIM_MODEL` |
| Ollama Deploy | `deploy-ollama.yaml` | Auto-undeploy existing model, pull + load new one; rollback on failure; writes `CURRENT_OLLAMA_MODEL` |
| Ollama Undeploy | `undeploy-ollama.yaml` | Unload/delete an Ollama model; clears `CURRENT_OLLAMA_MODEL` |
| Ollama Update | `update-ollama.yaml` | Install or upgrade Ollama on the DGX host; writes `OLLAMA_VERSION` |

| Build KFP arm64 Images | `build-kfp-arm64.yaml` | Build all 13 KFP arm64 images on DGX; optional `component` input to rebuild one |
| Kubeflow Deploy | `deploy-kubeflow.yaml` | Deploy KFP standalone with native arm64 images; writes `KFP_VERSION` |
| Kubeflow Undeploy | `undeploy-kubeflow.yaml` | Remove KFP and cluster-scoped resources |

DGX stack order:

```text
Minikube Install -> NeMo Deploy -> MLflow Deploy -> NIM Deploy (or Ollama Deploy)
```

**Platform state repo variables** written by workflows and displayed in the dashboard status bar:

| Variable | Written by | Cleared by | Default |
| --- | --- | --- | --- |
| `NEMO_VERSION` | NeMo Deploy | — | `25.12.1` |
| `KFP_VERSION` | Kubeflow Deploy | — | `2.16.1` |
| `OLLAMA_VERSION` | Ollama Update | — | set by `update-ollama.yaml` |
| `CURRENT_NIM_MODEL` | NIM Deploy | NIM Undeploy, NIM Deploy rollback | `none` |
| `CURRENT_OLLAMA_MODEL` | Ollama Deploy | Ollama Undeploy, Ollama Deploy rollback | `none` |

Variables must exist before the dashboard reads them. On a fresh install, seed them via the GitHub UI (`Settings → Secrets and variables → Actions → Variables`) or with the PATCH→POST upsert pattern using `GITHUB_ORG_ADMIN_PAT`.

See [dgx.md](dgx.md), [../dgx/minikube/](../dgx/minikube/), and
[../dgx/ollama/README.md](../dgx/ollama/README.md).

## Projects and Dashboard

| Workflow | File | Purpose |
| --- | --- | --- |
| Create Project | `create-project.yaml` | Create a new org repo pre-wired with notebook, KFP/NeMo pipeline stub, and deploy/undeploy workflows |
| Delete Project | `delete-project.yaml` | Permanently delete a platform repo (double-entry guard); triggers dashboard refresh |
| Deploy Platform Dashboard | `deploy-dashboard.yaml` | Build and publish the GitHub Pages project dashboard; reads platform state variables; runs hourly |

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
