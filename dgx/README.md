# DGX Spark (spark-79b7)

NVIDIA DGX Spark 128GB — aarch64, GB10 Blackwell GPU, runner label `dgx`.

## Contents

| Folder | Purpose |
|---|---|
| [minikube/](minikube/) | GHA workflows for minikube cluster lifecycle + NeMo deployment scripts |
| [systemd/](systemd/) | Systemd user service unit files + install/uninstall scripts |

## Systemd services

Four user services start automatically on boot (via linger) — see [systemd/](systemd/) for unit files and install instructions:

| Service | Port | What it does |
|---|---|---|
| `minikube` | — | Starts/stops the minikube cluster |
| `dashboard` | `8001` | `kubectl proxy` → minikube Kubernetes dashboard |
| `jupyterlab` | `8888` | JupyterLab |
| `mlflow-portfwd` | `5000` | `kubectl port-forward` → `svc/mlflow-tracking` in minikube |

`dashboard` and `jupyterlab` bind to `127.0.0.1`; `mlflow-portfwd` binds to `0.0.0.0` so the runner container can reach it. Access from your laptop via SSH tunnel:

```sh
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 -L 11434:localhost:11434 <user>@spark-79b7.local
```

| Port | Service |
|---|---|
| `8001` | Kubernetes dashboard |
| `8888` | JupyterLab |
| `5000` | MLflow |
| `11434` | Ollama API |

Ollama (`port 11434`) is installed via `scripts/ubuntu/install-ollama.sh` and runs as a native systemd service — not in the table above as it is not a user service managed by `dgx/systemd/`.

On Windows, [Bitvise SSH Client](https://www.bitvise.com/ssh-client) is used to configure all tunnels at once in a saved session profile — no need to pass `-L` flags on the command line each time.
