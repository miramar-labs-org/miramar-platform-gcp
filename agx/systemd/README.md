# agx/systemd

Systemd user services for the [NVIDIA Jetson AGX Orin](https://www.nvidia.com/en-us/autonomous-machines/embedded-systems/jetson-orin/). Identical stack to the DGX Spark — same service names, same host ports. Run `install.sh` / `uninstall.sh` from this directory on the AGX host.

| Service                     | Host port   | Purpose                                                                     |
| --------------------------- | ----------- | --------------------------------------------------------------------------- |
| `dashboard.service`         | `8001`      | `kubectl proxy` for the Kubernetes dashboard                                |
| `jupyterlab.service`        | `8888`      | JupyterLab (pyJLab environment)                                             |
| `mlflow-portfwd.service`    | `5000`      | `kubectl port-forward svc/mlflow-tracking` (`mlflow-system`)                |
| `kubeflow-portfwd.service`  | `8080`      | `kubectl port-forward svc/ml-pipeline-ui` (`kubeflow`)                      |
| `kfp-api-portfwd.service`   | `8890`      | `kubectl port-forward svc/ml-pipeline:8888` (KFP REST API)                  |
| `nemo-portfwd.service`      | `8082`      | `kubectl port-forward svc/ingress-nginx-controller:80` (NeMo / Data Store)  |
| `qdrant-portfwd.service`    | `6333/6334` | `kubectl port-forward svc/qdrant 6333:6333 6334:6334` (REST + gRPC)         |
| `nsight-portfwd.service`    | `8889`      | `kubectl port-forward svc/nsight-operator-gateway:8888` (`nsight-operator`) |
| `openwebui-portfwd.service` | `8084`      | `kubectl port-forward svc/openwebui:8080` (Open WebUI chat)                 |

## SSH tunnel from laptop

AGX services use offset local ports to allow the DGX and AGX tunnels to run simultaneously:

```sh
ssh -L 8002:localhost:8001 \
    -L 8887:localhost:8888 \
    -L 5001:localhost:5000 \
    -L 8081:localhost:8080 \
    -L 8891:localhost:8890 \
    -L 8083:localhost:8082 \
    -L 6335:localhost:6333 \
    -L 6336:localhost:6334 \
    -L 8892:localhost:8889 \
    -L 11435:localhost:11434 \
    -L 8085:localhost:8084 \
    $USER@orin.local
```

| Local port | Service URL                                                                                                              |
| ---------- | ------------------------------------------------------------------------------------------------------------------------ |
| `8002`     | http://localhost:8002/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/ — K8s dashboard |
| `8887`     | http://localhost:8887 — JupyterLab                                                                                       |
| `5001`     | http://localhost:5001 — MLflow                                                                                           |
| `8081`     | http://localhost:8081 — KFP UI                                                                                           |
| `8891`     | http://localhost:8891/apis/v2beta1/healthz — KFP REST API                                                                |
| `8083`     | http://localhost:8083 — NeMo / Data Store ingress                                                                        |
| `6335`     | http://localhost:6335/dashboard — Qdrant REST + web UI                                                                   |
| `8892`     | http://localhost:8892 — Nsight Operator UI                                                                               |
| `11435`    | http://localhost:11435 — Ollama API                                                                                      |
| `8085`     | http://localhost:8085 — Open WebUI                                                                                       |

## Install

```sh
# On the AGX host:
cd ~/git-miramar-labs-org/miramar-platform-gcp
./agx/systemd/install.sh
```

`install.sh` copies the service unit files from `dgx/systemd/` (AGX runs the identical stack on the same host ports) to `~/.config/systemd/user/`, enables linger, and starts all services. The SSH tunnel from the laptop uses offset local ports to allow the DGX and AGX tunnels to run simultaneously.

## Manage services

```sh
systemctl --user status k3s
systemctl --user restart mlflow-portfwd qdrant-portfwd kubeflow-portfwd kfp-api-portfwd nemo-portfwd openwebui-portfwd
journalctl --user -u mlflow-portfwd -f
journalctl --user -u openwebui-portfwd -f
```

See [../dgx/systemd/README.md](../dgx/systemd/README.md) for full notes on service behaviour and dependencies.
