# AGX Orin Operations

**The AGX Orin is a secondary Ollama model runner. Nothing else runs on it.**

It is *not* a second DGX. It does not run k3s, NeMo Microservices, Kubeflow
Pipelines, MLflow, Qdrant, Postgres, the Nsight Operator, Open WebUI, or NIM.
Everything in that list was torn down on 2026-09-07 (see [History](#history)).
The runner label is still `agx`, and the GHA workflows still accept
`runner: agx`, but pointing them at the AGX will stand up a stack nothing
consumes — don't, unless you are deliberately restoring it.

Hardware: 64 GB **unified** memory (Ampere sm_87, JetPack 6.2 / L4T R36.5).
Memory budget: ~24 GB OS/platform, **~40 GB for models** (`AGX_VRAM_USEABLE=40`).
Unified memory means every GB a service holds is a GB the model can't have —
which is the whole reason the k3s stack was removed.

## What actually runs

| Thing              | How                                   | Notes                                        |
| ------------------ | ------------------------------------- | -------------------------------------------- |
| **Ollama**         | native systemd (host), port `11434`   | The point of the machine. ~40 GB budget.     |
| `mlabs-runner`     | `mlabs-runner.service` (user unit)    | GHA self-hosted runner, label `agx`          |
| JupyterLab         | `jupyterlab.service`, port `8888`     | Convenience only — no KFP behind it          |

Ollama listens on `0.0.0.0:11434`, so the DGX reaches it directly over the LAN.

Disabled on 2026-09-07 because their backing services no longer exist:
`dashboard`, `kubeflow-portfwd`, `kfp-api-portfwd`, `nsight-portfwd`.

## Access

```sh
ssh -L 11435:localhost:11434 \
    -L 8887:localhost:8888 \
    $USER@orin.local
```

| Local port | AGX port | Service    |
| ---------- | -------- | ---------- |
| `11435`    | `11434`  | Ollama API |
| `8887`     | `8888`   | JupyterLab |

The other offset ports (`8002`, `5001`, `8081`, `8083`, `8891`, `6335`, `6336`,
`8892`, `13002`, `8085`) forwarded k3s services that are gone. They are still
listed in `win/agx.tlp` for a future restore; they will simply fail to connect.

See [../agx/systemd/README.md](../agx/systemd/README.md) for the service units.

## Ollama

Ollama runs natively on the AGX host, same as on the DGX.

```text
Actions -> Ollama Update    (runner: agx)
Actions -> Ollama Deploy    (runner: agx)
Actions -> Ollama Undeploy  (runner: agx)
```

State variables: `CURRENT_OLLAMA_MODEL_AGX`, `CURRENT_OLLAMA_VRAM_GB_AGX`,
`AGX_OLLAMA_ACTIVE`.

### Reached from the DGX model router

The DGX model router (LiteLLM, `model-router` namespace on DGX k3s) has the AGX
Ollama models registered as `agx/<model>` upstreams in
[`dgx/k3s/model-router/litellm-config.yaml`](../dgx/k3s/model-router/litellm-config.yaml).

Because the AGX has no k3s, there is no in-cluster Service and no CoreDNS
record for it — the router targets the **host IP** (`AGX_HOST_IP`,
`192.168.1.202`) on Ollama's OpenAI-compatible `/v1` endpoint. `orin.local`
will not resolve from inside a DGX pod (CoreDNS does not do mDNS); use the IP.

```sh
curl -s http://localhost:8000/v1/models | jq -r '.data[].id'   # via router portfwd
```

To add or remove AGX models: pull them on the AGX (`Ollama Deploy`, runner
`agx`), edit `litellm-config.yaml`, commit, and re-run **Model Router Deploy**
(runner `dgx`).

## NIM

NIM is **not supported on AGX Orin**. All NIM LLM containers on NGC are
`linux/amd64` only; there are no `linux/arm64` images. `CURRENT_NIM_MODEL_AGX`
stays `none`. Use Ollama.

## GPU containers do not work on the AGX

Verified 2026-09-07: `docker run --runtime nvidia` injects no `libcuda` into a
glibc container on this host (the CSV mount does not land), k3s containerd had
no nvidia runtime registered, and no `nvidia.com/gpu` resource was advertised.
The Orin GPU is reachable **only** from host-native processes — i.e. Ollama.
Do not plan containerised GPU work here.

Related: on JetPack 6.x the Orin serves CUDA through the proprietary `nvgpu`
driver, not `nvidia.ko`, so non-root profiling is blocked at the driver and
`NVreg_RestrictProfilingToAdminUsers` has no effect. JetPack 7.x replaces
`nvgpu` with OpenRM and would in principle lift that — but with no k3s, no KFP
and no Nsight Operator on this machine, there is nothing on the AGX that would
benefit. A JetPack 7.2 flash is **not** planned. See
[nsight.md](nsight.md) for the DGX profiling path.

## History

Until 2026-09-07 this document claimed the AGX ran "the same local AI stack as
the DGX Spark". It did not, in any useful sense. `kubectl get pods -A` returned
nothing while containerd still held 126 containers in the `k8s.io` namespace,
with `nmp-core` (3.44 GB) and SeaweedFS `weed` alive in `kubepods.slice`
cgroups since 2026-08-27 — orphaned kubelet pods invisible to the control
plane, eating unified memory that the models needed.

Teardown (all verified):

1. **K3s Uninstall** (runner `agx`) — service gone, binaries removed,
   `k3s-server`/`nmp-core`/`weed` all at 0 processes. Memory 37 GB → 4 GB used,
   54 GB available. (This workflow was itself a silent no-op until PR #75; it
   ran inside the runner container where `k3s-uninstall.sh` does not exist.)
2. `docker image prune -a` — 96.73 GB reclaimed, 147 images → 2.
3. Disabled the four dead portfwd/dashboard user units.
4. Registered AGX Ollama with the DGX model router.
5. Docs + dashboard corrected to match (this file; the dashboard's AGX Orin
   band now shows only Ollama, OpenUI backend, VRAM Reserved, VRAM Free).

To restore the full stack, the workflows are unchanged: **K3s Install** →
**NeMo Deploy** → **MLflow Deploy** → **Qdrant Deploy** → **Kubeflow Deploy**,
all with `runner: agx`. Re-enable the disabled user units and re-add the band
items to `scripts/dashboard/generate-dashboard.sh` if you do.
