# k3s workloads (DGX)

[k3s](https://k3s.io/) cluster on the [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/).
Cluster lifecycle and every workload are managed exclusively via [GitHub Actions](https://github.com/features/actions)
workflows — the scripts in this tree are invoked by those workflows, not run by hand.

## Cluster lifecycle

| Workflow          | Purpose                                                               |
| ----------------- | -------------------------------------------------------------------- |
| **K3s Install** (`install-k3s.yaml`)     | Install k3s with the NVIDIA device plugin + nginx-ingress; label the node; update the kubeconfig secret |
| **K3s Uninstall** (`uninstall-k3s.yaml`) | Tear the cluster down and remove k3s from the host                                                     |
| **K3s Bootstrap** (`bootstrap-k3s.yaml`) | Full end-to-end bootstrap of a fresh host (install + all workloads)                                    |

## Workloads

| Folder                         | Deploy / undeploy workflows                                    | Contents                                                                 |
| ------------------------------ | ----------------------------------------------------------- | ---------------------------------------------------------------------- |
| [nemo/](nemo/)                 | **NeMo Deploy** / **NeMo Undeploy**                          | [NeMo Microservices](https://docs.nvidia.com/nemo/microservices/) Helm install — values, endpoints, verify scripts |
| [nim/](nim/)                   | **NIM Deploy** / **NIM Undeploy**                            | [NIM](https://developer.nvidia.com/nim) inference — deploy, undeploy, log tailing |
| [mlflow/](mlflow/)             | **MLflow Deploy** / **Redeploy MLflow** / **MLflow Undeploy** | [MLflow](https://mlflow.org) tracking server — integrate, redeploy, verify, destroy |
| [qdrant/](qdrant/)             | **Qdrant Deploy** / **Qdrant Undeploy**                      | [Qdrant](https://qdrant.tech) vector DB — integrate, verify, destroy    |
| [kubeflow/](kubeflow/)         | **Kubeflow Deploy** / **Kubeflow Undeploy**                  | [Kubeflow Pipelines](https://www.kubeflow.org/) standalone deploy/destroy + arm64 image patches |
| [nsight/](nsight/)             | **Nsight Operator Deploy** / **Nsight Operator Undeploy**    | [Nsight](https://developer.nvidia.com/nsight-systems) Operator Helm values |
| [model-router/](model-router/) | (auto-registered by serving deploys)                        | [LiteLLM](https://litellm.ai) model-router config                       |
| [openwebui/](openwebui/)       | —                                                          | [Open WebUI](https://openwebui.com) chat UI manifests                   |
| [postgres/](postgres/)         | **Postgres Deploy**                                          | Shared Postgres 16 instance manifests                                   |

Ollama runs as a **native systemd service on the host** (not in k3s) — see [../ollama/](../ollama/).

## Access the Kubernetes dashboard

`kubectl proxy` on port `8001` is managed by the systemd service in [../systemd/](../systemd/).
It starts automatically. Open an SSH tunnel from your laptop:

```sh
ssh -L 8001:localhost:8001 <user>@spark-79b7.local
```

Then open:

```
http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/
```

## Reinstalling from scratch

Run the **K3s Uninstall** workflow, then **K3s Install** (or **K3s Bootstrap** to also
redeploy every workload). Both keep the `<RUNNER>_K3S_KUBECONFIG` org secret current.

## References

| Technology                                                        | GitHub                                                     | Docs                                                       |
| ----------------------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------- |
| [k3s](https://k3s.io/)                                            | [k3s-io/k3s](https://github.com/k3s-io/k3s)               | [docs](https://docs.k3s.io/)                              |
| [NeMo Microservices](https://docs.nvidia.com/nemo/microservices/) | —                                                        | [docs](https://docs.nvidia.com/nemo/microservices/latest/) |
| [Kubeflow Pipelines](https://www.kubeflow.org/)                   | [kubeflow/pipelines](https://github.com/kubeflow/pipelines) | [docs](https://www.kubeflow.org/docs/components/pipelines/) |
| [Helm](https://helm.sh)                                           | [helm/helm](https://github.com/helm/helm)                 | [docs](https://helm.sh/docs/)                             |
