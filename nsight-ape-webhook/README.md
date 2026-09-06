# nsight-ape-webhook

A tiny (pure-stdlib Go) **mutating admission webhook** that lets the NVIDIA Nsight
Operator's process-hook injection work on **Kubeflow Pipelines step pods** — or any
pod hardened to the Pod Security Standards `baseline`/`restricted` profiles.

## The problem

Full GB10 (DGX Spark, Blackwell) hardware GPU kernel trace requires
`securityContext.privileged: true` on the profiled container (~7 CUDA kernel
records without it, ~47 with). The Nsight Operator's injector webhook
(`nsight-injector-webhook`) stamps `privileged: true` onto every container of a
pod labelled `nvidia-nsight-profile=enabled`.

Kubeflow Pipelines bakes the opposite into every step container, from two
independent sources that **cannot be overridden through the KFP SDK**:

| Source | Field |
|---|---|
| `kfp` SDK compiler (`main` container) + Go compiler (PR #12782) | `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault` |
| Argo executor `wait` sidecar — `workflow-controller-configmap` `executor.securityContext` | same |

That produces two failures, in admission order:

1. **API object validation** rejects `privileged: true` + `allowPrivilegeEscalation: false`:
   `cannot set 'allowPrivilegeEscalation' to false and 'privileged' to true`.
2. **PodSecurity admission** — the `kubeflow` namespace carries
   `pod-security.kubernetes.io/enforce: baseline` (from upstream KFP kustomize),
   and `baseline` forbids `privileged: true` outright.

Upstream KFP has **deliberately rejected** privileged support (#12560 / #12205
closed; #12577 closed unmerged with `do-not-merge/hold`; the proto `SecurityContext`
reserves fields 3/4/5 "to comply with PSS baseline"; #12782 hardens the other way).
So there is no SDK fix coming — this webhook + a namespace-scoped PSA relax are the
supported path.

## What this webhook does

Runs with `reinvocationPolicy: IfNeeded`, so it is re-invoked **after** the Nsight
injector mutates the pod, regardless of admission-plugin ordering. For every
container (init / regular / ephemeral) whose `securityContext.privileged == true`,
it emits an idempotent JSON-Patch that:

- removes `securityContext.allowPrivilegeEscalation` — resolves failure (1)
- removes an all-drop `securityContext.capabilities` (keeps an explicit `add` list,
  only dropping the `drop` sub-list) — `privileged` + `drop: [ALL]` is contradictory
- rewrites `seccompProfile: RuntimeDefault` → `Unconfined` so `perf_event_open` is
  not filtered

It only ever touches containers the injector already marked `privileged`, on pods
that carry `nvidia-nsight-profile=enabled` (webhook `objectSelector`). It
**fails open** (`failurePolicy: Ignore`): if the webhook is down, pod creation
proceeds and a profiling run simply fails the way it does today.

Failure (2) is **not** solved here — it needs a namespace-level PSA change. The
`Nsight Operator Deploy` workflow relaxes `kubeflow`'s `enforce` label from
`baseline` to `privileged` (input `relax_kubeflow_psa`, default `true`) and
`Nsight Operator Undeploy` restores it to `baseline`. `warn: restricted` is left
in place throughout.

## Cert bootstrap

No cert-manager on the cluster. On startup the binary self-signs a serving
certificate (also its own CA), then `PATCH`es its own
`MutatingWebhookConfiguration`'s `clientConfig.caBundle` via the in-cluster API
using its ServiceAccount token — the same pattern `nsight-injector` uses. The
ClusterRole is scoped to `get`/`patch` on the single MWC by name.

## Layout

| Path | What |
|---|---|
| `main.go` | the webhook (stdlib only; no `go.sum`) |
| `main_test.go` | `buildPatch` table tests + double-pass no-op test |
| `Dockerfile` | distroless-static, non-root, multi-arch |
| `manifests/webhook.yaml` | SA + ClusterRole/Binding + Deployment + Service + MutatingWebhookConfiguration; `__IMAGE__` token substituted by the deploy workflow |

## Lifecycle

- **Build:** `Build Nsight APE Webhook Image` workflow (push to `main` touching
  `nsight-ape-webhook/**`, or `workflow_dispatch`) → multi-arch image at
  `ghcr.io/miramar-labs-org/nsight-ape-webhook:{latest,sha-<short>}`.
- **Deploy:** applied automatically by `Nsight Operator Deploy` /
  `Nsight Operator Deploy (GKE)` right after the Helm release (input
  `ape_webhook_tag`, default `latest`).
- **Teardown:** `Nsight Operator Undeploy` deletes the (cluster-scoped)
  `MutatingWebhookConfiguration` + ClusterRole/Binding **before** deleting the
  `nsight-operator` namespace, and restores the `kubeflow` PSA label.

## Local checks

```sh
cd nsight-ape-webhook
go vet ./...
go test ./...
```
