# minikube (DGX)

Scripts for managing the minikube cluster on the NVIDIA DGX Spark.

| Script | Purpose |
|---|---|
| `up.sh` | Start minikube and enable dashboard + metrics-server addons |
| `down.sh` | Shut down minikube |
| `pause.sh` | Freeze all workloads (preserves cluster state, frees CPU) |
| `resume.sh` | Unfreeze workloads after a pause |

The `kubectl proxy` on port `8001` is managed by the systemd service in [../systemd/dashboard.service](../systemd/). It starts automatically and does not need to be managed manually.

## Usage

### Start

```sh
./up.sh
```

Starts minikube if it is not already running and enables the `dashboard` and `metrics-server` addons. Idempotent — safe to run again if the cluster is already up.

### Access the dashboard

The proxy is always running via `dashboard.service`. Open an SSH tunnel from your laptop:

```sh
ssh -L 8001:localhost:8001 <user>@spark-79b7.local
```

Then open the dashboard in your browser:

```
http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/
```

### Stop

```sh
./down.sh
```

Runs `minikube stop`. The cluster state is preserved on disk — `up.sh` will bring it back up from the same state. The `dashboard.service` proxy will reconnect automatically once minikube is started again.

### Pause / Resume

```sh
./pause.sh   # freeze workloads, keep cluster state
./resume.sh  # unfreeze
```

Pause suspends all containers via `minikube pause` without stopping the cluster. Useful for temporarily freeing CPU/memory when the DGX is needed for a training run. Resume with `./resume.sh` (`minikube unpause`).

> The `dashboard.service` proxy keeps running while paused — the SSH tunnel stays live and the dashboard will show the cluster as paused.

## GitHub Secret — `DGX_MINIKUBE_KUBECONFIG`

CI/CD workflows that deploy to minikube need a self-contained kubeconfig stored as an org-level GitHub secret. `kubectl config view --raw` does not embed the certs inline for minikube — you must build the kubeconfig manually:

```sh
cat > /tmp/minikube-embedded.yaml << EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: $(base64 -w0 < /home/aaron/.minikube/ca.crt)
    server: https://192.168.49.2:8443
  name: minikube
contexts:
- context:
    cluster: minikube
    user: minikube
  name: minikube
current-context: minikube
kind: Config
users:
- name: minikube
  user:
    client-certificate-data: $(base64 -w0 < /home/aaron/.minikube/profiles/minikube/client.crt)
    client-key-data: $(base64 -w0 < /home/aaron/.minikube/profiles/minikube/client.key)
EOF

base64 -w0 < /tmp/minikube-embedded.yaml
```

Paste the output into the `DGX_MINIKUBE_KUBECONFIG` org secret at [github.com/organizations/miramar-labs-org/settings/secrets/actions](https://github.com/organizations/miramar-labs-org/settings/secrets/actions).

> The certs are rotated when minikube is deleted and recreated. Re-run this whenever you do a fresh `minikube start` from scratch.
