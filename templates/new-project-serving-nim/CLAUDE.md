# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a NIM model serving project on the Miramar platform (GKE or K3s on DGX).

## Key files

| File                       | Purpose                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------ |
| `serving-config.yaml`      | Project config — NIM org, model name, DGX image name, and image tags per host       |
| `k8s/nim-k3s.yaml`         | K3s manifest — deployment (NIM, uses `dgx_image_name` which may include `-dgx-spark` suffix), ClusterIP service |
| `k8s/nim.yaml`             | GKE manifest — deployment (NIM, standard L4 image using `model_name`), ClusterIP service |
| `smoke_test_prompts.jsonl` | Prompts to run after deploy to confirm model is responding                           |

## serving-config.yaml fields

```yaml
nim:
  org: "..."            # NGC org (e.g. nvidia, meta, minimax-ai, mit)
  model_name: "..."     # base model name used for GKE (no -dgx-spark suffix)
  dgx_image_name: "..." # full DGX image name (e.g. llama-3.1-8b-instruct-dgx-spark)
  dgx_image_tag: "..."  # DGX image tag (e.g. 1.0.0-variant)
  gke_image_tag: "..."  # GKE image tag (e.g. 1.0.0)
```

`dgx_image_name` and `model_name` differ for NIMs that use the `-dgx-spark` suffix (e.g. `llama-3.1-8b-instruct-dgx-spark` vs `llama-3.1-8b-instruct`). For NIMs without a DGX-specific variant (boltz2, cosmos-reason2-8b, etc.) they are the same value.

## GPU cost

L4 spot GPU node pool is not persistent on GKE. Expanded on every `deploy.yaml` (host=gke) run and torn down on every `undeploy.yaml` (host=gke) run. L4 spot costs ~$0.22/hr — always undeploy when done.

On K3s (DGX), there is no node pool cost but the GPU is occupied while the pod runs. Undeploy when done to free GPU memory.

## Workflows

| Workflow        | Inputs                          | Effect                                                            |
| --------------- | ------------------------------- | ----------------------------------------------------------------- |
| `deploy.yaml`   | `host` (dgx\|gke, default: dgx) | Pull NIM image from nvcr.io, deploy, run smoke tests             |
| `undeploy.yaml` | `host` (dgx\|gke, default: dgx) | Remove deployment; GKE also restores GPU node pool               |

## AGX not supported

NIM LLM containers on NGC are `linux/amd64` only — no `linux/arm64` images exist. DGX Spark uses a special `-dgx-spark` image variant compiled for the GB10 Blackwell GPU.

## NIM cache

The NIM container caches model weights in `/opt/nim/.cache`. On DGX, this maps to `/home/aaron/shared/nim-cache` (hostPath). Model weights can be several GBs — first startup downloads them.

## Port-forward access

```bash
kubectl port-forward svc/nim 8000:8000 -n {{PROJECT_NAME}}
curl http://localhost:8000/v1/models
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"{{SERVED_MODEL_NAME}}","messages":[{"role":"user","content":"Hello"}],"max_tokens":200}'
```

## Secrets required

- `secrets.NGC_API_KEY` — NGC API key for pulling from nvcr.io (org-level secret)
- `secrets.MIRAMAR_ORG_ADMIN_PAT` — for setting repo variables
- `secrets.WIF_PROVIDER` / `secrets.GCP_SERVICE_ACCOUNT` — GKE auth (GKE target only)
- `secrets.MIRAMAR_ORG_ADMIN_PAT` — for triggering gke-expand-gpu (GKE target only)
