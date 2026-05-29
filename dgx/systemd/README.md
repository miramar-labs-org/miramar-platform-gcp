# dgx/systemd

Systemd user services for the [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/). These start automatically on boot (via linger) and on login — no manual intervention needed after a reboot.

| Service | Port | Purpose |
|---|---|---|
| `minikube.service` | — | Starts/stops the [minikube](https://minikube.sigs.k8s.io/) cluster; other services depend on it |
| `dashboard.service` | `8001` | `kubectl proxy` for the minikube Kubernetes dashboard |
| `jupyterlab.service` | `8888` | [JupyterLab](https://jupyter.org) (pyNeMo environment) — no token required |
| `mlflow-portfwd.service` | `5000` | `kubectl port-forward` — proxies `svc/mlflow-tracking` ([MLflow](https://mlflow.org)) in the `mlflow-system` namespace |
| `kubeflow-portfwd.service` | `8080` | `kubectl port-forward` — proxies `svc/ml-pipeline-ui` ([Kubeflow Pipelines](https://www.kubeflow.org/)) in the `kubeflow` namespace |
| `nemo-portfwd.service` | `8082` | `kubectl port-forward` — proxies `svc/ingress-nginx-controller:80` in `ingress-nginx`; exposes all NeMo ingress routes (`nemo.test`, `nim.test`, `data-store.test`) |

`dashboard.service` and `mlflow-portfwd.service` bind to `127.0.0.1` only; the port-forward
services (`mlflow-portfwd`, `kubeflow-portfwd`) bind to `0.0.0.0` so the runner container can
reach them. Access from a laptop via SSH tunnel:

```sh
ssh -L 8001:localhost:8001 \
    -L 8888:localhost:8888 \
    -L 5000:localhost:5000 \
    -L 8080:localhost:8080 \
    -L 8082:localhost:8082 \
    <user>@spark-79b7.local
```

To reach NeMo endpoints via the tunnel, add these entries to your **laptop's** `/etc/hosts`:

```
127.0.0.1 nemo.test nim.test data-store.test
```

Then access NeMo APIs on the standard port (e.g. `http://nemo.test:8082/v1/namespaces`).

## Install

Copies the service files to `~/.config/systemd/user/`, enables linger (so services start on boot
without requiring a login session), reloads systemd, then enables and starts all services.

```sh
./install.sh
```

Re-running install applies any changes to the service files and restarts the affected services —
safe to use as an update mechanism. `minikube.service` starts first because the others depend on
it; expect ~30–60 s on first boot while minikube pulls its Docker image.

## Uninstall

Stops and disables all services (dependents first, then minikube) and removes their unit files.
Does not disable linger.

```sh
./uninstall.sh
```

## Managing individual services

```sh
systemctl --user status  minikube
systemctl --user restart minikube
systemctl --user stop    minikube
systemctl --user start   minikube

systemctl --user status  dashboard
systemctl --user restart dashboard

# Follow logs
journalctl --user -u minikube -f
journalctl --user -u dashboard -f
journalctl --user -u jupyterlab -f
journalctl --user -u mlflow-portfwd -f
journalctl --user -u kubeflow-portfwd -f
journalctl --user -u nemo-portfwd -f
```

## Notes

- `minikube.service` is `Type=oneshot RemainAfterExit` — systemd considers it active once
  `minikube start` returns, and runs `minikube stop` on shutdown. `TimeoutStartSec=300` gives it
  up to 5 minutes to start (first boot after a reboot may pull images).
- `dashboard.service` and `mlflow-portfwd.service` have `After=minikube.service` so systemd
  starts minikube first and stops it last on shutdown.
- `mlflow-portfwd.service` and `kubeflow-portfwd.service` wait for their respective services to
  have a ready endpoint before starting the port-forward, so they won't crash-loop on boot if pods
  are still coming up. If the workload is not deployed they hit `StartLimitBurst=3` quickly and
  stop retrying — expected behavior when MLflow or Kubeflow is not installed.
- Services are user-scoped (`WantedBy=default.target`) and do not require `sudo`.
- Linger (`loginctl enable-linger`) is set by `install.sh` — this is what makes the services
  start on boot rather than only on interactive login.

## References

| Technology | GitHub | Docs |
|---|---|---|
| [minikube](https://minikube.sigs.k8s.io/) | [kubernetes/minikube](https://github.com/kubernetes/minikube) | [docs](https://minikube.sigs.k8s.io/docs/) |
| [JupyterLab](https://jupyter.org) | [jupyterlab/jupyterlab](https://github.com/jupyterlab/jupyterlab) | [docs](https://jupyterlab.readthedocs.io/) |
| [MLflow](https://mlflow.org) | [mlflow/mlflow](https://github.com/mlflow/mlflow) | [docs](https://mlflow.org/docs/latest/index.html) |
| [Kubeflow Pipelines](https://www.kubeflow.org/) | [kubeflow/pipelines](https://github.com/kubeflow/pipelines) | [docs](https://www.kubeflow.org/docs/components/pipelines/) |
