# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — serves compiled TRT-LLM engine artifacts via `tensorrt_llm.serve` on the Miramar platform.

## Key files

| File                       | Purpose                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------ |
| `serving-config.yaml`      | Project config — compression source project, run ID                                  |
| `Dockerfile.serve`         | GKE image — engine_l4/ baked in at `/engine/` at build time                         |
| `k8s/trtllm-k3s.yaml`      | K3s manifest — hostPath volume for arch-specific engine subdir, tensorrt_llm.serve   |
| `k8s/trtllm.yaml`          | GKE manifest — engine in image at `/engine/`, L4 nodeSelector                       |
| `smoke_test_prompts.jsonl` | Prompts to run after deploy to confirm model is responding                           |

## GPU cost

L4 spot GPU node pool is not persistent on GKE. Expanded on every deploy (host=gke) run and torn down on every undeploy (host=gke) run.

## Engine architecture mapping

TRT-LLM engines are compiled for a specific GPU architecture. This template maps:

| Host  | target_gpu | Engine subdir  | GPU             |
|-------|------------|----------------|-----------------|
| `dgx` | `gb10`     | `engine_gb10/` | DGX Spark GB10  |
| `agx` | `sm87`     | `engine_sm87/` | AGX Orin sm_87  |
| `gke` | `l4`       | `engine_l4/`   | GKE L4 sm_89    |

## Workflows

| Workflow          | Inputs                                       | Effect                                                             |
| ----------------- | -------------------------------------------- | ------------------------------------------------------------------ |
| `build-push.yaml` | `run_id` (default: latest)                   | Stage engine_l4/, build TRT-LLM image with engine at /engine/, push to GAR |
| `deploy.yaml`     | `host` (dgx\|agx\|gke), `run_id`, `image_tag` | Deploy TRT-LLM server (hostPath on K3s, baked image on GKE)      |
| `undeploy.yaml`   | `host` (dgx\|agx\|gke)                      | Remove deployment; GKE also restores GPU node pool                 |

## Engine path (DGX/AGX)

Engines are read from:
```
~/shared/huggingface-kfp/engines/<compression_project>/<run_id>/engine_<target_gpu>/
```

## Open decision: TRT-LLM base image

The K3s manifest uses `nvcr.io/nvidia/tensorrt-llm:latest` directly (requires `nvcr-pull` NGC secret). If this image pull is unreliable, consider mirroring it to GHCR once as a platform image.

## Port-forward access

```bash
kubectl port-forward svc/trtllm 8000:8000 -n {{PROJECT_NAME}}
curl http://localhost:8000/v1/models
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"{{SERVED_MODEL_NAME}}","messages":[{"role":"user","content":"Hello"}],"max_tokens":200}'
```

## Secrets required

- `secrets.NGC_API_KEY` — for pulling nvcr.io/nvidia/tensorrt-llm (K3s targets)
- `secrets.WIF_PROVIDER` / `secrets.GCP_SERVICE_ACCOUNT` — GCP auth
- `secrets.MIRAMAR_ORG_ADMIN_PAT` — for setting repo variables and triggering gke-expand-gpu
