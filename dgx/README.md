# DGX Spark (spark-79b7)

[NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/) 128GB — aarch64, GB10 Blackwell GPU, runner label `dgx`.

## Contents

| Folder | Purpose |
|---|---|
| [minikube/](minikube/) | GHA workflows for minikube cluster lifecycle + NeMo deployment scripts |
| [systemd/](systemd/) | Systemd user service unit files + install/uninstall scripts |

## Systemd services

Five user services start automatically on boot (via linger) — see [systemd/](systemd/) for unit files and install instructions:

| Service | Port | What it does |
|---|---|---|
| `minikube` | — | Starts/stops the [minikube](https://minikube.sigs.k8s.io/) cluster |
| `dashboard` | `8001` | `kubectl proxy` → minikube Kubernetes dashboard |
| `jupyterlab` | `8888` | [JupyterLab](https://jupyter.org) |
| `mlflow-portfwd` | `5000` | `kubectl port-forward` → [MLflow](https://mlflow.org) (`svc/mlflow-tracking` in minikube) |
| `kubeflow-portfwd` | `8080` | `kubectl port-forward` → [Kubeflow Pipelines](https://www.kubeflow.org/) UI (`svc/ml-pipeline-ui` in minikube) |

`dashboard` and `jupyterlab` bind to `127.0.0.1`; the port-forward services bind to `0.0.0.0` so the runner container can reach them. Access from your laptop via SSH tunnel:

```sh
ssh -L 8001:localhost:8001 \
    -L 8888:localhost:8888 \
    -L 5000:localhost:5000 \
    -L 8080:localhost:8080 \
    -L 11434:localhost:11434 \
    <user>@spark-79b7.local
```

| Port | Service |
|---|---|
| `8001` | Kubernetes dashboard |
| `8888` | JupyterLab |
| `5000` | MLflow |
| `8080` | Kubeflow Pipelines UI |
| `11434` | Ollama API |

[Ollama](https://ollama.com) (`port 11434`) is installed via `scripts/ubuntu/install-ollama.sh` and runs as a native systemd service — not in the table above as it is not a user service managed by `dgx/systemd/`.

On Windows, [Bitvise SSH Client](https://www.bitvise.com/ssh-client) is used to configure all tunnels at once in a saved session profile — no need to pass `-L` flags on the command line each time.

## References

| Technology | GitHub | Docs |
|---|---|---|
| [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/) | — | [developer docs](https://docs.nvidia.com/dgx/index.html) |
| [minikube](https://minikube.sigs.k8s.io/) | [kubernetes/minikube](https://github.com/kubernetes/minikube) | [docs](https://minikube.sigs.k8s.io/docs/) |
| [JupyterLab](https://jupyter.org) | [jupyterlab/jupyterlab](https://github.com/jupyterlab/jupyterlab) | [docs](https://jupyterlab.readthedocs.io/) |
| [MLflow](https://mlflow.org) | [mlflow/mlflow](https://github.com/mlflow/mlflow) | [docs](https://mlflow.org/docs/latest/index.html) |
| [Kubeflow Pipelines](https://www.kubeflow.org/) | [kubeflow/pipelines](https://github.com/kubeflow/pipelines) | [docs](https://www.kubeflow.org/docs/components/pipelines/) |
| [Ollama](https://ollama.com) | [ollama/ollama](https://github.com/ollama/ollama) | [API docs](https://github.com/ollama/ollama/blob/main/docs/api.md) |
