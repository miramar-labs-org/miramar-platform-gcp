# DGX Spark (spark-79b7)

NVIDIA DGX Spark 128GB — aarch64, GB10 Blackwell GPU, runner label `dgx`.

## Contents

| Folder | Purpose |
|---|---|
| [minikube/](minikube/) | Scripts to start, stop, pause, and resume the minikube cluster |
| [systemd/](systemd/) | Systemd user service unit files + install/uninstall scripts |

## Systemd services

Three user services run automatically on login — see [systemd/](systemd/) for unit files and install instructions:

| Service | Port | What it does |
|---|---|---|
| `dashboard` | `8001` | `kubectl proxy` → minikube Kubernetes dashboard |
| `jupyterlab` | `8888` | JupyterLab (pyNeMo environment) |
| `mlflow-portfwd` | `5000` | `kubectl port-forward` → `svc/mlflow-tracking` in minikube |

All ports bind to `0.0.0.0` (mlflow) or `127.0.0.1` (dashboard, jupyterlab). Access from your laptop via SSH tunnel:

```sh
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 <user>@spark-79b7.local
```

## Host setup

`bootstrap.sh` in this directory contains the DGX host configuration script.
