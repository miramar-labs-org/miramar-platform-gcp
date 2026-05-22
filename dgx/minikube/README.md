# minikube (DGX)

Minikube cluster on the NVIDIA DGX Spark. Lifecycle is managed exclusively via GitHub Actions
workflows — there are no local shell scripts.

| Workflow | Purpose |
|---|---|
| **Minikube Install** | Install binary on host, start cluster, enable addons, update `DGX_MINIKUBE_KUBECONFIG` |
| **Minikube Uninstall** | Delete cluster, purge state, remove binary from host |
| **Minikube Toggle** | Pause or resume workloads (`pause` \| `resume` input) |

## Workloads

| Folder | Contents |
|---|---|
| [nemo/](nemo/) | NeMo Microservices Helm chart install — values, credentials, deployment config |
| [nim/](nim/) | NIM inference scripts — deploy, undeploy, and log tailing |

The `kubectl proxy` on port `8001` is managed by the systemd service in [../systemd/dashboard.service](../systemd/). It starts automatically and does not need to be managed manually.

## Access the dashboard

The proxy is always running via `dashboard.service`. Open an SSH tunnel from your laptop:

```sh
ssh -L 8001:localhost:8001 <user>@spark-79b7.local
```

Then open the dashboard in your browser:

```
http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/
```

## Reinstalling from scratch

To wipe the existing cluster and re-test the setup workflow from a clean state:

```sh
# 1. Delete the cluster and purge all minikube state
minikube delete --all --purge

# 2. Remove the binary from the host
sudo rm -f /usr/local/bin/minikube

# 3. Restart the runner to pick up the /host-bin mount
docker stop mlabs-runner-arm64
./scripts/gha/launch-runner.sh --detach
```

Then trigger the **Minikube Install** workflow from the GitHub Actions UI. It will download the
latest binary onto the host, start a fresh cluster, pin the nvidia-device-plugin, enable addons,
label the node, and update `DGX_MINIKUBE_KUBECONFIG`.

## GitHub Secret — `DGX_MINIKUBE_KUBECONFIG`

The **Minikube Install** workflow updates this secret automatically. If you ever need to regenerate
it manually (e.g. after `minikube delete` without running the workflow):

```sh
kubectl config view --raw --minify --flatten --context=minikube | base64 -w0
```

Paste the output into the `DGX_MINIKUBE_KUBECONFIG` org secret at
[github.com/organizations/miramar-labs-org/settings/secrets/actions](https://github.com/organizations/miramar-labs-org/settings/secrets/actions).

> The certs rotate on every `minikube delete` + recreate — re-run the workflow or the command
> above whenever you do a fresh start from scratch.
