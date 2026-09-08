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

### The platform judge runs here

**Platform rule: the LLM-as-judge is one shared model — `phi4` — and it is hosted on
the AGX Orin.** Every project on the platform that needs a judge points at
`http://192.168.1.202:11434/v1` and names that same model. It is not a per-project
modelling choice: a fixed judge is what makes scores comparable across runs, across
projects, and over time.

Templates that ship with a judge, all four pointing here:

| Template | Judged stages |
| --- | --- |
| `new-project-ft-eval` | `baseline_safety_eval`, `safety_eval` |
| `new-project-nemo-ft-eval` | `baseline_safety_eval`, `safety_eval` |
| `new-project-kfp-rag` | `generation_eval`, `faithfulness_eval`, `safety_eval` |
| `new-project-kfp-eval` | `judge_and_score` |

Those stages run in KFP pods on the **DGX**; only the judge call crosses to the AGX.
Traffic stays on the LAN, so the PHI boundary is unaffected.

**Why off-box.** The judge is the one LLM that has to be available *during* an eval
while not being the thing under evaluation. A judged stage keeps its subject resident
on the DGX GPU while it calls the judge — the fine-tuned model for `safety_eval`, the
current candidate in a bakeoff, or the vLLM serving project for the whole of a
`kfp-rag` run. With the judge on the DGX too, `phi4` occupies 9.1 GB of the same
unified memory. Judging from the AGX hands those 9.1 GB back.

Note this is *not* contention with `fine_tune`: the ft-eval DAG is sequential
(`download → prepare/baseline_eval → baseline_safety_eval → fine_tune → …`), so a
judge call never overlaps training. The contention is with the eval subject inside
the judged stage. `kfp-rag` is the stronger case, because its serving project holds
memory across every stage rather than one.

**Why `phi4`.** Measured 2026-09-07 on five judge-shaped safety cases at
`temperature: 0` — a safe answer, two dangerous medical answers, a correct refusal,
and a borderline case:

| Candidate | Mean warm latency (AGX) | Parseable + correct |
| --- | --- | --- |
| `phi4` | 14.0 s | 5/5 |
| `nemotron-3-nano:30b` | 15.4 s | 4/5 (one empty completion) |
| `qwen3.6:35b-a3b` | — | 0/5 (empty completions) |

The two larger candidates are reasoning models: they spend the token budget on
thinking tokens and return empty content on harder cases. `gpt-oss:120b` — the old
`kfp-eval` judge — is 65 GB and exceeds not just the AGX model budget but the Orin's
64 GB of total memory, so it cannot be the platform judge at all.

**Cost.** Same five cases, same model, `temperature: 0`:

| Host | Mean warm latency |
| --- | --- |
| DGX Spark (GB10) | 2.5 s/call |
| AGX Orin | 14.0 s/call |

The Orin has far less memory bandwidth, so the judge is ~5.6× slower there. At
`safety_sample_size: 100` over two safety stages that is roughly **+38 min of wall
clock per ft-eval run**; ~+29 min for a `kfp-rag` run at `sample_size: 50` over three
judge stages. **Verdicts are identical on both hosts** (same model, `temperature: 0`),
so the fallback below does not move a single score.

**Keep the judge's headroom.** `phi4` must stay pulled on the AGX. It is deliberately
*not* deployed via the `Ollama Deploy` workflow: that pins a model resident with
`keep_alive=-1` and claims the machine's single deploy slot, which would block
`CURRENT_OLLAMA_MODEL_AGX` from being anything else. The judge only needs the model in
the local cache — Ollama loads it on the first judge call and unloads it when idle.
Pull it with:

```sh
ssh $USER@orin.local 'ollama pull phi4'
```

Because the judge loads on demand, it needs ~9.1 GB of the ~40 GB `AGX_VRAM_USEABLE`
budget free when a judged stage runs. An `Ollama Deploy` against `agx` that pins a
model larger than ~30 GB will starve it. Size AGX deployments with that headroom in
mind.

`new-project-kfp-eval`'s `serving.ollama_base_url` is a different thing and stays on
the DGX: it is the candidate-under-test endpoint, and the DGX is the hardware being
benchmarked. Only its `judge.base_url` points here.

If the AGX is offline, the fallback is a one-line edit in the project's `config.yaml`:
point `judge.base_url` back at `http://192.168.1.200:11434/v1`. All four candidate
models exist on both hosts, so the judge model itself is preserved.

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
