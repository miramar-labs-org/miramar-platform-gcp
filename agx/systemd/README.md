# agx/systemd

Systemd user services for the [NVIDIA Jetson AGX Orin](https://www.nvidia.com/en-us/autonomous-machines/embedded-systems/jetson-orin/). Unit files live in `dgx/systemd/` and are shared with the DGX — `install.sh` copies the relevant subset here. Run `install.sh` / `uninstall.sh` from this directory on the AGX host.

AGX installs a subset of the DGX services (`mlabs-runner`, `dashboard`, `jupyterlab`, `kubeflow-portfwd`, `kfp-api-portfwd`, `nsight-portfwd`). MLflow, Qdrant, and NeMo port-forwards are omitted — AGX does not run those stacks.

| Service                    | Host port   | Purpose                                                                     |
| -------------------------- | ----------- | --------------------------------------------------------------------------- |
| `mlabs-runner.service`     | —           | GHA runner container (persistent across reboots; PATs from `mlabs-runner.env`) |
| `dashboard.service`        | `8001`      | `kubectl proxy` for the Kubernetes dashboard                                |
| `jupyterlab.service`       | `8888`      | JupyterLab (pyJLab environment)                                             |
| `kubeflow-portfwd.service` | `8080`      | `kubectl port-forward svc/ml-pipeline-ui` (`kubeflow`)                      |
| `kfp-api-portfwd.service`  | `8890`      | `kubectl port-forward svc/ml-pipeline:8888` (KFP REST API)                  |
| `nsight-portfwd.service`   | `8889`      | `kubectl port-forward svc/nsight-operator-gateway:8888` (`nsight-operator`) |

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

`install.sh` copies unit files from `dgx/systemd/` to `~/.config/systemd/user/`, enables linger, and starts all services. It also creates `~/.config/systemd/user/mlabs-runner.env` on first run, seeding PATs from the current shell environment. If those vars are not set, edit the file before starting the runner:

```sh
vi ~/.config/systemd/user/mlabs-runner.env
systemctl --user restart mlabs-runner
```

## Manage services

```sh
systemctl --user status k3s
systemctl --user restart mlflow-portfwd qdrant-portfwd kubeflow-portfwd kfp-api-portfwd nemo-portfwd openwebui-portfwd
journalctl --user -u mlflow-portfwd -f
journalctl --user -u openwebui-portfwd -f
```

See [../dgx/systemd/README.md](../dgx/systemd/README.md) for full notes on service behaviour and dependencies.
