# minikube (DGX)

Scripts for managing the minikube cluster on the NVIDIA DGX Spark.

| Script | Purpose |
|---|---|
| `up.sh` | Start minikube, enable dashboard, start kubectl proxy |
| `down.sh` | Stop kubectl proxy and shut down minikube |
| `pause.sh` | Freeze all workloads (preserves cluster state, frees CPU) |
| `resume.sh` | Unfreeze workloads after a pause |

## Usage

### Start

```sh
./up.sh
```

Starts minikube if it is not already running, enables the `dashboard` and `metrics-server` addons, and starts `kubectl proxy` on port `8001` in the background. The proxy log is written to `~/kubectl-proxy.log`. All operations are idempotent — safe to run again if the cluster or proxy is already up.

### Access the dashboard

The proxy only binds to `127.0.0.1`, so open an SSH tunnel from your laptop:

```sh
ssh -L 8001:localhost:8001 <user>@spark-79b7.local
```

Then open the dashboard in your browser:

```
http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/
```

The tunnel (and the proxy on the DGX) persist across shell sessions — you only need to run `up.sh` once after a reboot.

### Stop

```sh
./down.sh
```

Kills the kubectl proxy and runs `minikube stop`. The cluster state is preserved on disk — `up.sh` will bring it back up from the same state.

### Pause / Resume

```sh
./pause.sh   # freeze workloads, keep cluster state
./resume.sh  # unfreeze
```

Pause suspends all containers via `minikube pause` without stopping the cluster. Useful for temporarily freeing CPU/memory when the DGX is needed for a training run. Resume with `./resume.sh` (`minikube unpause`).

> Pause does not stop the kubectl proxy — the proxy process keeps running and the SSH tunnel stays live. The dashboard will show the cluster as paused.

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
