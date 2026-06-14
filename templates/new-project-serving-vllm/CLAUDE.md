# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a vLLM LoRA adapter serving project on the Miramar platform (GKE or K3s on DGX/AGX).

## Key files

| File                       | Purpose                                                                                               |
| -------------------------- | ----------------------------------------------------------------------------------------------------- |
| `serving-config.yaml`      | Project config — base model, stable alias, adapter source (ft_project), vLLM settings                |
| `Dockerfile.serve`         | Thin image — adapter baked in at `/adapter/` at build time; base model fetched from HF Hub at runtime |
| `k8s/vllm.yaml`            | GKE manifest — namespace, deployment (vLLM), ClusterIP service                                       |
| `k8s/vllm-k3s.yaml`        | K3s manifest — deployment (vLLM, GHCR image pull), ClusterIP service                                 |
| `smoke_test_prompts.jsonl` | 3–5 prompts to run after deploy to confirm model is responding                                        |

## GPU cost

The L4 spot GPU node pool is **not persistent** on GKE. It is expanded on every `deploy.yaml` (host=gke) run and torn down on every `undeploy.yaml` (host=gke) run. L4 spot costs ~$0.22/hr — always run `undeploy.yaml` when done.

On K3s (DGX/AGX), there is no node pool cost — but the GPU is occupied while the pod is running. Always undeploy when done to free GPU memory for other workloads.

## Workflows

| Workflow          | Inputs                                              | Effect                                                                                    |
| ----------------- | --------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `build-push.yaml` | `host` (gke\|dgx\|agx, default: dgx)               | Find latest gate-passing run from `ft_project`, bake adapter into image, push to registry |
| `deploy.yaml`     | `host` (gke\|dgx\|agx, default: dgx), `image_tag`  | Deploy vLLM to target host (registry inferred from host), run smoke tests                 |
| `undeploy.yaml`   | `host` (gke\|dgx\|agx, default: dgx)               | Remove deployment; GKE also restores GPU node pool                                        |

Run order: `build-push.yaml` (once after ft-eval gate passes, or on Dockerfile changes) → `deploy.yaml` → `undeploy.yaml`.

## Adapter source

The adapter is baked into the Docker image at build time — it is not pulled at runtime.

`build-push.yaml` reads `adapter.ft_project` from `serving-config.yaml`, then scans
`~/shared/huggingface-kfp/runs/<ft_project>/*/gate_result.json` (via SMB on the wsl2 runner)
for the most recent run where `eval_passed == true` and `safety_passed == true`. It copies
that adapter into the Docker build context and runs `docker build`, producing an image that
contains the adapter at `/adapter/`.

The image tag encodes the ft run: `<run_id>-<commit_sha[:8]>` (e.g. `run-001-a1b2c3d4`).

If no gate-passing run exists, `build-push.yaml` fails with a clear error. Run the ft-eval
pipeline and wait for the gate to pass before building the serving image.

## Stable model alias

Clients always use the stable `served_model_name` alias (e.g. `qwen25-arc`), never the raw model path.
This allows swapping adapters or base models without changing client code.

## Cold-start time

First deploy downloads the base model from HuggingFace Hub into the pod's `/tmp/hf-cache` volume.
This takes **5–10 minutes** depending on model size and network conditions.
The adapter is already in the image at `/adapter/` — no additional download needed at startup.
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

To serve a different adapter (e.g. after a new ft-eval run passes the gate):

1. Run `build-push.yaml` — it automatically finds the latest gate-passing run and bakes it in
2. Run `deploy.yaml` with the new image tag (or use `latest`)

No config edits needed — `build-push.yaml` always picks the latest passing run automatically.
To pin a specific run, pass a specific image tag to `deploy.yaml`.

## Namespace

The K8s namespace is `{{PROJECT_NAME}}`. It is created idempotently by `deploy.yaml`.
`undeploy.yaml` removes the deployment and service but does **not** delete the namespace.

## Secrets

`deploy.yaml` creates the `hf-token` K8s secret from `secrets.HF_TOKEN` if it does not exist.
On K3s, it also creates the `ghcr-pull` image pull secret from `secrets.MIRAMAR_ORG_GHCR_PAT`.
Ensure `HF_TOKEN` is set as a GitHub Actions secret on this repo (or inherited from the org).
