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
| NeMo Deploy | `deploy-nemo.yaml` | Install NeMo Microservices and Volcano |
| NeMo Undeploy | `undeploy-nemo.yaml` | Remove NeMo, Volcano, DNS entries, and postgres PVCs |
| MLflow Deploy | `deploy-mlflow.yaml` | Deploy MLflow + MinIO into minikube |
| MLflow Undeploy | `undeploy-mlflow.yaml` | Remove MLflow namespace |
| NIM Deploy | `deploy-nim.yaml` | Deploy a NIM through the NeMo deployment API |
| NIM Undeploy | `undeploy-nim.yaml` | Remove a NIM deployment |
| Ollama Deploy | `deploy-ollama.yaml` | Pull and load an Ollama model into DGX GPU memory |
| Ollama Undeploy | `undeploy-ollama.yaml` | Unload/delete an Ollama model |
| Ollama Update | `update-ollama.yaml` | Install or upgrade Ollama on the DGX host |

DGX stack order:

```text
Minikube Install -> NeMo Deploy -> MLflow Deploy -> NIM Deploy
```

See [dgx.md](dgx.md), [../dgx/minikube/](../dgx/minikube/), and
[../dgx/ollama/README.md](../dgx/ollama/README.md).

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
