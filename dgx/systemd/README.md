# dgx/systemd

Systemd user services for the [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/). These start automatically on boot (via linger) and on login — no manual intervention needed after a reboot.

AGX Orin runs the identical set of services — see [../../agx/systemd/README.md](../../agx/systemd/README.md) for AGX-specific tunnel port assignments.

| Service                     | Port        | Purpose                                                                                                                                                             |
| --------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `mlabs-runner.service`      | —           | GHA runner container — starts on boot, deregisters on stop. PATs loaded from `~/.config/systemd/user/mlabs-runner.env` (created by `install.sh`).                  |
| `dashboard.service`         | `8001`      | `kubectl proxy` for the k3s Kubernetes dashboard                                                                                                                    |
| `jupyterlab.service`        | `8888`      | [JupyterLab](https://jupyter.org) (pyJLab environment) — no token required                                                                                          |
| `mlflow-portfwd.service`    | `5000`      | `kubectl port-forward` — proxies `svc/mlflow-tracking` ([MLflow](https://mlflow.org)) in the `mlflow-system` namespace                                              |
| `kubeflow-portfwd.service`  | `8080`      | `kubectl port-forward` — proxies `svc/ml-pipeline-ui` ([Kubeflow Pipelines](https://www.kubeflow.org/)) in the `kubeflow` namespace                                 |
| `kfp-api-portfwd.service`   | `8890`      | `kubectl port-forward` — proxies `svc/ml-pipeline:8888` (KFP REST API) in the `kubeflow` namespace                                                                  |
| `nemo-portfwd.service`      | `8082`      | `kubectl port-forward` — proxies `svc/ingress-nginx-controller:80` in `ingress-nginx`; exposes all NeMo ingress routes (`nemo.test`, `nim.test`, `data-store.test`) |
| `qdrant-portfwd.service`    | `6333/6334` | `kubectl port-forward` — proxies `svc/qdrant` ([Qdrant](https://qdrant.tech)) in the `qdrant-system` namespace; exposes REST (6333) and gRPC (6334)                 |
| `postgres-portfwd.service`  | `5432`      | `kubectl port-forward` — proxies `svc/postgres` ([Postgres](https://www.postgresql.org/)) in the `postgres-system` namespace                                       |
| `nsight-portfwd.service`    | `8889` + `13001` | `kubectl port-forward` — `8889`→`svc/nsight-operator-gateway:8888` (Nsight Operator UI / SPA) and `13001`→`svc/nsight-operator-coordinator:80` (REST API used by `~/bin/nsight-export-report`). The SPA endpoint does **not** serve the REST API. |
| `openwebui-portfwd.service` | `8084`      | `kubectl port-forward` — proxies `svc/openwebui:8080` in the `openwebui` namespace; [Open WebUI](https://github.com/open-webui/open-webui) chat interface over Ollama / vLLM |

k3s itself runs as a system-level service (`sudo systemctl start k3s` / `sudo systemctl stop k3s`) — not a user unit. The port-forward services above start after k3s is ready.

`dashboard.service` and `mlflow-portfwd.service` bind to `127.0.0.1` only; the port-forward
services (`mlflow-portfwd`, `kubeflow-portfwd`, `nemo-portfwd`, `qdrant-portfwd`, `postgres-portfwd`) bind to `0.0.0.0` so the runner container can
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
    -L 5432:localhost:5432 \
    -L 8084:localhost:8084 \
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

`install.sh` creates `~/.config/systemd/user/mlabs-runner.env` on first run, seeding
`GITHUB_ORG_ADMIN_PAT`, `GITHUB_ORG_GHCR_PAT`, and `HF_TOKEN` from the current shell
environment. If those vars are not set, edit the file manually before starting the service:

```sh
vi ~/.config/systemd/user/mlabs-runner.env
systemctl --user restart mlabs-runner
```

## Uninstall

Stops and disables all port-forward services and removes their unit files.
Does not disable linger or stop k3s (k3s is a system service, not a user unit).

```sh
./uninstall.sh
```

## Shutdown

Gracefully stops every DGX service (in dependency order, including the system-level `k3s` and
`ollama` services `uninstall.sh` deliberately leaves alone) and powers off the host. Warns about
in-flight GHA jobs, running KFP/Argo workflows, and active GPU processes before it touches
anything, and requires typing `SHUTDOWN` to proceed.

```sh
./shutdown.sh            # interactive
./shutdown.sh --dry-run  # show the plan, stop nothing, don't power off
./shutdown.sh --yes      # skip the typed confirmation
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
journalctl --user -u mlabs-runner -f
journalctl --user -u dashboard -f
journalctl --user -u jupyterlab -f
journalctl --user -u mlflow-portfwd -f
journalctl --user -u kubeflow-portfwd -f
journalctl --user -u kfp-api-portfwd -f
journalctl --user -u nemo-portfwd -f
journalctl --user -u qdrant-portfwd -f
journalctl --user -u postgres-portfwd -f
journalctl --user -u nsight-portfwd -f
journalctl --user -u openwebui-portfwd -f
```

## Notes

- k3s is a system-level service managed by the root systemd instance. The user-level port-forward
  services connect to k3s via `~/.kube/config` (written by the K3s Install workflow). k3s starts
  automatically on boot via `systemctl enable k3s` (set during install).
- `mlflow-portfwd.service`, `kubeflow-portfwd.service`, `kfp-api-portfwd.service`,
  `qdrant-portfwd.service`, and `postgres-portfwd.service` wait for their respective services to
  have a ready endpoint before starting the port-forward, so they won't crash-loop on boot if
  pods are still coming up. If the workload is not deployed they hit `StartLimitBurst` quickly and
  stop retrying — expected behavior when MLflow, Kubeflow, Qdrant, or Postgres is not installed.
- Services are user-scoped (`WantedBy=default.target`) and do not require `sudo`.
- Linger (`loginctl enable-linger`) is set by `install.sh` — this is what makes the services
  start on boot rather than only on interactive login.

## References

| Technology                                      | GitHub                                                            | Docs                                                        |
| ----------------------------------------------- | ----------------------------------------------------------------- | ----------------------------------------------------------- |
| [k3s](https://k3s.io/)                          | [k3s-io/k3s](https://github.com/k3s-io/k3s)                       | [docs](https://docs.k3s.io/)                                |
| [JupyterLab](https://jupyter.org)               | [jupyterlab/jupyterlab](https://github.com/jupyterlab/jupyterlab) | [docs](https://jupyterlab.readthedocs.io/)                  |
| [MLflow](https://mlflow.org)                    | [mlflow/mlflow](https://github.com/mlflow/mlflow)                 | [docs](https://mlflow.org/docs/latest/index.html)           |
| [Qdrant](https://qdrant.tech)                   | [qdrant/qdrant](https://github.com/qdrant/qdrant)                 | [docs](https://qdrant.tech/documentation/)                  |
| [PostgreSQL](https://www.postgresql.org/)       | [postgres/postgres](https://github.com/postgres/postgres)         | [docs](https://www.postgresql.org/docs/)                    |
| [Kubeflow Pipelines](https://www.kubeflow.org/) | [kubeflow/pipelines](https://github.com/kubeflow/pipelines)       | [docs](https://www.kubeflow.org/docs/components/pipelines/) |
