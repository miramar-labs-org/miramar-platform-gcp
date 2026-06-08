# DGX Operations

DGX Spark runs the local AI stack: minikube, NeMo Microservices, MLflow, Qdrant, NIM,
and Ollama. The runner label is `dgx`.

AGX Orin runs the same stack minus NIM (no arm64 NIM images exist) — see
[agx.md](agx.md) for AGX-specific details and SSH tunnel port assignments.

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
    aaron@spark-79b7.local
```

| Local port | Service |
| --- | --- |
| `8001` | Kubernetes dashboard proxy |
| `8888` | JupyterLab |
| `5000` | MLflow |
| `8080` | Kubeflow Pipelines UI |
| `8082` | NeMo / NIM / Data Store ingress |
| `8890` | KFP REST API |
| `11434` | Ollama API |
| `6333` | Qdrant REST API + web UI (`/dashboard`) |
| `6334` | Qdrant gRPC |

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

## minikube

DGX minikube hosts NeMo Microservices, MLflow, MinIO, Qdrant, and NIM deployments.

Lifecycle workflows:

```text
Actions -> Minikube Install
Actions -> Minikube Toggle
Actions -> Minikube Uninstall
```

Stack deployment order:

```text
Minikube Install -> NeMo Deploy -> MLflow Deploy -> Qdrant Deploy -> Kubeflow Deploy -> NIM Deploy (or Ollama Deploy)
```

See [../dgx/minikube/](../dgx/minikube/).

## MLflow

MLflow runs in minikube namespace `mlflow-system` behind
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

Kubeflow Pipelines runs in minikube namespace `kubeflow`. Two systemd services
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
minikube cluster without any other workloads.

The deploy workflow runs a smoke test after deployment (`dgx/minikube/kubeflow/verify-kfp-endpoints.sh`):
- `GET /` on `svc/ml-pipeline-ui:80` — UI serving
- `GET /apis/v2beta1/healthz` on `svc/ml-pipeline:8888` — API server healthy

### arm64 images (GHCR)

All 13 KFP images are built natively on the DGX. Full image catalog and patch
details: [../dgx/minikube/kubeflow/arm64/README.md](../dgx/minikube/kubeflow/arm64/README.md)

## Qdrant

Qdrant vector database runs in minikube namespace `qdrant-system` behind
`svc/qdrant`. The `qdrant-portfwd.service` forwards REST (port `6333`) and
gRPC (port `6334`) simultaneously. No auth configured — local dev only.

```text
Actions -> Qdrant Deploy
Actions -> Qdrant Undeploy
```

Qdrant is independent of NeMo and MLflow — it can be deployed on a fresh minikube cluster. Conventional position: after MLflow Deploy, before Kubeflow Deploy.

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

Ollama runs natively on the DGX host, not inside minikube. The platform
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

| Model | org | nim_name |
| --- | --- | --- |
| Nemotron Nano 9B v2 | `nvidia` | `nvidia-nemotron-nano-9b-v2-dgx-spark` |
| Llama 3.1 8B Instruct | `meta` | `llama-3.1-8b-instruct-dgx-spark` |

After deployment:

```sh
curl http://nim.test/v1/models
```

Available DGX Spark NIMs: [NVIDIA NIM supported models](https://docs.nvidia.com/nim/large-language-models/latest/supported-models.html) · [NGC DGX Spark containers](https://catalog.ngc.nvidia.com/orgs/nim/containers?filters=&orderBy=scoreDESC&query=dgx-spark).

## GPU Profiling

KFP pipeline projects can optionally profile individual GPU stages with **NVIDIA Nsight Systems**
(`nsys`). When enabled, a profiled KFP component runs the stage script under `nsys profile` inside
a dedicated Docker image, and writes a `.nsys-rep` report to a shared host directory organized by
project, run ID, and stage name.

Getting `nsys` to produce actual CUDA kernel data inside a KFP pod on minikube requires satisfying
several independent prerequisites at the host, container, and tool level. Every layer must be
correct — a failure at any one produces either an empty profile or a report with only NVTX
annotations and no GPU activity.

### Architecture

`build_pipeline.py` generates two variants of each profiled stage:

1. **Normal component** — runs in the standard project image; produces eval/training metrics.
2. **Profiled component** — runs `docker/nsys_<stage>.py` (an NVTX-injected version of the same
   stage script) in `Dockerfile.profiled`, wrapped in a `nsys profile` subprocess.

Both are compiled into the KFP pipeline. The `--profile-*` deploy flags select which variant runs
for each stage. Stages with profiling disabled execute the normal component; no subprocess overhead,
no PVC writes.

The profiled component's bash entrypoint:

```bash
export NVIDIA_DRIVER_CAPABILITIES=all
export NVIDIA_VISIBLE_DEVICES=all
mkdir -p "/nsight-reports/<project>/<run-id>/<stage>" && chmod 777 "..."
nsys profile \
  --trace=cuda,nvtx,cublas,cudnn \
  --gpu-metrics-devices=all \
  --gpu-metrics-frequency=10000 \
  --sample=none --force-overwrite=true \
  -o /tmp/nsys_profile \
  python3 /usr/local/bin/nsys_<stage>.py ...
cp /tmp/nsys_profile.nsys-rep "<stage-dir>/profile.nsys-rep"
nsys stats "<stage-dir>/profile.nsys-rep" > "<stage-dir>/nsys_stats.txt" || true
```

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

#### 2. NGC image / host driver compatibility

CUPTI communicates with the kernel driver via direct IOCTL, not through the CUDA compatibility
library. This means **the CUPTI version bundled inside the NGC container must match the host
driver series**. A mismatch produces `CUDA_ERROR_SYSTEM_DRIVER_MISMATCH` (error 803) and zero
kernel captures.

Check the host driver version:

```bash
cat /proc/driver/nvidia/version | head -1
# e.g. NVRM version: NVIDIA UNIX Open Kernel Module for aarch64  580.159.03  ...
```

| Host driver series | Minimum NGC pytorch image |
|---|---|
| 570.x | `nvcr.io/nvidia/pytorch:25.03-py3` |
| 580.x | `nvcr.io/nvidia/pytorch:26.04-py3` |

When the host driver is upgraded, `Dockerfile.profiled` must be updated to a matching NGC image
and the profiled image must be rebuilt. The non-profiled project image is unaffected (CUPTI
attaches only when `nsys` is running).

---

### Infrastructure (one-time per fresh minikube deploy)

Profiling uses a dedicated PVC (`nsight-reports`) mounted at `/nsight-reports/` inside each GPU
component pod, backed by a minikube 9p mount from the DGX host. This is created automatically by
the **Kubeflow Deploy** workflow, but the steps are documented here for reference or manual recovery.

```bash
# 1. Create host directory with world-writable permissions.
#    IMPORTANT: must be 777 — minikube's 9p server does not map container UIDs
#    to the host user, so pods running as any UID cannot write into a 755 dir.
mkdir -p /home/aaron/shared/nsight
chmod 777 /home/aaron/shared/nsight

# 2. Start the minikube mount with umask 0.
#    Default umask 022 causes the 9p server to create new directories with 755
#    permissions — pods get EACCES trying to write into them.
(umask 000; minikube mount /home/aaron/shared/nsight:/nsight-reports) &

# 3. Apply the PV and PVC.
kubectl apply -f - <<'EOF'
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
    path: /nsight-reports
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
minikube ssh "ls /nsight-reports"
kubectl get pvc nsight-reports -n kubeflow
```

The profiled component also pre-creates its stage subdirectory with `chmod 777` before launching
`nsys` — this prevents EACCES for the first write into a new path on the 9p mount.

---

### Profiled Docker image (`Dockerfile.profiled`)

The profiled component runs in a dedicated image separate from the normal project image.
It lives at `docker/Dockerfile.profiled` in `miramar-platform-gcp`.

```dockerfile
FROM nvcr.io/nvidia/pytorch:26.04-py3

# 'all' ensures CUPTI profiling libraries are mounted at container start.
# The NGC base image defaults to compute,utility,video — insufficient for nsys.
ENV NVIDIA_DRIVER_CAPABILITIES=all
ENV PIP_CONSTRAINT=""

RUN pip install --no-cache-dir \
    "transformers>=4.45,<5.0" \
    "peft>=0.14" \
    accelerate mlflow nvtx "openai>=1.40.2" datasets "trl>=0.14.0,<1.0"

COPY nsys_*.py /usr/local/bin/
RUN chmod +x /usr/local/bin/nsys_*.py 2>/dev/null || true
```

Key points:
- **NGC base image** must match the host driver series (see driver compatibility table above).
- **`NVIDIA_DRIVER_CAPABILITIES=all`** in the Dockerfile ensures the flag is set even if the
  entrypoint environment doesn't set it explicitly. The profiled component bash entrypoint also
  exports it for belt-and-suspenders coverage.
- The `nsys_*.py` scripts are copied from the project's `docker/` directory at image build time
  by the GHA workflow — they are not part of the platform repo itself.

**Building the image:**

```bash
# Trigger via GHA (runs on DGX, pushes to GHCR)
gh workflow run "Build Profiled PyTorch Image" --repo miramar-labs-org/miramar-platform-gcp

# Monitor
gh run list --repo miramar-labs-org/miramar-platform-gcp \
  --workflow "Build Profiled PyTorch Image" --limit 3
```

The build takes ~1h40m (large NGC base layer). The resulting image is pushed to
`ghcr.io/miramar-labs-org/pytorch-profiled:latest`.

**Rebuild required when:**
- The host NVIDIA driver is upgraded (NGC base image must be updated to match).
- New pip packages are added to `Dockerfile.profiled`.
- The `nsys_*.py` scripts change significantly (they are re-injected per project at pipeline build
  time, but the image layer must contain current versions for the COPY step to work).

**Referencing in a project's `config.yaml`:**

```yaml
components:
  baseline_eval:
    profiled_image: ghcr.io/miramar-labs-org/pytorch-profiled:latest
```

---

### Container environment variables

Two env vars must be set before `nsys` runs, either in the Dockerfile `ENV` or in the bash
entrypoint (the profiled component does both):

| Variable | Required value | Why |
|---|---|---|
| `NVIDIA_DRIVER_CAPABILITIES` | `all` | Mounts CUPTI libraries into the container. Default `compute,utility,video` omits them. |
| `NVIDIA_VISIBLE_DEVICES` | `all` | Prevents any inherited env override from hiding the GPU from the NVIDIA container runtime. |

---

### `nsys profile` flags

```bash
nsys profile \
  --trace=cuda,nvtx,cublas,cudnn \   # capture CUDA kernels, NVTX ranges, cuBLAS and cuDNN calls
  --sample=none \                    # disable CPU call-stack sampling (not needed, reduces file size)
  --force-overwrite=true \           # overwrite any existing .nsys-rep at the output path
  -o /tmp/nsys_profile \             # write to /tmp — see "Writing to /tmp" section below
  python3 /usr/local/bin/nsys_<stage>.py ...
```

**Do not use `--gpu-metrics-devices` or `--gpu-metrics-frequency`.** These flags collect hardware
GPU metrics (SM utilization, memory bandwidth) but are not supported on the DGX Spark GB10
(Blackwell, sm_100). nsys exits immediately with `Illegal --gpu-metrics-devices usage. None of
the installed GPUs are supported.` CUDA kernel tracing works without them.

**Do not use `--capture-range=cudaProfilerApi`.** PyTorch calls CUDA profiler start/stop through
`torch._C._cudart`, which is compiled directly into the PyTorch binary and bypasses nsys's
`LD_PRELOAD` injection entirely. nsys never receives the signal and captures nothing.

**Do not add `--osrt`.** OS runtime tracing adds significant overhead and is not needed for
GPU-focused ML profiling.

---

### NVTX capture injection

`build_pipeline.py` injects NVTX markers around the capture window of each profiled stage script
before writing `docker/nsys_<stage>.py`:

```python
import nvtx
nvtx.push_range("nsys_capture")
# ... the eval/training loop ...
nvtx.pop_range()
```

This approach is reliable because nsys intercepts NVTX via `LD_PRELOAD` of `libnvtx` — no
dependency on the CUDA profiler API. The markers appear in the Nsight Systems timeline as a
colored range, making it easy to isolate the GPU-active window from Python startup overhead.

`nsys` is invoked without a `--capture-range` flag and profiles the full process lifetime. The
NVTX markers are visual delineators in the timeline, not hard capture boundaries.

---

### Writing output to `/tmp`, then copying to the PVC

nsys writes `.nsys-rep` files using an mmap-based `FileStream`. The minikube 9p mount used for
the nsight PVC rejects `mmap` (`ENODEV`) — writing directly to `/nsight-reports/` causes nsys to
crash without producing a file.

The workaround is always to write to a local `/tmp` path and `cp` after `nsys` exits:

```bash
nsys profile ... -o /tmp/nsys_profile python3 ...
cp /tmp/nsys_profile.nsys-rep "${PROFILE_DIR}/profile.nsys-rep"
```

The `cp` is a plain sequential write which the 9p mount handles correctly.

---

### Enabling profiling in a pipeline run

Projects built from the `kfp-ft-eval` template expose `--profile-*` flags on `deploy_pipeline.py`:

```bash
python3 scripts/purge_kfp.py   # always purge before deploy

python3 scripts/deploy_pipeline.py \
    --run-name run-032 \
    --profile-baseline          # profile baseline eval stage only
    # --profile-finetune        # profile fine-tune stage
    # --profile-postft          # profile post-fine-tune eval stage
    # --profile-safety          # profile safety eval stage
    # --profile-nsight          # shorthand: baseline + fine-tune
```

All flags default to off. A run with no flags set is identical to a run before profiling existed —
no subprocess, no PVC writes.

---

### Output location

```
/home/aaron/shared/nsight/
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

### Reading and interpreting reports

**CLI summary (on DGX):**

```bash
nsys stats /home/aaron/shared/nsight/<project>/<run-id>/baseline-eval/profile.nsys-rep \
  --report cuda_gpu_kern_sum,cuda_api_sum,nvtx_sum,cuda_mem_time_sum,dx12_mem_ops_sum
```

**`/nsight-interpret` skill** — sends the `nsys stats` output to Claude or a local Ollama model
for bottleneck analysis without reading raw `.nsys-rep` files:

```bash
/nsight-interpret run-032               # auto-locate report by run name
/nsight-interpret run-032 --ollama llama3  # use local model instead of Claude
```

**Nsight Systems desktop GUI:**

```bash
nsys-ui /home/aaron/shared/nsight/<project>/<run-id>/baseline-eval/profile.nsys-rep
```

Or copy the `.nsys-rep` to any machine with the Nsight Systems GUI installed. The timeline shows
CUDA kernels, memory transfers, CPU threads, and NVTX ranges. A valid GPU-profiled report will show
colored kernel rows under the GPU timeline; a report with only NVTX and no GPU rows means one of
the prerequisites above was not satisfied.

---

### Troubleshooting

**Profile produces only NVTX annotations, no CUDA kernels**

The most common cause. Work through in order:

1. `cat /proc/driver/nvidia/params | grep RmProfilingAdminOnly` → must be `0`. If `1`, the
   modprobe fix has not been applied or the DGX has not been rebooted since it was written.
2. Check `NVIDIA_DRIVER_CAPABILITIES=all` is set in the container at the time `nsys` runs.
   Add a `printenv NVIDIA_DRIVER_CAPABILITIES` before the `nsys profile` line in the bash
   entrypoint and inspect pod logs.

**`CUDA_ERROR_SYSTEM_DRIVER_MISMATCH` (error 803) in pod logs**

Host driver and CUPTI version in the NGC container are incompatible. Check the host driver
series with `cat /proc/driver/nvidia/version` and update `Dockerfile.profiled` to the matching
NGC image, then rebuild the profiled image.

**`.nsys-rep` file is ~76 bytes (path string) or does not appear on the host**

Caused by a symlink on the 9p mount being read as the file content (76-byte path string), or by
nsys trying to write via mmap directly to the PVC. Verify the bash entrypoint writes to `/tmp`
first and copies after `nsys` exits.

**EACCES writing to `/nsight-reports/<project>/<run>/`**

The stage subdirectory does not exist or has restrictive permissions. The profiled component
pre-creates it with `chmod 777`, but if it fails silently, create it manually on the host:

```bash
chmod -R 777 /home/aaron/shared/nsight/<project>/
```

**`minikube mount` process died; PVC reads as empty**

The 9p mount is maintained by a foreground `minikube mount` process. If it dies (e.g. after a
laptop sleep/wake), the PVC becomes inaccessible from inside pods. Restart it:

```bash
(umask 000; minikube mount /home/aaron/shared/nsight:/nsight-reports) &
```

Verify with `minikube ssh "ls /nsight-reports"` before triggering a profiled run.
