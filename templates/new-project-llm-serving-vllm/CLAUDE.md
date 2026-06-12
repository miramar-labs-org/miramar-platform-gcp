# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a vLLM LoRA adapter serving project on the Miramar platform (GKE).

## Key files

| File | Purpose |
|---|---|
| `serving-config.yaml` | Project config — base model, stable alias, adapter manifest URI, vLLM settings, GKE deployment config |
| `Dockerfile.serve` | Thin image (no model baked in) — model and adapter are injected at runtime |
| `k8s/vllm.yaml` | K8s manifest — namespace, deployment (init container + vLLM), ClusterIP service |
| `smoke_test_prompts.jsonl` | 3–5 prompts to run after deploy to confirm model is responding |

## GPU cost

The L4 spot GPU node pool is **not persistent**. It is expanded on every `deploy.yaml` run and torn down on every `undeploy.yaml` run. L4 spot costs ~$0.22/hr — always run `undeploy.yaml` when done.

**Always undeploy after testing.** Do not leave the GPU pool expanded.

## Workflows

| Workflow | Trigger | Effect |
|---|---|---|
| `build-push.yaml` | `workflow_dispatch` | Build `Dockerfile.serve` → push to GAR as `:latest` + commit SHA |
| `deploy.yaml` | `workflow_dispatch` (inputs: `image_tag`, `manifest_uri`) | Expand L4 spot, deploy vLLM to GKE, run smoke tests |
| `undeploy.yaml` | `workflow_dispatch` | Remove deployment, restore GPU node pool (stop costs) |

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

The init container re-fetches the manifest and pulls the new adapter on startup.

## Namespace

The K8s namespace is `{{PROJECT_NAME}}`. It is created idempotently by `deploy.yaml`.
`undeploy.yaml` removes the deployment and service but does **not** delete the namespace.

## Secrets

`deploy.yaml` creates the `hf-token` K8s secret from `secrets.HF_TOKEN` if it does not exist.
Ensure `HF_TOKEN` is set as a GitHub Actions secret on this repo (or inherited from the org).
