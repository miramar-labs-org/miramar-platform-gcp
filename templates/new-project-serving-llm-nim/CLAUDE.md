# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — model serving via NVIDIA Multi-LLM NIM on DGX Spark K3s.
Uses `nvcr.io/nim/nvidia/llm-nim` runtime. Two source modes, auto-detected from `model.model_path`:

- **local** (`/abs/path`) — model mounted from DGX host via hostPath volume; TRT-LLM engine compiled on first start, cached in `~/shared/nim-cache`
- **hf** (`hf://org/model` or `org/model`) — NIM downloads weights from HuggingFace; optional `HF_TOKEN` secret

## Key files

| File | Purpose |
|---|---|
| `serving-config.yaml` | `model.model_path` (local or hf), `model.container_name`, `model.served_model_name`, `nim.image_tag` |
| `k8s/nim-local-k3s.yaml` | K3s manifest for local mode (hostPath volume, NGC_API_KEY secret) |
| `k8s/nim-hf-k3s.yaml` | K3s manifest for HF mode (no model volume, HF_TOKEN secret optional) |
| `smoke_test_prompts.jsonl` | Prompts sent after deploy to confirm the endpoint responds |

## Workflows

| Workflow | Job ID | Effect |
|---|---|---|
| `deploy.yaml` | `deploy-llm-nim-dgx` | Detect mode → preflight → unserve Ollama → apply manifest → 60-min rollout wait → smoke test → set `DGX_SERVING_ACTIVE=true` → wire Open WebUI |
| `undeploy.yaml` | `undeploy-llm-nim-dgx` | Delete deployment + service → set `DGX_SERVING_ACTIVE=false` → clear Open WebUI backend |

## To update the model

1. Edit `model.model_path` (and optionally `model.served_model_name`) in `serving-config.yaml`
2. Run the `deploy.yaml` workflow — it re-detects mode and applies the new path on every deploy

## DGX K3s only

No GKE manifest. Do not add a GKE deploy target.

## Serving a fine-tuned model

If this project serves a model produced by a KFP fine-tune pipeline, point `model_path` at the **merged full-weights** directory — not the LoRA adapter. Adapters live at:
```
/home/aaron/shared/huggingface-kfp/adapters/<pipeline-name>/chunk-N/
```
Merged weights live at:
```
/home/aaron/shared/huggingface-kfp/models/<pipeline-name>/
```
The NIM runtime requires full model weights. Merge the adapter first if needed.

## Secrets required

- `secrets.NGC_API_KEY` — NGC API key for pulling `nvcr.io/nim/nvidia/llm-nim`
- `secrets.HF_TOKEN` — HuggingFace token (hf mode only; optional for public models)
- `secrets.MIRAMAR_ORG_ADMIN_PAT` — for setting `DGX_SERVING_ACTIVE` and triggering Open WebUI redeploy
