# Nsight GPU Profiling Manual

Everything about profiling GPU work on the Miramar platform: the two Nsight tools, how each one
is wired, the flags that matter, recipes for common scenarios, and what to do when a capture
comes back empty.

Host specifics in this document are measured on the **DGX Spark** (`spark-79b7.local`, GB10
Blackwell, `nsys` 2026.3.1.157 injected by the operator, `ncu` 2026.2.1.0 on the host). AGX Orin
differences are called out where they exist.

- **Quickstart** — [below](#quickstart)
- **Operations** (deploy/undeploy the operator, service ports): [dgx.md](dgx.md)
- **KFP integration** (`config.yaml` `profiling:` block, `/kfp-monitor` wiring): [kfp-skills.md](kfp-skills.md)

---

## Quickstart

Both quickstarts profile the same committed workload, `scripts/nsight/gpu-bench.py` — fp16
`matmul → relu → add` on 4096² tensors, wrapped in an NVTX range. It exists so you can answer
"is profiling working at all?" without involving a real project.

### Prerequisites

```bash
# 1. Operator deployed?  (Systems only — Compute needs none of this)
kubectl -n nsight-operator get pods | grep -c Running     # expect 12
curl -fsS http://localhost:13001/api/v1/sessions/ >/dev/null && echo "coordinator OK"

# 2. Non-root profiling allowed?  (see Host prerequisites below)
grep RmProfilingAdminOnly /proc/driver/nvidia/params      # DGX expects 0
```

### Nsight Systems — in-cluster, on a KFP stage

```bash
cd ~/git-miramar-labs-org/miramar-platform-gcp

# 1. Submit the bench as a KFP pipeline (300 s on GPU, pod-labelled for injection)
python3 scripts/nsight/gpu-bench.py --submit
# -> KFP_RUN_ID: 4e6d7c97-...

# 2. Wait for the step pod to reach Running
kubectl get pods -n kubeflow | grep gpu-bench | grep container-impl

# 3. Capture a 90 s window while it is hot
~/bin/nsight-export-report --project gpu-bench --run-id run-001 --stage main \
  --duration 90 --adhoc
# -> EXPORTED: ~/shared/nsight/systems/gpu-bench-<UTC-ts>/profile.nsys-rep
```

Expect ~10 MB, tens of thousands of kernel records, and NVTX `matmul_block_<n>` ranges. Verified
on 2026-09-07: 35,119 `cutlass_80_tensorop_f16_s16816gemm_relu_f16` launches (68.2 % of GPU
time), 35,119 `vectorized_elementwise_kernel` add (19.8 %), 35,119 clamp (12.1 %).

### Nsight Compute — host, per-kernel

```bash
~/bin/nsight-export-report --project gpu-bench --run-id run-001 --stage main \
  --adhoc --tool compute
# -> EXPORTED: ~/shared/nsight/compute/gpu-bench-<UTC-ts>/profile.ncu-rep
```

No pipeline, no cluster, no operator. `ncu` runs the bench directly as a child process. With no
`-- <command>` the helper falls back to `gpu-bench.py` automatically, so this one line is the
whole smoke test. Expect ~29 MB and 20 profiled kernels at 9 replay passes each.

### Reading the result

```bash
/nsight-interpret gpu-bench run-001                  # LLM bottleneck analysis
nsys-ui  ~/shared/nsight/systems/gpu-bench-<ts>/profile.nsys-rep
ncu-ui   ~/shared/nsight/compute/gpu-bench-<ts>/profile.ncu-rep
```

---

## The two tools

They answer different questions and, on this platform, are wired completely differently. This is
the single most important thing to internalise.

| | **Nsight Systems** (`--tool systems`) | **Nsight Compute** (`--tool compute`) |
|---|---|---|
| Question | *Where does wall-clock time go?* | *Why is this one kernel slow?* |
| Granularity | Whole-process timeline | Per-kernel counters |
| Where it runs | **In-cluster** — operator injects `nsys` into the KFP step pod | **Host only** — `ncu` on the DGX |
| Attaches to a running process? | Yes (time-boxed `nsys start`/`stop`) | **No** — must be the parent process |
| Overhead | ~3.5 % on a gemm-bound loop | Replays each kernel 9× |
| Output | `profile.nsys-rep` | `profile.ncu-rep` |
| Touches operator/MinIO? | Yes | Never |
| Typical use | A real KFP fine-tune / eval stage | A kernel you already suspect |

**Why Compute cannot profile a KFP stage.** `ncu` works by *replaying* each kernel many times
with different counter configurations, which means it must own the process from launch. It
cannot attach to a container that is already running, and there is no operator path for it — the
Nsight Operator is Systems-only (its coordinator `/collect` body accepts only `duration` and
`delay`, and `default-nsight-tool-config` is hardwired to `nsys`). To use Compute on pipeline
code, extract the hot function into a host-runnable script and profile that.

**They cannot run at the same time.** Only one profiling session may hold the GPU's performance
counters. Run Systems first, let it finish, then run Compute.

---

## How an in-cluster Systems capture actually works

```
  KFP step pod                        nsight-operator ns              host
  ┌──────────────────────┐            ┌──────────────────┐
  │ label:               │  inject    │ nsight-injector  │
  │ nvidia-nsight-       │◀───────────│ (mutating hook)  │
  │   profile=enabled    │            └──────────────────┘
  │                      │
  │ + nvidia-devtools-   │            ┌──────────────────┐
  │     binaries (init)  │   drive    │   coordinator    │◀── :13001 ──┐
  │ + nsight-process-    │◀───────────│  start / stop    │             │
  │     hook   (init)    │            └──────────────────┘             │
  │                      │                     │ writes               │
  │ your container       │                     ▼                      │
  └──────────────────────┘            ┌──────────────────┐            │
                                      │ MinIO            │            │
                                      │ bucket:          │   pull     │
                                      │ nsight-reports   │────────────┤
                                      └──────────────────┘            │
                                                                       │
                              ~/shared/nsight/…/profile.nsys-rep ◀─────┘
                                      export-report.sh
```

1. **Injection.** You label the pod `nvidia-nsight-profile=enabled`. A mutating webhook adds two
   init containers (`nvidia-devtools-binaries`, `nsight-process-hook`) that stage the `nsys`
   binaries and hook process startup. No special image, no `nsys` wrapper in your entrypoint.
2. **Collection.** `export-report.sh` creates a *coordinator session*, waits `--delay`, fires
   `start`, waits `--duration`, fires `stop`, and releases the session (via a trap, so an
   interrupt does not strand the `default` service tag).
3. **Storage.** The operator writes the `.nsys-rep` **only to its own MinIO** in the
   `nsight-operator` namespace. Nothing reaches the host filesystem on its own.
4. **Export.** The helper pulls the report out of MinIO, runs `nsys stats`, verifies GPU kernel
   activity is present, computes a sha256, writes a `profile.json` sidecar, and only then moves
   the staged tree into the archive.

> **MinIO is the operator's working set (~7–30 days). `~/shared/nsight` is the durable archive.**
> `/nsight-interpret`, the desktop GUIs, and the template READMEs all read the archive.

MinIO credentials live in the k8s secret `nsight-operator-cloud-storage-minio-credentials`
(namespace `nsight-operator`) and are read at runtime. Never hardcode them.

The coordinator REST API is at `http://localhost:13001/api/v1/` (`nsight-portfwd.service`).
Port `:8889` serves the web UI/SPA only — **not** the REST API.

### `--trace=cuda-sw` is load-bearing

This single setting decides whether a KFP capture contains GPU kernels **at all**. It is already
set in `dgx/k3s/nsight/values.yaml`; this note exists so a future edit does not silently undo it.

On a CUDA ≥ 13.0 driver, `--trace=cuda` selects nsys's **hardware** CUDA trace, which reconciles
GPU-side kernel timestamps to the host **only at process teardown**. The operator always runs a
*time-boxed* collection while the stage keeps running, so at `stop` every GPU-side record is
still unreconciled and gets discarded ("Number of incomplete CUPTI events dropped: N"). The
report comes back with a complete CPU-side CUDA API trace, NVTX ranges, and **no
`CUPTI_ACTIVITY_KIND_KERNEL` table at all** — and the helper's verify fails it.

Measured on the DGX with nsys 2026.3.1.157, reproducing the operator's invocation shape
(`profile --start-later=true`, separate `start`/`stop`, target still running at stop), changing
only the trace value:

| Trigger / window | `--trace=cuda` | `--trace=cuda-sw` |
|---|---|---|
| t+25 s, 30 s window | 0 kernels (2800 dropped) | 2553 kernels (47 dropped) |
| t+60 s, 90 s window | 0 kernels (8400 dropped) | 8624 kernels (176 dropped) |

Consequences:

- **Trigger timing is not the variable.** Under `cuda-sw` a collect fired 60 s into a saturated
  stage returns full kernel data. Firing early is still sensible — you get the window you asked
  for — but a late trigger no longer costs you the kernels, and neither `--delay 0` nor a
  workload that issues kernels from its first line is required for *correctness*.
- **`--cuda-flush-interval` is not a workaround.** It governs only the software path, so it was
  inert while hardware trace was selected. It is now genuinely in effect at 100 ms.
- **Cost:** ~3.5 % runtime overhead on a gemm-bound loop. `--cuda-graph-trace=node` granularity
  and device-side graph launch tracing require hardware trace and are unavailable under
  `cuda-sw`. Nothing on this platform traces CUDA graphs at node granularity.

Check what the live operator is collecting:

```sh
kubectl -n nsight-operator get nsightoperatorprofileconfigs.nvidia.com \
  default-profile-config -o jsonpath='{.spec.nsightToolConfigs[0].nsightToolArgs}'
# --trace=cuda-sw,nvtx,cublas,cudnn --sample=none --cuda-flush-interval=100 --force-overwrite=true
```

### Privileged mode is decided by the host driver

Whether the profiled container needs `securityContext.privileged: true` is decided by the
**host driver**, not by the trace mode. Specifically, by *which driver serves CUDA* — because
that determines whether a non-root profiling knob exists at all:

| Host | CUDA served by | Non-root profiling | `privileged` | Values file |
|---|---|---|---|---|
| DGX Spark (GB10) | `nvidia.ko` RM | opt-in, see [Host prerequisites](#host-prerequisites) | `false` | `dgx/k3s/nsight/values.yaml` |
| AGX Orin (JetPack 6.2) | `nvgpu` (Tegra) | **impossible** — no equivalent knob | `true` | `agx/k3s/nsight/values.yaml` |

**Do not read `RmProfilingAdminOnly` as the gate on Tegra.** `/proc/driver/nvidia/params` exists
on the AGX and reports `1`, which invites the conclusion that the DGX's modprobe fix would align
it. It would not. On JetPack 6.x Orin the `nvidia`/`nvidia_modeset`/`nvidia_drm` modules are the
*display* stack; CUDA runs on `nvgpu` (`nvidia-smi` names the device `Orin (nvgpu)`, no
`nvidia_uvm` is loaded, and the device nodes are `/dev/nvhost-gpu` + `/dev/nvgpu/igpu0`). Setting
`NVreg_RestrictProfilingToAdminUsers=0` there flips a reading on a driver that is not serving
CUDA, and changes nothing. Measured on the AGX with a non-root `ncu`:

```
==WARNING== Insufficient privileges to launch app for profiling. Launch app with root privileges
```

Note that this is the **Tegra** message, not the desktop `ERR_NVGPUCTRPERM` that the modprobe
knob addresses — a different gate, with no user-space control (`/sys/module/nvgpu/parameters/`
exposes nothing profiling-related). The same workload runs fine as non-root when not profiled.

**This is a JetPack 6.x property, not a permanent one.** JetPack 7.x replaces the proprietary
`nvgpu` with OpenRM, and JetPack 7.2 (Jetson Linux R39.2) extends that to the whole Orin family.
On an Orin running JetPack 7.x, CUDA is served by the RM that *does* have this knob, so the DGX's
configuration should apply and `privileged: false` becomes possible. **Verify before relying on
it** — confirm with a non-root `ncu` on the host, not from the `/proc` reading alone. The AGX is
on JetPack 6.2 (L4T R36.5) as of 2026-09-07; moving to 7.x is a full flash, not an apt upgrade.

**Nsight Operator Deploy** picks the values file from the `runner` input. Measured on the DGX
through the real operator path (KFP stage, collect fired 60 s in, 90 s window): `privileged: true`
→ 7,992 kernel records, `privileged: false` → 8,539. Dropping it costs nothing there and lets KFP
step pods keep their own hardening. Do not copy `privileged: false` to a host whose driver you
have not checked — on a `nvgpu` host it would simply fail to attach.

`privileged` is read by the injector **at startup**. `helm upgrade` only rewrites the
`nsight-injector` ConfigMap, so the deploy workflow explicitly rolls the injector Deployment
afterwards; without that a values change appears applied but is not.

On a host that does need `privileged` (AGX today), the injector adds it, but KFP step pods bake
in `allowPrivilegeEscalation: false` + `drop: [ALL]` + `RuntimeDefault` (not overridable via the
KFP SDK — upstream rejected privileged support), and the `kubeflow` namespace enforces PodSecurity
`baseline`. **Nsight Operator Deploy** handles both automatically:

- deploys `nsight-ape-webhook` (`nsight-ape-webhook/` in this repo) — a mutating webhook that, on
  pods labelled `nvidia-nsight-profile=enabled`, strips `allowPrivilegeEscalation`/all-drop
  caps/`RuntimeDefault` from containers the injector marked `privileged`;
- relaxes the `kubeflow` namespace `pod-security.kubernetes.io/enforce` from `baseline` to
  `privileged` (input `relax_kubeflow_psa`, default `true`; `warn: restricted` is kept).

**Both are gated on `nsight-injector.privileged`** and are not deployed where they are not needed:

| Host | CUDA driver | `privileged` | APE webhook + PSA relax |
|---|---|---|---|
| DGX | `nvidia.ko` RM | `false` | skipped |
| AGX (JetPack 6.2) | `nvgpu` | `true`  | applied |

On the DGX both would be inert anyway — the webhook only patches containers the injector marked
`privileged`, and the injector's added containers carry no `securityContext` at all, so PSA
`baseline` admits them unchanged. Verified by probing a labelled pod in `kubeflow`: three init
containers with `securityContext: null`, the workload container's hardening untouched, no webhook
patch logged. A host that flips from `true` to `false` is converged by the **Remove
privileged-only workarounds** step, which deletes the webhook (Deployment, Service,
ServiceAccount, MWC, ClusterRole/Binding) and restores `enforce=baseline`.

A **preflight** hard-fails the deploy when an RM-served host reports `RmProfilingAdminOnly: 1`
while the values file says `privileged: false`. That combination fails *silently* otherwise —
collection runs, the coordinator reports success, the report exports and verifies, and it simply
contains no GPU records. The check is skipped on `nvgpu` hosts, where the reading is not the gate
(see above); `scripts/ubuntu/preflight-host.sh` keys on the driver — `/dev/nvgpu` or a loaded
`nvgpu` module — rather than on "is this Tegra", so an Orin moved to JetPack 7.x starts being
checked automatically.

---

## The bench: `scripts/nsight/gpu-bench.py`

One committed workload definition serving both capture paths. It is platform tooling, not a
project template — `export-report.sh` uses it as the default `--tool compute` target, so it has
to exist at a fixed path on any host where the helper does.

```bash
python3 scripts/nsight/gpu-bench.py                    # 30 iterations, exit 0  (ncu target)
python3 scripts/nsight/gpu-bench.py --seconds 300      # time-bounded
python3 scripts/nsight/gpu-bench.py --size 8192        # bigger tiles
python3 scripts/nsight/gpu-bench.py --submit           # run it in-cluster as a KFP pipeline
python3 scripts/nsight/gpu-bench.py --compile out.yaml # just compile the pipeline
```

| Flag | Default | Notes |
|---|---|---|
| `--seconds N` | `0` | Time-bounded when > 0, else iteration-bounded. `--submit` uses 300. |
| `--iters N` | `30` | Iterations when not time-bounded. Small on purpose — `ncu` replays 9× per kernel. |
| `--size N` | `4096` | Square matrix dimension. |
| `--kfp-host` | `http://localhost:8080` | KFP endpoint for `--submit`. |
| `--experiment` | `gpu-bench` | KFP experiment name. |

**Why two bounding modes.** Compute needs a *short* run — `ncu` replays each kernel 9 times, so a
300 s loop is unusable. Systems needs a *long* run — the collection window has to land on
something. Same function, different bound.

**Exit codes:** `0` ran · `2` usage/submit error · `3` host prerequisite missing (no PyTorch, or
no CUDA). `3` is deliberately distinct so you can tell a broken host from a broken `ncu`.

### Why the source looks the way it does

`bench_workload` is defined once at module level and wrapped programmatically:

```python
stage = dsl.component(base_image=..., packages_to_install=["nvtx"])(bench_workload)
```

KFP ships the function's **source text** to the container and re-executes the `def` there.
Nothing outside the body may be referenced — so every import is inside the body, and every
signature default is a literal. `iters: int = DEFAULT_ITERS` would raise `NameError` at def time
in the container; `iters: int = 30` is fine. The same rule applies to any KFP component you write.

NVTX is imported with a no-op fallback: the KFP container pip-installs it, but neither host
interpreter has it and `ncu` does not need it.

### Interpreter split on the DGX

| Interpreter | torch | nvtx | kfp |
|---|---|---|---|
| `/usr/bin/python3` | ✅ | ❌ | ✅ |
| pyenv `python3` (pyGlobal 3.12) | ❌ | ❌ | ✅ |

`export-report.sh` picks the first interpreter that can import torch **with CUDA available**
(`$GPU_BENCH_PYTHON` overrides; `$NCU_BENCH_PYTHON` is honoured as a deprecated alias). Use
pyenv `python3` for `--submit`/`--compile`, `/usr/bin/python3` for anything that touches the GPU.

---

## `export-report.sh` reference

The implementation lives at `scripts/nsight/export-report.sh`; `~/bin/nsight-export-report` is a
symlink to it, so every caller and doc keeps using the `~/bin/...` path. Prints
`EXPORTED: <path>` on success.

### Required

| Flag | Meaning |
|---|---|
| `--project <name>` | Project / repo name, verbatim |
| `--run-id <run-NNN>` | Human run id, e.g. `run-059` |
| `--stage <stage>` | Hyphenated KFP component name, or `main` for single-stage |

### Tool selection

| Flag | Default | Meaning |
|---|---|---|
| `--tool systems\|compute` | `systems` | `systems` → operator + `nsys` → `.nsys-rep`; `compute` → host `ncu` → `.ncu-rep` |

### Systems collection

| Flag | Default | Meaning |
|---|---|---|
| `--duration <sec>` | `60` | Collection window |
| `--delay <sec>` | `0` | Pre-collection delay |
| `--no-collect` | — | Skip the session drive; pull an existing MinIO report |
| `--report-id <uuid>` | — | MinIO report uuid (required with `--no-collect`) |
| `--coordinator-url <url>` | `http://localhost:13001` | Coordinator REST endpoint |

`--no-collect` / `--report-id` are **systems-only** — the helper rejects them with `--tool
compute`, which never touches operator storage.

### Compute collection

| Flag | Default | Meaning |
|---|---|---|
| `--ncu-set <set>` | `basic` | `basic`, `detailed`, `full`, `roofline`, `pmsampling`, `nvlink` |
| `--launch-count <N>` | `20` | Number of kernel launches to profile |
| `--kernel-name <spec>` | — | Plain function name, or `regex:<expr>`. Passed to `ncu --kernel-name` |
| `--kernel-regex <expr>` | — | **Deprecated** alias for `--kernel-name regex:<expr>` |
| `-- <command...>` | bundled bench | Workload to profile. Must be last. |

Metric-set cost on this host (`ncu --list-sets`):

| Set | Sections | Est. metrics | Use when |
|---|---|---|---|
| `basic` | LaunchStats, Occupancy, SpeedOfLight, WorkloadDistribution | 213 | Default. "Is it compute- or memory-bound?" |
| `detailed` | + Compute/Memory workload analysis, SourceCounters, Roofline | 1,071 | You have a suspect kernel |
| `full` | + Instruction stats, warp states, scheduler, PM sampling, NVLink | 7,381 | Deep dive, one or two kernels only |
| `roofline` | Roofline charts | — | Arithmetic-intensity questions |
| `pmsampling` | PM sampling | — | Time-correlated counter sampling |
| `nvlink` | NVLink topology/tables | 122 | **Inert on the single-GPU GB10** |

`full` on many kernels takes a very long time — pair it with `--launch-count 1` and a
`--kernel-name` filter.

### Destination

| Flag | Default | Meaning |
|---|---|---|
| `--adhoc` | — | Land under `<root>/<systems\|compute>/<project>-<UTC-ts>/` |
| `--dest-root <dir>` | `~/shared/nsight` (`$NSIGHT_DEST_ROOT`) | Redirect the whole tree off the archive |

### Metadata / linkage

| Flag | Meaning |
|---|---|
| `--kfp-run-id <uuid>` | KFP run UUID → sidecar + MLflow tag |
| `--mlflow-run <name>` | MLflow run name, e.g. `run-059-baseline` — enables MLflow tag linkage |
| `--namespace <ns>` | Stage pod namespace (default `kubeflow`) |
| `--pod <name>` | Stage pod name (metadata only) |
| `--no-sha256` | Skip checksum |

### Failure behaviour

The helper **never reports success when a usable report was not archived**. It exits non-zero if:

- the coordinator is unreachable, or the `default` service tag is held by another session;
- the retrieved `.nsys-rep` shows no GPU kernel activity;
- the `.ncu-rep` fails an `ncu -i … --csv --page raw` readback, or contains no profiled kernels;
- the profiled command itself failed (reported distinctly from an `ncu` failure).

---

## Scenarios

### 1. Profile a real KFP stage (the normal path)

Set the stage's flag in the project `config.yaml` `profiling:` block, then `/kfp-deploy` and
`/kfp-monitor`. When the profiled stage's pod goes `Running`, `/kfp-monitor` launches
`nsight-export-report` in the background so collection overlaps the hot window, and on terminal
state it reports the export path and the auto-chained `/nsight-interpret` analysis.

```yaml
# config.yaml
profiling:
  collection_window_s: 90
  fine-tune: true
  baseline-eval: false
```

### 2. Capture a stage manually while it is hot

```bash
cd ~/git-miramar-labs-org/projects/<project>       # must be the repo — see archive rules
/nsight-export <project> run-NNN <stage> --duration 90
# or directly:
~/bin/nsight-export-report --project <project> --run-id run-NNN --stage <stage> --duration 90
```

### 3. Export a report already sitting in MinIO

Useful when the stage finished before you could fire a collection.

```bash
curl -fsS http://localhost:13001/api/v1/sessions/ | python3 -m json.tool   # find the report uuid
~/bin/nsight-export-report --project <slug> --run-id run-000 --stage main \
  --no-collect --report-id <uuid> --adhoc
```

### 4. Profile an arbitrary host script with Compute

```bash
~/bin/nsight-export-report --project myscript --run-id run-000 --stage main --adhoc \
  --tool compute -- /usr/bin/python3 ~/work/train_step.py --batch 8
```

`-- <command...>` must be last. The command runs as a child of `ncu`.

### 5. Deep-dive one kernel

```bash
~/bin/nsight-export-report --project myscript --run-id run-000 --stage main --adhoc \
  --tool compute --ncu-set full --launch-count 1 \
  --kernel-name 'regex:cutlass.*gemm' -- /usr/bin/python3 ~/work/train_step.py
```

Start from the Systems report's kernel summary to pick the name — profile the kernel that owns
the time, not the one you assume is slow.

### 6. Annotate your own code so the timeline is readable

```python
import nvtx
with nvtx.annotate("data_loading", color="blue"):
    batch = next(loader)
with nvtx.annotate("forward", color="green"):
    loss = model(batch)
```

The operator traces `nvtx` already (`--trace=cuda-sw,nvtx,cublas,cudnn`). Torch's built-in
`torch.cuda.nvtx.range_push/pop` works equally well. NVTX ranges are what turn a wall of kernel
names into a readable phase breakdown, and they are the main reason a capture is worth taking at
all on a complex pipeline.

### 7. Keep throwaway captures out of the archive

```bash
~/bin/nsight-export-report … --dest-root /tmp/scratch/nsight
# or: export NSIGHT_DEST_ROOT=/tmp/scratch/nsight
```

Every other path writes under `~/shared/nsight/`. Use this for validation runs and experiments.

---

## Archive layout

```
~/shared/nsight/
  <project-name>/
    <run-id>/
      baseline-eval/
        profile.nsys-rep       # Nsight Systems report (pulled from the operator's MinIO)
        profile.nsys-rep.sha256
        profile.json           # sidecar: operator session/report ids, sha256,
                               #   kfp_run_id, mlflow_run, collection window
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
pipeline. Existing history is not reorganised — the convention is forward-only.

**`~/shared/nsight/` has exactly three kinds of top-level entry** and nothing else:
`<project-name>/` trees, `systems/`, and `compute/`. A throwaway or validation capture — anything
not tied to a real project's `runs/<run-id>.md` — must land in `systems/` / `compute/` via
`--adhoc`, or off the archive via `--dest-root`. It must never create a new top-level `<name>/`
dir. The helper enforces this: a non-adhoc run whose destination falls under `~/shared/nsight/`
is **refused** unless `./runs/<run-id>.md` exists in `$PWD` (i.e. it is being driven from the
project repo). An already-existing dir left by a past mistake does not satisfy the check.

Ad-hoc dirs are timestamped because `ncu -f -o` force-replaces — without it a same-day re-capture
would silently clobber. Non-adhoc `<project>/<run>/<stage>/` re-captures overwrite in place, by
design, for both tools.

### Retention

`nsight-export-report` never deletes the MinIO copy. MinIO `nsight-reports` is the operator's
working set (~7–30 days); `~/shared/nsight` is kept indefinitely. Prune MinIO only **after** a
verified export exists on disk. A `nsight-retention` systemd timer is a future item.

---

## Host prerequisites

### Allow non-root CUPTI access (one-time, survives reboots)

By default NVIDIA drivers restrict hardware performance counter access to root. KFP pods run as
UID 65532 — without this, `nsys` silently captures zero CUDA kernels and CUPTI returns
`CUPTI_ERROR_INVALID_DEVICE`.

**RM-served hosts only** (the DGX; and Orin from JetPack 7.x, which replaces `nvgpu` with
OpenRM). On a `nvgpu` host — the AGX on JetPack 6.x — this parameter belongs to the display
driver, not to the driver serving CUDA, and setting it achieves nothing; that host runs the
injector `privileged` instead. Check which you have first:

```bash
[ -e /dev/nvgpu ] && echo "nvgpu — skip this section, use privileged: true" || echo "RM — proceed"
```

`scripts/ubuntu/preflight-host.sh` makes this determination for you and registers the fix below
as `nvidia-profiling` when it applies.

```bash
# Check current state (1 = restricted, 0 = open)
grep RmProfilingAdminOnly /proc/driver/nvidia/params

sudo tee /etc/modprobe.d/nvidia.conf <<'EOF'
# Allow non-root CUPTI/Nsight profiling (required for KFP pod UID 65532)
options nvidia NVreg_RestrictProfilingToAdminUsers=0
EOF

sudo reboot        # cannot hot-reload while the GPU is active
```

Verify after reboot: `RmProfilingAdminOnly: 0`.

This persists across reboots via `/etc/modprobe.d/nvidia.conf`. It does **not** persist across
driver reinstalls — re-verify after any NVIDIA driver upgrade. See NVIDIA's
[ERR_NVGPUCTRPERM guidance](https://developer.nvidia.com/nvidia-development-tools-solutions-err_nvgpuctrperm-permission-issue-performance-counters).

### No k3s storage setup is needed

There is no `nsight-reports` PV or PVC. It dated from a removed mechanism (an `nsys`-wrapper
entrypoint image that `cp`'d reports into a hostPath) and exposed the whole archive root
`ReadWriteMany`. **Kubeflow Deploy** now deletes it instead of creating it. `export-report.sh`
`mkdir -p`s its destination, so `~/shared/nsight/` is created on demand.

---

## Troubleshooting

**Report has NVTX ranges and CUDA API calls but zero kernels.**
The classic `--trace=cuda` failure. Check the live operator args (above) — you want `cuda-sw`.
Also check the values file's `privileged` against what the host's CUDA driver actually allows —
`false` on a host that needs `true` (any `nvgpu` Orin) fails silently in exactly this way.

**`ncu` produces nothing and seems to succeed.**
`ncu` is **not on `$PATH`** on the DGX. A bare `ncu` invocation silently does nothing. Use
`/opt/nvidia/nsight-compute/2026.2.1/ncu`. `export-report.sh` resolves the absolute path for you.

**"the `default` service tag is held by another session".**
A previous capture did not release its coordinator session:

```bash
curl -fsS http://localhost:13001/api/v1/sessions/ | python3 -m json.tool
```

Look for a session in `ACTIVE`. The helper releases via a trap, so this normally only happens
after a `kill -9`.

**Compute capture fails while a Systems capture is running.**
Expected — only one session may hold the performance counters. Run them sequentially.

**`gpu-bench: PyTorch not available on this interpreter` (exit 3).**
You are on the pyenv interpreter. Use `/usr/bin/python3`, or set `$GPU_BENCH_PYTHON`.

**`NameError` inside a KFP component at def time.**
The component referenced a module-level name. Every import must be inside the function body and
every signature default must be a literal — see [the bench notes](#why-the-source-looks-the-way-it-does).

**The stage finished before I could capture.**
The report may still be in MinIO — use `--no-collect --report-id <uuid>` (scenario 3). Under
`cuda-sw` a late trigger is fine, so widen the window rather than racing the pod next time.

**Coordinator unreachable on `:13001`.**
`systemctl --user status nsight-portfwd`. Do not `pkill -f port-forward` — it would take down the
KFP, MLflow, and Postgres forwards too. Find the specific PID with `pgrep -af`.

---

## Interpreting reports

```bash
/nsight-interpret <project> run-032        # locate report by project + run name
/nsight-interpret run-032 --ollama llama3  # local model instead of Claude

nsys-ui ~/shared/nsight/<project>/<run-id>/<stage>/profile.nsys-rep
ncu-ui  ~/shared/nsight/compute/<slug>-<ts>/profile.ncu-rep
```

`/nsight-export` auto-chains `/nsight-interpret` on the report it just archived, writing
`analysis-claude.md` alongside it.

Useful raw queries:

```bash
nsys stats --report cuda_gpu_kern_sum <report>.nsys-rep     # kernel time breakdown
nsys stats --report nvtx_sum          <report>.nsys-rep     # NVTX phase breakdown
/opt/nvidia/nsight-compute/2026.2.1/ncu -i <report>.ncu-rep --csv --page raw
/opt/nvidia/nsight-compute/2026.2.1/ncu -i <report>.ncu-rep --page details
```

The DGX has no browser — copy anything you want to view to `~/shared` and open it from the laptop
(`\\spark-79b7\shared\` on Windows, `/mnt/spark-shared` on WSL2).

---

## Official NVIDIA documentation

All links verified 2026-09-07.

**Nsight Systems**
- [User Guide](https://docs.nvidia.com/nsight-systems/UserGuide/index.html) — CLI switches, `nsys stats` reports, timeline semantics
- [Installation Guide](https://docs.nvidia.com/nsight-systems/InstallationGuide/index.html)
- [Release Notes](https://docs.nvidia.com/nsight-systems/ReleaseNotes/index.html)

**Nsight Compute**
- [Nsight Compute docs](https://docs.nvidia.com/nsight-compute/NsightCompute/index.html) — GUI, report sections, metric definitions
- [CLI reference](https://docs.nvidia.com/nsight-compute/NsightComputeCli/index.html) · [command-line options](https://docs.nvidia.com/nsight-compute/NsightComputeCli/index.html#command-line-options)
- [Kernel Profiling Guide](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html) — how to *read* the metrics; roofline, memory workload analysis
- [Release Notes](https://docs.nvidia.com/nsight-compute/ReleaseNotes/index.html)

**Nsight Operator**
- [Nsight Operator docs](https://docs.nvidia.com/nsight-operator/index.html) — injection, coordinator API, storage

**Instrumentation and counters**
- [NVTX](https://nvidia.github.io/NVTX/) — annotation API
- [`torch.cuda.nvtx`](https://pytorch.org/docs/stable/generated/torch.cuda.nvtx.range_push.html)
- [CUPTI](https://docs.nvidia.com/cupti/index.html) — the counter interface both tools sit on
- [CUDA Profiler User's Guide](https://docs.nvidia.com/cuda/profiler-users-guide/index.html)
- [ERR_NVGPUCTRPERM](https://developer.nvidia.com/nvidia-development-tools-solutions-err_nvgpuctrperm-permission-issue-performance-counters) — the permission issue behind `RmProfilingAdminOnly`

There is also a local reference asset: [`ML_Profiling_Topics_Nsight_GB10.pdf`](ML_Profiling_Topics_Nsight_GB10.pdf).
