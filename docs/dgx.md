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
| `8889`     | Nsight Operator UI / SPA (not the REST API) |
| `13001`    | Nsight Operator coordinator REST API   |
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

See [../dgx/k3s/](../dgx/k3s/) for the per-workload manifests and deploy/verify scripts.

## MLflow

MLflow runs in k3s namespace `mlflow-system` behind
`svc/mlflow-tracking`. The `mlflow-portfwd.service` forwards port `5000`.

```text
Actions -> MLflow Deploy
Actions -> MLflow Undeploy
```

NeMo must be deployed before MLflow because MLflow uses NeMo's postgres backend.

The deploy workflow runs a smoke test after deployment (`dgx/k3s/mlflow/verify-mlflow-endpoints.sh`):
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

The deploy workflow runs a smoke test after deployment (`dgx/k3s/kubeflow/verify-kfp-endpoints.sh`):
- `GET /` on `svc/ml-pipeline-ui:80` — UI serving
- `GET /apis/v2beta1/healthz` on `svc/ml-pipeline:8888` — API server healthy

### arm64 images (GHCR)

All 13 KFP images are built natively on the DGX. Full image catalog and patch
details: [../dgx/k3s/kubeflow/arm64/README.md](../dgx/k3s/kubeflow/arm64/README.md)

## Qdrant

Qdrant vector database runs in k3s namespace `qdrant-system` behind
`svc/qdrant`. The `qdrant-portfwd.service` forwards REST (port `6333`) and
gRPC (port `6334`) simultaneously. No auth configured — local dev only.

```text
Actions -> Qdrant Deploy
Actions -> Qdrant Undeploy
```

Qdrant is independent of NeMo and MLflow — it can be deployed on a fresh k3s cluster. Conventional position: after MLflow Deploy, before Kubeflow Deploy.

The deploy workflow runs a smoke test after deployment (`dgx/k3s/qdrant/verify-qdrant-endpoints.sh`):
- `GET /health` — server up
- `GET /collections` — API reachable

Web UI (with SSH tunnel active): [http://localhost:6333/dashboard](http://localhost:6333/dashboard)

Python client:

```python
from qdrant_client import QdrantClient
client = QdrantClient(url="http://localhost:6333")
```

## Postgres

Postgres 16 runs in k3s namespace `postgres-system` behind `svc/postgres`
(`postgres.postgres-system.svc.cluster.local:5432`). The `postgres-portfwd.service`
forwards port `5432`, same pattern as Qdrant/MLflow — connect a GUI client
(psql, pgAdmin, DBeaver, TablePlus, etc.) to `localhost:5432` (DGX) or
`localhost:5433` (AGX) over the laptop SSH tunnel. `kubectl exec -it
deploy/postgres -- psql -U postgres` still works for ad hoc in-cluster access.

```text
Actions -> Postgres Deploy
Actions -> Postgres Undeploy
```

Postgres is a shared platform service: any project needing durable
relational storage gets its own database + role provisioned in the same
namespace, rather than standing up a private instance. Provision (or
re-provision) a consumer by passing `consumer_db` / `consumer_user` to
**Postgres Deploy** — the run prints the resulting `DATABASE_URL` to the
step summary for pasting into the consumer app's own secret. Re-running is
safe: database/role/grants are idempotent and an existing role's password is
never reset.

**Known gotcha:** GitHub Actions' automatic secret-masking heuristics can
redact the generated password inside the `DATABASE_URL` line in both the
raw log and the step summary (observed live during the
`multi-agent-ai-trader` rollout), even though it was never registered via
`secrets.*` or `::add-mask::` — it just looks enough like a secret to trip
the heuristic. If the printed value comes back as `***`, don't try to
recover it from the run output; instead set a known password directly and
build `DATABASE_URL` from it yourself:
```sh
kubectl -n postgres-system exec -it deploy/postgres -- \
  psql -U postgres -c "ALTER ROLE <consumer_user> PASSWORD '<new-password>';"
```
then assemble `postgresql://<consumer_user>:<new-password>@postgres.postgres-system.svc.cluster.local:5432/<consumer_db>`
and patch it into the consumer's secret directly.

**Known gotcha:** the auto-generated consumer password can contain
URL-reserved characters (observed: a literal `/`), which breaks `psql`'s URI
parsing — it misreads part of the password+host as the port and fails with
`invalid integer value "..." for connection option "port"`. Don't treat this
as just a log-masking-recovery fallback; pin a fresh alphanumeric-only
password immediately after any consumer provisioning, regardless of whether
the printed value was masked:
```sh
openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24
```
then apply it with the same `ALTER ROLE` command above.

**Known gotcha:** a consumer reached via a GHA-workflow-side
`kubectl port-forward svc/postgres 5432:5432` (SSH + kubeconfig + port-forward
from within a workflow step, as opposed to a pod running inside the cluster)
must use `localhost` as the host in its `DATABASE_URL`, **not**
`postgres.postgres-system.svc.cluster.local`. That in-cluster DNS name only
resolves for pods running inside the cluster — the runner container reaching
Postgres through a locally-forwarded port cannot resolve it, and fails with
`could not translate host name ... Temporary failure in name resolution`.

The deploy workflow runs a smoke test after deployment
(`dgx/k3s/postgres/verify-postgres-endpoints.sh`): Deployment rollout
status, Service has endpoints, and `pg_isready`.

Storage: hostPath PV (`persistentVolumeReclaimPolicy: Retain`) — data
survives `Postgres Undeploy` unless the namespace is explicitly deleted too.
See `dgx/k3s/postgres/README.md` for full script usage.

## Model Router

The model router is a [LiteLLM](https://github.com/BerriAI/litellm) proxy running in k3s namespace
`model-router` that exposes a single OpenAI-compatible `/v1` endpoint and dispatches to multiple
active serving backends by the `model` field in the request. Open WebUI is wired to this URL so
it sees all registered models at once rather than a single backend.

```text
Actions -> Model Router Deploy    (upserts ConfigMap, restarts pod, sets {MACHINE}_OPENWEBUI_API_URL)
Actions -> Model Router Undeploy  (deletes namespace, clears {MACHINE}_OPENWEBUI_API_URL)
```

The routing table lives in the platform repo at `dgx/k3s/model-router/litellm-config.yaml`.

**Serving projects register automatically.** When a serving project (`serving-vllm`, `serving-trt-engine`, etc.) deploys and the model-router namespace exists, the deploy workflow adds its entry to `litellm-config.yaml` via the GitHub Contents API and triggers a router redeploy. Undeploy removes the entry. No manual edits are needed for serving project models.

To manually add or remove a non-serving-project upstream:

1. Edit `dgx/k3s/model-router/litellm-config.yaml`:
   ```yaml
   model_list:
     - model_name: "my-model"
       litellm_params:
         model: "openai/my-model"
         api_base: "http://{service}.{namespace}.svc.cluster.local:8000/v1"
         api_key: "none"
   ```
2. `git commit && git push`
3. Run **Model Router Deploy** — the ConfigMap is upserted and the pod restarts.

**URL convention:** `http://{service}.{namespace}.svc.cluster.local:8000/v1`  
where `namespace` = the serving project repo name (that is the K8s namespace used by all serving templates).

The router is CPU-only — no GPU required. It is independent of NeMo and can be deployed any time after K3s Install.

```bash
# Local access (with kubectl access)
kubectl port-forward svc/model-router 8000:8000 -n model-router

curl http://localhost:8000/v1/models
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen25-7b-arc","messages":[{"role":"user","content":"hello"}],"max_tokens":100}'
```

When the model router is deployed, `{MACHINE}_OPENWEBUI_API_URL` is set to
`http://model-router.model-router.svc.cluster.local:8000/v1` and Open WebUI is redeployed automatically
(if active) to pick up the new backend. When undeployed, the URL is cleared and Open WebUI reverts to
Ollama-only.

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
profiled (the ft-eval / kfp templates drive this from a `profiling:` block in `config.yaml` —
see the project README).

**Where reports live.** The operator writes every `.nsys-rep` **only to its own internal
object store** — a MinIO instance in the `nsight-operator` namespace (bucket `nsight-reports`).
Nothing lands on the host filesystem automatically. The durable, human-facing archive at
`~/shared/nsight/<project>/<run-id>/<stage>/` is populated by **`~/bin/nsight-export-report`**
(usually via the **`/nsight-export`** skill, which also auto-runs `/nsight-interpret`), which
drives an Nsight Operator *coordinator session*, pulls the finished report out of MinIO, verifies
it, and writes a `profile.json` sidecar.

The helper's implementation lives in the repo at **`scripts/nsight/export-report.sh`**;
`~/bin/nsight-export-report` is a symlink to it, so every caller and doc keeps using the
`~/bin/...` path unchanged.

**Systems vs Compute.** `--tool systems` (default) is the KFP-integrated path above — the
operator injects `nsys` into the stage pod and the coordinator drives collection out of band.
`--tool compute` is **host-only and ad-hoc**: it runs `ncu`
(`/opt/nvidia/nsight-compute/2026.2.1/ncu`, `RmProfilingAdminOnly=0` so no sudo) directly on the
DGX as the parent process of the workload, replaying kernels — it cannot attach to a live KFP
pod, touches no operator/coordinator/MinIO, and writes a verified `profile.ncu-rep`.

> **MinIO is the operator's internal report storage. `~/shared/nsight` is the durable
> profiling archive** that `/nsight-interpret`, the desktop GUI, and the template READMEs
> all expect.

The coordinator REST API is reached at `http://localhost:13001/api/v1/` on the DGX host —
`nsight-portfwd.service` forwards it (alongside `:8889`, which serves the web UI / SPA only,
**not** the REST API).

### Collecting a profile

**Via a KFP run (normal path).** Set the stage's flag in the project `config.yaml`
`profiling:` block, `/kfp-deploy`, then `/kfp-monitor` — when the profiled stage's pod goes
`Running`, `/kfp-monitor` kicks off `nsight-export-report` in the background so collection
happens while the stage is hot on GPU. When the run reaches a terminal state it reports the
export path and the `/nsight-interpret` analysis file.

**Manually, while a stage is hot:**

```bash
/nsight-export <project> <run-NNN> <stage> [--duration 90]
# or directly:
~/bin/nsight-export-report --project <project> --run-id run-NNN --stage <stage> --duration 90
```

**Ad-hoc (no KFP run)** — a report already sitting in MinIO, or a one-off capture:

```bash
# Systems: export a report already in MinIO
~/bin/nsight-export-report --project <slug> --run-id run-000 --stage main \
  --no-collect --report-id <minio-report-uuid>
# Systems: drive a fresh operator collection, land it ad-hoc
~/bin/nsight-export-report --project <slug> --run-id run-000 --stage main --adhoc
# Compute: run host `ncu` against the bundled GPU smoke bench (or `-- <your cmd>`)
~/bin/nsight-export-report --project <slug> --run-id run-000 --stage main --adhoc \
  --tool compute --ncu-set basic --launch-count 20
# --adhoc lands under ~/shared/nsight/{systems,compute}/<slug>-<UTC-timestamp>/ instead of
# project/run/stage. Non-adhoc compute re-captures of the same stage overwrite in place, same
# as systems. --no-collect / --report-id are systems-only.
```

**Keeping throwaway captures out of the archive.** Every path above writes under
`~/shared/nsight/` (the durable archive). For validation runs, one-off experiments, or
anything you do not want kept, pass `--dest-root <dir>` (or set `$NSIGHT_DEST_ROOT`) to
redirect the whole `{<project>/<run>/<stage>, systems/…, compute/…}` tree elsewhere — e.g. a
scratch dir. The helper otherwise has no non-archive output mode.

`nsight-export-report` fails loudly (non-zero exit) if the coordinator is unreachable, the
`default` service tag is held by another session, or the retrieved report shows no GPU
kernel activity — it never reports success when a usable report was not archived. The
`--tool compute` path applies the same rule: it verifies the `.ncu-rep` with an `ncu -i`
readback and fails if no kernels were profiled.

**Fire it while the GPU is already hot — the window opens, it does not "catch up".**
GB10 uses hardware tracing for CUDA. On a KFP-injected `nsys` collection, only kernels that
run in **roughly the first few seconds after the collection window opens** get GPU-side
timestamps retrieved; every kernel launched later stays "incomplete" at session stop and is
dropped ("Number of incomplete CUPTI events dropped: N"). The `.nsys-rep` then comes back with
CUDA API rows but no `cuda_gpu_kern_sum`, and the helper's verify fails it.

Consequences:

- The profiled stage must issue representative GPU kernels **from its very first line — no
  startup `sleep`, no idle warm-up**. A pipeline that sleeps before its GPU work will always
  produce a kernel-less report, no matter how long the window is.
- Run `/nsight-export` (or let `/kfp-monitor` fire it) the **instant** the stage pod is
  `Running` and hot, with `--delay 0`.
- A **longer `--duration` does not help** and neither does raising the iteration count — the
  retrieval window is anchored to when collection *opens*, not to how much GPU work happens.
  ~30–90 s is plenty; the template's `collection_window_s` can stay small.

(Confirmed 2026-09-06: identical injected `nsys` cmd, identical stage code — the only
difference between a capture with 46 GB10 kernel rows and one with zero was whether the GPU
loop was already running when collection opened.)

#### Privileged-mode reconciliation (automatic)

Full GB10 hardware GPU trace (~47 CUDA kernel records vs ~7) needs
`securityContext.privileged: true` on the profiled container. The Nsight injector adds it, but
KFP step pods bake in `allowPrivilegeEscalation: false` + `drop: [ALL]` + `RuntimeDefault`
(not overridable via the KFP SDK — upstream rejected privileged support), and the `kubeflow`
namespace enforces PodSecurity `baseline`. **Nsight Operator Deploy** handles both automatically:

- deploys `nsight-ape-webhook` (`nsight-ape-webhook/` in this repo) — a mutating webhook that,
  on pods labelled `nvidia-nsight-profile=enabled`, strips `allowPrivilegeEscalation`/all-drop
  caps/`RuntimeDefault` from containers the injector marked `privileged`;
- relaxes the `kubeflow` namespace `pod-security.kubernetes.io/enforce` from `baseline` to
  `privileged` (input `relax_kubeflow_psa`, default `true`; `warn: restricted` is kept).

**Nsight Operator Undeploy** removes the webhook (cluster-scoped) and restores `enforce=baseline`.
No pipeline-code change is needed beyond the pod label.

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

> **Legacy — not written by the Nsight Operator.** The `nsight-reports` PVC below dates from a
> removed profiling mechanism (an `nsys`-wrapper entrypoint image that `cp`'d reports into the
> hostPath). The operator does **not** use this PVC — it writes to its own MinIO, and
> `~/bin/nsight-export-report` writes the host archive directly. The PV/PVC is still created by
> **Kubeflow Deploy** (harmless; removal is tracked as a follow-up) and the directory doubles as
> a scratch location for ad-hoc host-side `nsys`/`ncu` captures.

The PVC (`nsight-reports`) is mounted at `/nsight-reports/` inside each GPU component pod, backed
by a k3s hostPath PV pointing directly at the DGX host. Created automatically by the
**Kubeflow Deploy** workflow; steps documented here for reference or manual recovery.

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
        profile.nsys-rep       # Nsight Systems report (pulled from the operator's MinIO)
        profile.nsys-rep.sha256
        profile.json           # metadata sidecar (operator session/report ids, sha256,
                               #   kfp_run_id, mlflow_run, collection window)
        profile.sqlite         # nsys export (reused by nsys stats / nsys-ui)
        manifest.json          # the operator's own report manifest
        summaries.csv          # nsys stats output, consumed by /nsight-interpret
        nsys_stats.txt
        analysis-claude.md     # written by the auto-chained /nsight-interpret
      fine-tune/
        ...
  systems/<slug>-<UTC-timestamp>/   # ad-hoc Nsight Systems captures (--adhoc)
  compute/<slug>-<UTC-timestamp>/   # ad-hoc host-ncu captures (--adhoc --tool compute):
                                    #   profile.ncu-rep + .sha256, summaries.csv (ncu --page raw),
                                    #   ncu_details.txt (ncu --page details), profile.json
                                    #   (tool=nsight-compute, ncu_version, ncu_set, launch_count,
                                    #    command; operator ids null)
```

`<stage>` is the hyphenated KFP component name (`baseline-eval`, `fine-tune`,
`post-finetune-eval`, `safety-eval`, `baseline-safety-eval`), or `main` for a single-stage
pipeline. Existing report history is not reorganised — the convention is forward-only.

### Retention

`nsight-export-report` never deletes the MinIO copy. MinIO `nsight-reports` is the operator's
working set (retained ~7–30 days); `~/shared/nsight` is the archive, kept indefinitely. MinIO
objects should only be pruned **after** a verified export exists on disk. A `nsight-retention`
systemd timer to automate the MinIO prune is a future item.

---

### Interpreting reports

`/nsight-export` auto-chains `/nsight-interpret` on the report it just archived. To (re-)run the
analysis by hand, use the `/nsight-interpret` skill to send `nsys stats` output to an LLM for
bottleneck analysis:

```bash
/nsight-interpret <project> run-032       # locate report by project + run name
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
