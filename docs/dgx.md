# DGX Operations

DGX Spark runs the local AI stack: k3s, NeMo Microservices, MLflow, Qdrant, NIM,
and Ollama. The runner label is `dgx`.

AGX Orin runs the same stack minus NIM (no arm64 NIM images exist) — see
[agx.md](agx.md) for AGX-specific details and SSH tunnel port assignments.

## Host prerequisites

These tools must be present on the host before any deploy workflow runs:

- **kubectl** — installed automatically by k3s at `/usr/local/bin/kubectl`
- **helm** — installed automatically by `scripts/ubuntu/install-k3s.sh`

Run `K3s Install` workflow (or `K3s Bootstrap`) to set up both. The mlabs-runner
container is a thin SSH proxy — it does not mount host paths and expects kubectl/helm
to be on the host.

## Access

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
    -L 8889:localhost:8889 \
    -L 8084:localhost:8084 \
    $USER@spark-79b7.local
```

| Local port | Service                                 |
| ---------- | --------------------------------------- |
| `8001`     | Kubernetes dashboard proxy              |
| `8888`     | JupyterLab                              |
| `5000`     | MLflow                                  |
| `8080`     | Kubeflow Pipelines UI                   |
| `8082`     | NeMo / NIM / Data Store ingress         |
| `8890`     | KFP REST API                            |
| `11434`    | Ollama API                              |
| `6333`     | Qdrant REST API + web UI (`/dashboard`) |
| `6334`     | Qdrant gRPC                             |
| `8889`     | Nsight Operator UI                      |
| `8084`     | Open WebUI chat (Ollama / NIM / vLLM)   |

See [../dgx/README.md](../dgx/README.md) and
[../dgx/systemd/README.md](../dgx/systemd/README.md).

## JupyterLab

JupyterLab runs on the DGX at port `8888` via the `jupyterlab.service` systemd unit. Access it through the SSH tunnel at [http://localhost:8888](http://localhost:8888).

Full environment details, installed packages, and project workflow tips: [../dgx/jupyterlab/README.md](../dgx/jupyterlab/README.md).

Project repos live at `~/git-miramar-labs-org/projects/<name>` on the DGX. Each project README has an **Open in JupyterLab** badge that links directly to `http://localhost:8888/lab/tree/git-miramar-labs-org/projects/<name>/notebook.ipynb` — click it with an SSH tunnel active.

### Git integration

`jupyterlab-git` (v0.53.0) is installed and active. It adds a **Git panel** in the left sidebar with full branch switching, staging, committing, and diff viewing — no terminal needed for routine git operations.

To switch branches from JupyterLab without the extension, open a terminal (`File → New → Terminal`) and run:

```sh
cd ~/git-miramar-labs-org/projects/<project-name>
git checkout <branch-name>
```

JupyterLab sees the filesystem live — files update immediately after a branch switch.

### Working on a project

1. Click the **Open in JupyterLab** badge in the project README
2. The notebook opens at `http://localhost:8888/lab/tree/git-miramar-labs-org/projects/<name>/notebook.ipynb`
3. Use the Git panel or terminal to switch to the relevant branch if needed
4. Edit and run cells — MLflow at `http://localhost:5000` tracks experiments automatically; Qdrant at `http://localhost:6333` is available as a vector store

## k3s

DGX k3s hosts NeMo Microservices, MLflow, MinIO, Qdrant, KFP, and NIM deployments.

Lifecycle workflows:

```text
Actions -> K3s Install
Actions -> K3s Uninstall
```

Stack deployment order:

```text
K3s Install -> NeMo Deploy -> MLflow Deploy -> Qdrant Deploy -> Kubeflow Deploy -> NIM Deploy (or Ollama Deploy)
```

See [../dgx/minikube/](../dgx/minikube/) for legacy manifests (retained for reference).

## MLflow

MLflow runs in k3s namespace `mlflow-system` behind
`svc/mlflow-tracking`. The `mlflow-portfwd.service` forwards port `5000`.

```text
Actions -> MLflow Deploy
Actions -> MLflow Undeploy
```

NeMo must be deployed before MLflow because MLflow uses NeMo's postgres backend.

The deploy workflow runs a smoke test after deployment (`dgx/minikube/mlflow/verify-mlflow-endpoints.sh`):
- `GET /health` — tracking server up
- `GET /api/2.0/mlflow/experiments/list` — PostgreSQL backend reachable

## Kubeflow Pipelines

Kubeflow Pipelines runs in k3s namespace `kubeflow`. Two systemd services
expose it over SSH tunnels:

- `kubeflow-portfwd.service` (port `8080`) — KFP UI (`svc/ml-pipeline-ui:80`)
- `kfp-api-portfwd.service` (port `8890`) — KFP REST API (`svc/ml-pipeline:8888`)

After deploying, restart both services and open `http://localhost:8080` (UI) or
hit `http://localhost:8890/apis/v2beta1/healthz` (API) through the SSH tunnel.

```text
Actions -> Build KFP arm64 Images    (once per version; covers all 13 arm64 images including MLMD)
Actions -> Kubeflow Undeploy         (clean slate before deploy)
Actions -> Kubeflow Deploy
```

Kubeflow is independent of NeMo and MLflow — it can be deployed on a fresh
k3s cluster without any other workloads.

The deploy workflow runs a smoke test after deployment (`dgx/minikube/kubeflow/verify-kfp-endpoints.sh`):
- `GET /` on `svc/ml-pipeline-ui:80` — UI serving
- `GET /apis/v2beta1/healthz` on `svc/ml-pipeline:8888` — API server healthy

### arm64 images (GHCR)

All 13 KFP images are built natively on the DGX. Full image catalog and patch
details: [../dgx/minikube/kubeflow/arm64/README.md](../dgx/minikube/kubeflow/arm64/README.md)

## Qdrant

Qdrant vector database runs in k3s namespace `qdrant-system` behind
`svc/qdrant`. The `qdrant-portfwd.service` forwards REST (port `6333`) and
gRPC (port `6334`) simultaneously. No auth configured — local dev only.

```text
Actions -> Qdrant Deploy
Actions -> Qdrant Undeploy
```

Qdrant is independent of NeMo and MLflow — it can be deployed on a fresh k3s cluster. Conventional position: after MLflow Deploy, before Kubeflow Deploy.

The deploy workflow runs a smoke test after deployment (`dgx/minikube/qdrant/verify-qdrant-endpoints.sh`):
- `GET /health` — server up
- `GET /collections` — API reachable

Web UI (with SSH tunnel active): [http://localhost:6333/dashboard](http://localhost:6333/dashboard)

Python client:

```python
from qdrant_client import QdrantClient
client = QdrantClient(url="http://localhost:6333")
```

## Ollama

Ollama runs natively on the DGX host, not inside k3s. The platform
reserves ~28 GB for OS/services, leaving ~100 GB for models; no deployed model
may exceed this budget.

```text
Actions -> Ollama Update      (installs/upgrades binary; writes OLLAMA_VERSION)
Actions -> Ollama Deploy      (auto-undeploys existing model first; rollback on failure)
Actions -> Ollama Undeploy
```

Deploy auto-undeploys any currently loaded Ollama model before pulling the new
one, so you never need to manually undeploy first. If the deploy fails
(OOM, pull error, etc.) the workflow rolls back: unloads any partial load and
clears `CURRENT_OLLAMA_MODEL`. Fails if a NIM is still loaded.

See [../dgx/ollama/README.md](../dgx/ollama/README.md) for the local model
catalog. Browse available models: [ollama.com/library](https://ollama.com/library).

## NeMo Microservices

NeMo runs in namespace `nemo-microservices` and provides the deployment API used
by NIM. It requires `NVIDIA_API_KEY`.

```text
Actions -> NeMo Deploy
Actions -> NeMo Undeploy
```

Deploy installs NeMo and Volcano. Undeploy removes NeMo, Volcano, DNS entries,
and postgres PVCs to avoid password drift on redeploy.

## NIM

NIMs are deployed through the NeMo deployment API and serve at
`http://nim.test/v1`. NIM Deploy swaps any currently running NIM first and
rolls back (undeploys + clears `CURRENT_NIM_MODEL`) on failure.

```text
Actions -> NIM Deploy
Actions -> NIM Undeploy
```

Common DGX Spark models:

| Model                 | org      | nim_name                               |
| --------------------- | -------- | -------------------------------------- |
| Nemotron Nano 9B v2   | `nvidia` | `nvidia-nemotron-nano-9b-v2-dgx-spark` |
| Llama 3.1 8B Instruct | `meta`   | `llama-3.1-8b-instruct-dgx-spark`      |

After deployment:

```sh
curl http://nim.test/v1/models
```

Available DGX Spark NIMs: [NVIDIA NIM supported models](https://docs.nvidia.com/nim/large-language-models/latest/supported-models.html) · [NGC DGX Spark containers](https://catalog.ngc.nvidia.com/orgs/nim/containers?filters=&orderBy=scoreDESC&query=dgx-spark).

## GPU Profiling

KFP pipeline projects profile GPU stages using the **NVIDIA Nsight Operator**, which injects
`nsys` tooling at pod creation time via a Kubernetes mutating webhook. No specialised Docker
images or embedded `nsys` wrappers are needed — profiling is controlled entirely by pod labels.

Deploy the operator via the **Nsight Operator Deploy** workflow in miramar-platform-gcp, then add
`kubernetes.add_pod_label(task, "nvidia-nsight-profile", "enabled")` to any KFP stage you want
profiled. Reports land in `~/shared/nsight/<project>/<run-id>/` as before.

---

### Host prerequisites (one-time per DGX install, survives reboots)

#### 1. Allow non-root CUPTI access

By default, NVIDIA drivers on DGX restrict hardware performance counter access to root.
KFP pods run as UID 65532 — without this fix, `nsys` silently captures zero CUDA kernels and
CUPTI returns `CUPTI_ERROR_INVALID_DEVICE`.

```bash
# Check current state (1 = restricted, 0 = open)
cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly

# Write the modprobe option
sudo tee /etc/modprobe.d/nvidia.conf <<'EOF'
# Allow non-root CUPTI/Nsight profiling (required for KFP pod UID 65532)
options nvidia NVreg_RestrictProfilingToAdminUsers=0
EOF

# Reboot to apply (cannot hot-reload while the GPU is active)
sudo reboot
```

After reboot, verify:

```bash
cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly
# Expected: RmProfilingAdminOnly: 0
```

This setting persists across reboots via `/etc/modprobe.d/nvidia.conf`. It does not persist across
driver reinstalls — re-verify after any NVIDIA driver upgrade.

### Infrastructure (one-time per fresh k3s deploy)

Profiling uses a dedicated PVC (`nsight-reports`) mounted at `/nsight-reports/` inside each GPU
component pod, backed by a k3s hostPath PV pointing directly at the DGX host. This is created
automatically by the **Kubeflow Deploy** workflow, but the steps are documented here for reference
or manual recovery.

```bash
# 1. Create host directory with world-writable permissions.
#    IMPORTANT: must be 777 — k3s pods run as non-root UIDs and cannot write
#    into a 755 dir owned by another user.
mkdir -p ~/shared/nsight
chmod 777 ~/shared/nsight

# 2. Apply the PV and PVC.
#    k3s hostPath PVs reference the actual host path directly — no mount daemon needed.
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nsight-reports
spec:
  capacity:
    storage: 50Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: ${HOME}/shared/nsight
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nsight-reports
  namespace: kubeflow
spec:
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 50Gi
  storageClassName: ""
  volumeName: nsight-reports
EOF
```

Verify:

```bash
ls ~/shared/nsight
kubectl get pvc nsight-reports -n kubeflow
```

---

### Output location

```
~/shared/nsight/
  <project-name>/
    <run-id>/
      baseline-eval/
        profile.nsys-rep    # Nsight Systems report
        nsys_stats.txt      # text summary (cuda_gpu_kern_sum, cuda_api_sum, etc.)
      fine-tune/
        profile.nsys-rep
        nsys_stats.txt
      post-finetune-eval/
        profile.nsys-rep
        nsys_stats.txt
      safety-eval/
        profile.nsys-rep
        nsys_stats.txt
```

---

### Interpreting reports

Use the `/nsight-interpret` skill to send `nsys stats` output to an LLM for bottleneck analysis:

```bash
/nsight-interpret run-032               # auto-locate report by run name
/nsight-interpret run-032 --ollama llama3  # use local model instead of Claude
```

Or open the desktop GUI directly:

```bash
nsys-ui ~/shared/nsight/<project>/<run-id>/baseline-eval/profile.nsys-rep
```

---

### Troubleshooting

**PVC reads as empty inside a pod**

k3s hostPath PVs are stable across reboots — no mount daemon to restart. If the directory
appears empty inside a pod, verify the host path exists and has correct permissions:

```bash
ls -la ~/shared/nsight
# Expected: drwxrwxrwx  (777)
```

If missing, re-create: `mkdir -p ~/shared/nsight && chmod 777 ~/shared/nsight`.
