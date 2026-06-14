# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a vLLM LoRA adapter serving project on the Miramar platform (GKE or K3s on DGX/AGX).

## Key files

| File                       | Purpose                                                                                               |
| -------------------------- | ----------------------------------------------------------------------------------------------------- |
| `serving-config.yaml`      | Project config — base model, stable alias, adapter manifest URI, vLLM settings                        |
| `Dockerfile.serve`         | Thin image (no model baked in) — model and adapter are injected at runtime                            |
| `k8s/vllm.yaml`            | GKE manifest — namespace, deployment (init container + vLLM), ClusterIP service                       |
| `k8s/vllm-k3s.yaml`        | K3s manifest — deployment (hostPath adapter, no init container), ClusterIP service                    |
| `smoke_test_prompts.jsonl` | 3–5 prompts to run after deploy to confirm model is responding                                        |

## GPU cost

The L4 spot GPU node pool is **not persistent** on GKE. It is expanded on every `deploy.yaml` (host=gke) run and torn down on every `undeploy.yaml` (host=gke) run. L4 spot costs ~$0.22/hr — always run `undeploy.yaml` when done.

On K3s (DGX/AGX), there is no node pool cost — but the GPU is occupied while the pod is running. Always undeploy when done to free GPU memory for other workloads.

## Workflows

| Workflow          | Inputs                                              | Effect                                                                      |
| ----------------- | --------------------------------------------------- | --------------------------------------------------------------------------- |
| `build-push.yaml` | `registry` (gar\|ghcr, default: gar)               | Build `Dockerfile.serve` → push to GAR (gar) or GHCR (ghcr) as `:latest` + SHA |
| `deploy.yaml`     | `host` (gke\|dgx\|agx, default: gke), `registry` (gar\|ghcr, default: gar), `image_tag`, `manifest_uri` | Deploy vLLM to target host, run smoke tests |
| `undeploy.yaml`   | `host` (gke\|dgx\|agx, default: gke)               | Remove deployment; GKE also restores GPU node pool                          |

**Registry mapping:** use `registry=gar` with `host=gke`; use `registry=ghcr` with `host=dgx` or `host=agx`.

Run order: `build-push.yaml` (once, or on Dockerfile changes) → `deploy.yaml` → `undeploy.yaml`.

## Adapter manifest

The `manifest_uri` in `serving-config.yaml` points to a `manifest.json` produced by the `publish-adapter.yaml`
workflow in the fine-tuning project. The deploy workflow validates `eval_passed` and `safety_passed` from
the manifest — deploy will fail if either is false.

To serve a different run's adapter, update `adapter.manifest_uri` in `serving-config.yaml` and re-run `deploy.yaml`.

## Stable model alias

Clients always use the stable `served_model_name` alias (e.g. `biomistral-onc`), never the raw model path.
This allows swapping adapters or base models without changing client code.

## Cold-start time

First deploy downloads the base model from HuggingFace Hub into the pod's `/tmp/hf-cache` volume.
This takes **5–10 minutes** depending on model size and network conditions.
Subsequent deploys within the same node lifecycle reuse the downloaded weights.

## Port-forward access (local testing)

```bash
kubectl port-forward svc/vllm 8000:8000 -n {{PROJECT_NAME}}

# Check available models
curl http://localhost:8000/v1/models

# Chat completion
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"{{SERVED_MODEL_NAME}}","messages":[{"role":"user","content":"<your prompt>"}],"max_tokens":200}'
```

On GKE, run this from your laptop via SSH tunnel (DGX handles `kubectl` commands directly).
On K3s (DGX/AGX), run this on the DGX/AGX host or forward through an SSH tunnel.

## Adapter swap procedure

To serve a different adapter (e.g. run-002 after run-001):

1. Run `publish-adapter.yaml` on the FT project for the new run
2. Update `serving-config.yaml`:
   ```yaml
   adapter:
     manifest_uri: gs://miramar-platform-ft-adapters/<project>/<run>/manifest.json
   ```
3. Commit and push
4. Run `deploy.yaml` (a new rollout replaces the running pod)

On GKE, the init container re-fetches the manifest and pulls the new adapter on startup.
On K3s, the deploy workflow pre-fetches the adapter to `/tmp/vllm-adapters/{{PROJECT_NAME}}/` on the host.

## Namespace

The K8s namespace is `{{PROJECT_NAME}}`. It is created idempotently by `deploy.yaml`.
`undeploy.yaml` removes the deployment and service but does **not** delete the namespace.

## Secrets

`deploy.yaml` creates the `hf-token` K8s secret from `secrets.HF_TOKEN` if it does not exist.
On K3s, it also creates the `ghcr-pull` image pull secret from `secrets.MIRAMAR_ORG_GHCR_PAT`.
Ensure `HF_TOKEN` is set as a GitHub Actions secret on this repo (or inherited from the org).
