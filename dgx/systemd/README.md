# dgx/systemd

Systemd user services for the DGX Spark. These run under the logged-in user (`systemctl --user`) and start automatically on login.

| Service | Port | Purpose |
|---|---|---|
| `dashboard.service` | `8001` | `kubectl proxy` for the minikube Kubernetes dashboard |
| `jupyterlab.service` | `8888` | JupyterLab (pyNeMo environment) |
| `mlflow-portfwd.service` | `5000` | `kubectl port-forward` — proxies `svc/mlflow-tracking` in the `mlflow-system` namespace |

All three bind to `127.0.0.1` only. Access them from your laptop via SSH tunnel:

```sh
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 <user>@spark-79b7.local
```

## Install

Copies the service files to `~/.config/systemd/user/`, reloads systemd, then enables and starts all three services.

```sh
./install.sh
```

Re-running install applies any changes to the service files and restarts the affected services — safe to use as an update mechanism.

## Uninstall

Stops and disables all three services and removes their unit files.

```sh
./uninstall.sh
```

## Managing individual services

```sh
systemctl --user status  dashboard
systemctl --user restart dashboard
systemctl --user stop    dashboard
systemctl --user start   dashboard

# Follow logs
journalctl --user -u dashboard -f
journalctl --user -u jupyterlab -f
journalctl --user -u mlflow-portfwd -f
```

## Notes

- `dashboard.service` uses `--context minikube` explicitly so it always connects to the local minikube cluster, not any GKE context that may be present in kubeconfig.
- `mlflow-portfwd.service` waits for `svc/mlflow-tracking` to have a ready endpoint before starting the port-forward, so it won't crash-loop on boot if minikube is still starting up.
- Services are user-scoped (`WantedBy=default.target`) and do not require `sudo`.
