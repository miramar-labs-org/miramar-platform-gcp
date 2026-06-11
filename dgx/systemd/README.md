# dgx/systemd

Systemd user services for the [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/). These start automatically on boot (via linger) and on login — no manual intervention needed after a reboot.

AGX Orin runs the identical set of services — see [../../agx/systemd/README.md](../../agx/systemd/README.md) for AGX-specific tunnel port assignments.

| Service | Port | Purpose |
|---|---|---|
| `dashboard.service` | `8001` | `kubectl proxy` for the k3s Kubernetes dashboard |
| `jupyterlab.service` | `8888` | [JupyterLab](https://jupyter.org) (pyJLab environment) — no token required |
| `mlflow-portfwd.service` | `5000` | `kubectl port-forward` — proxies `svc/mlflow-tracking` ([MLflow](https://mlflow.org)) in the `mlflow-system` namespace |
| `kubeflow-portfwd.service` | `8080` | `kubectl port-forward` — proxies `svc/ml-pipeline-ui` ([Kubeflow Pipelines](https://www.kubeflow.org/)) in the `kubeflow` namespace |
| `kfp-api-portfwd.service` | `8890` | `kubectl port-forward` — proxies `svc/ml-pipeline:8888` (KFP REST API) in the `kubeflow` namespace |
| `nemo-portfwd.service` | `8082` | `kubectl port-forward` — proxies `svc/ingress-nginx-controller:80` in `ingress-nginx`; exposes all NeMo ingress routes (`nemo.test`, `nim.test`, `data-store.test`) |
| `qdrant-portfwd.service` | `6333/6334` | `kubectl port-forward` — proxies `svc/qdrant` ([Qdrant](https://qdrant.tech)) in the `qdrant-system` namespace; exposes REST (6333) and gRPC (6334) |

k3s itself runs as a system-level service (`sudo systemctl start k3s` / `sudo systemctl stop k3s`) — not a user unit. The port-forward services above start after k3s is ready.

`dashboard.service` and `mlflow-portfwd.service` bind to `127.0.0.1` only; the port-forward
services (`mlflow-portfwd`, `kubeflow-portfwd`, `nemo-portfwd`, `qdrant-portfwd`) bind to `0.0.0.0` so the runner container can
reach them. Access from a laptop via SSH tunnel:

```sh
ssh -L 8001:localhost:8001 \
    -L 8888:localhost:8888 \
    -L 5000:localhost:5000 \
    -L 8080:localhost:8080 \
    -L 8082:localhost:8082 \
    -L 8890:localhost:8890 \
    -L 11434:localhost:11434 \
    -L 6333:localhost:6333 \
    -L 6334:localhost:6334 \
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
safe to use as an update mechanism. k3s must be running before port-forward services start;
verify with `sudo systemctl status k3s` if any port-forward fails to connect.

## Uninstall

Stops and disables all port-forward services and removes their unit files.
Does not disable linger or stop k3s (k3s is a system service, not a user unit).

```sh
./uninstall.sh
```

## Managing individual services

```sh
# k3s is a system service (not a user unit)
sudo systemctl status k3s
sudo systemctl start  k3s
sudo systemctl stop   k3s

# User-level port-forward and UI services
systemctl --user status  dashboard
systemctl --user restart dashboard

# Follow logs
journalctl --user -u dashboard -f
journalctl --user -u jupyterlab -f
journalctl --user -u mlflow-portfwd -f
journalctl --user -u kubeflow-portfwd -f
journalctl --user -u kfp-api-portfwd -f
journalctl --user -u nemo-portfwd -f
journalctl --user -u qdrant-portfwd -f
```

## Notes

- k3s is a system-level service managed by the root systemd instance. The user-level port-forward
  services connect to k3s via `~/.kube/config` (written by the K3s Install workflow). k3s starts
  automatically on boot via `systemctl enable k3s` (set during install).
- `mlflow-portfwd.service`, `kubeflow-portfwd.service`, `kfp-api-portfwd.service`, and
  `qdrant-portfwd.service` wait for their respective services to have a ready endpoint before
  starting the port-forward, so they won't crash-loop on boot if pods are still coming up. If the
  workload is not deployed they hit `StartLimitBurst` quickly and stop retrying — expected
  behavior when MLflow, Kubeflow, or Qdrant is not installed.
- Services are user-scoped (`WantedBy=default.target`) and do not require `sudo`.
- Linger (`loginctl enable-linger`) is set by `install.sh` — this is what makes the services
  start on boot rather than only on interactive login.

## References

| Technology | GitHub | Docs |
|---|---|---|
| [k3s](https://k3s.io/) | [k3s-io/k3s](https://github.com/k3s-io/k3s) | [docs](https://docs.k3s.io/) |
| [JupyterLab](https://jupyter.org) | [jupyterlab/jupyterlab](https://github.com/jupyterlab/jupyterlab) | [docs](https://jupyterlab.readthedocs.io/) |
| [MLflow](https://mlflow.org) | [mlflow/mlflow](https://github.com/mlflow/mlflow) | [docs](https://mlflow.org/docs/latest/index.html) |
| [Qdrant](https://qdrant.tech) | [qdrant/qdrant](https://github.com/qdrant/qdrant) | [docs](https://qdrant.tech/documentation/) |
| [Kubeflow Pipelines](https://www.kubeflow.org/) | [kubeflow/pipelines](https://github.com/kubeflow/pipelines) | [docs](https://www.kubeflow.org/docs/components/pipelines/) |
