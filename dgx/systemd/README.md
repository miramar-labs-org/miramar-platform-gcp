# dgx/systemd

Systemd user services for the DGX Spark. These start automatically on boot (via linger) and on
login — no manual intervention needed after a reboot.

| Service | Port | Purpose |
|---|---|---|
| `minikube.service` | — | Starts/stops the minikube cluster; other services depend on it |
| `dashboard.service` | `8001` | `kubectl proxy` for the minikube Kubernetes dashboard |
| `jupyterlab.service` | `8888` | JupyterLab (pyNeMo environment) |
| `mlflow-portfwd.service` | `5000` | `kubectl port-forward` — proxies `svc/mlflow-tracking` in the `mlflow-system` namespace |

`dashboard.service` and `mlflow-portfwd.service` bind to `127.0.0.1` only (`mlflow-portfwd` binds
to `0.0.0.0` so the runner container can reach it). Access from a laptop via SSH tunnel:

```sh
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 <user>@spark-79b7.local
```

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
```

## Notes

- `minikube.service` is `Type=oneshot RemainAfterExit` — systemd considers it active once
  `minikube start` returns, and runs `minikube stop` on shutdown. `TimeoutStartSec=300` gives it
  up to 5 minutes to start (first boot after a reboot may pull images).
- `dashboard.service` and `mlflow-portfwd.service` have `After=minikube.service` so systemd
  starts minikube first and stops it last on shutdown.
- `mlflow-portfwd.service` waits for `svc/mlflow-tracking` to have a ready endpoint before
  starting the port-forward, so it won't crash-loop on boot if MLflow pods are still coming up.
- Services are user-scoped (`WantedBy=default.target`) and do not require `sudo`.
- Linger (`loginctl enable-linger`) is set by `install.sh` — this is what makes the services
  start on boot rather than only on interactive login.
