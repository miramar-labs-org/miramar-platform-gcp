# agx/systemd

Systemd user services for the [NVIDIA Jetson AGX Orin](https://www.nvidia.com/en-us/autonomous-machines/embedded-systems/jetson-orin/). Identical stack to the DGX Spark — same service names, same host ports. Run the same `install.sh` / `uninstall.sh` scripts from this directory on the AGX host.

| Service | Host port | Purpose |
|---|---|---|
| `dashboard.service` | `8001` | `kubectl proxy` for the Kubernetes dashboard |
| `jupyterlab.service` | `8888` | JupyterLab (pyJLab environment) |
| `mlflow-portfwd.service` | `5000` | `kubectl port-forward svc/mlflow-tracking` (`mlflow-system`) |
| `kubeflow-portfwd.service` | `8080` | `kubectl port-forward svc/ml-pipeline-ui` (`kubeflow`) |
| `kfp-api-portfwd.service` | `8890` | `kubectl port-forward svc/ml-pipeline:8888` (KFP REST API) |
| `nemo-portfwd.service` | `8082` | `kubectl port-forward svc/ingress-nginx-controller:80` (`nemo.test`, `nim.test`, `data-store.test`) |
| `qdrant-portfwd.service` | `6333/6334` | `kubectl port-forward svc/qdrant 6333:6333 6334:6334` (`qdrant-system`) |

## SSH tunnel from laptop

AGX services use offset local ports to allow the DGX and AGX tunnels to run simultaneously:

```sh
ssh -L 8002:localhost:8001 \
    -L 8887:localhost:8888 \
    -L 5001:localhost:5000 \
    -L 8081:localhost:8080 \
    -L 8083:localhost:8082 \
    -L 8891:localhost:8890 \
    -L 11435:localhost:11434 \
    -L 6335:localhost:6333 \
    -L 6336:localhost:6334 \
    aaron@orin.local
```

| Local port | Service URL |
|---|---|
| `5001` | http://localhost:5001 — MLflow |
| `6335` | http://localhost:6335/dashboard — Qdrant REST API |
| `6336` | gRPC — Qdrant gRPC |
| `8081` | http://localhost:8081 — KFP UI |
| `8083` | http://nemo.test:8083 — NeMo / NIM (add `127.0.0.1 nemo.test nim.test` to laptop `/etc/hosts`) |
| `8887` | http://localhost:8887 — JupyterLab |
| `8891` | http://localhost:8891/apis/v2beta1/healthz — KFP REST API |
| `11435` | http://localhost:11435 — Ollama API |

## Install

```sh
# On the AGX host:
cd ~/git-miramar-labs-org/miramar-platform-gcp
./agx/systemd/install.sh
```

The service unit files are symlinked from `dgx/systemd/` — the AGX stack is identical. `install.sh` copies them to `~/.config/systemd/user/`, enables linger, and starts all services.

## Manage services

```sh
systemctl --user status  k3s
systemctl --user restart mlflow-portfwd qdrant-portfwd kubeflow-portfwd kfp-api-portfwd nemo-portfwd
journalctl --user -u mlflow-portfwd -f
journalctl --user -u qdrant-portfwd -f
```

See [../dgx/systemd/README.md](../dgx/systemd/README.md) for full notes on service behaviour and dependencies.
