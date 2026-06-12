# agx/systemd

Systemd user services for the [NVIDIA Jetson AGX Orin](https://www.nvidia.com/en-us/autonomous-machines/embedded-systems/jetson-orin/). Identical stack to the DGX Spark — same service names, same host ports. Run `install.sh` / `uninstall.sh` from this directory on the AGX host.

| Service                    | Host port | Purpose                                                                     |
| -------------------------- | --------- | --------------------------------------------------------------------------- |
| `dashboard.service`        | `8001`    | `kubectl proxy` for the Kubernetes dashboard                                |
| `jupyterlab.service`       | `8888`    | JupyterLab (pyJLab environment)                                             |
| `kubeflow-portfwd.service` | `8080`    | `kubectl port-forward svc/ml-pipeline-ui` (`kubeflow`)                      |
| `kfp-api-portfwd.service`  | `8890`    | `kubectl port-forward svc/ml-pipeline:8888` (KFP REST API)                  |
| `nsight-portfwd.service`   | `8889`    | `kubectl port-forward svc/nsight-operator-gateway:8888` (`nsight-operator`) |

> MLflow, Qdrant, and NeMo are not deployed on AGX — `mlflow-portfwd`, `qdrant-portfwd`, and `nemo-portfwd` are excluded.

## SSH tunnel from laptop

AGX services use offset local ports to allow the DGX and AGX tunnels to run simultaneously:

```sh
ssh -L 8002:localhost:8001 \
    -L 8887:localhost:8888 \
    -L 8081:localhost:8080 \
    -L 8891:localhost:8890 \
    -L 8892:localhost:8889 \
    -L 11435:localhost:11434 \
    $USER@orin.local
```

| Local port | Service URL                                                                                                              |
| ---------- | ------------------------------------------------------------------------------------------------------------------------ |
| `8002`     | http://localhost:8002/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/ — K8s dashboard |
| `8081`     | http://localhost:8081 — KFP UI                                                                                           |
| `8887`     | http://localhost:8887 — JupyterLab                                                                                       |
| `8891`     | http://localhost:8891/apis/v2beta1/healthz — KFP REST API                                                                |
| `8892`     | http://localhost:8892 — Nsight Operator UI                                                                               |
| `11435`    | http://localhost:11435 — Ollama API                                                                                      |

## Install

```sh
# On the AGX host:
cd ~/git-miramar-labs-org/miramar-platform-gcp
./agx/systemd/install.sh
```

`install.sh` copies the service unit files from `dgx/systemd/` (AGX runs the identical stack on the same host ports) to `~/.config/systemd/user/`, enables linger, and starts all services. The SSH tunnel from the laptop uses offset local ports to allow the DGX and AGX tunnels to run simultaneously.

## Manage services

```sh
systemctl --user status  k3s
systemctl --user restart mlflow-portfwd qdrant-portfwd kubeflow-portfwd kfp-api-portfwd nemo-portfwd
journalctl --user -u mlflow-portfwd -f
journalctl --user -u qdrant-portfwd -f
```

See [../dgx/systemd/README.md](../dgx/systemd/README.md) for full notes on service behaviour and dependencies.
