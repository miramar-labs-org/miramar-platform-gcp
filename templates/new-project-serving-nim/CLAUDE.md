# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a NIM model serving project on the Miramar platform (GKE or K3s on DGX).

## Key files

| File                       | Purpose                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------ |
| `serving-config.yaml`      | Project config — NIM org, model name, image tags per host                            |
| `k8s/nim-k3s.yaml`         | K3s manifest — deployment (NIM, DGX Spark -dgx-spark variant), ClusterIP service    |
| `k8s/nim.yaml`             | GKE manifest — deployment (NIM, standard L4 image), ClusterIP service               |
| `smoke_test_prompts.jsonl` | Prompts to run after deploy to confirm model is responding                           |

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
