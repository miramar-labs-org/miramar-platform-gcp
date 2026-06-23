# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — local model serving via NVIDIA Multi-LLM NIM on DGX Spark K3s.
Not an NGC catalog NIM. Uses `nvcr.io/nim/nvidia/llm-nim` runtime with a host-mounted model dir.

## Key files

| File | Purpose |
|---|---|
| `serving-config.yaml` | Model path, container name, served name, NIM image tag |
| `k8s/nim-local-k3s.yaml` | K3s Deployment + Service manifest (placeholders substituted at deploy time) |
| `scripts/list-profiles.sh` | Local script to validate NIM compatibility before deploy |
| `smoke_test_prompts.jsonl` | Prompts sent after deploy to confirm the endpoint responds |

## Workflows

| Workflow | Effect |
|---|---|
| `deploy.yaml` | List profiles → deploy to K3s → smoke test → wire Open WebUI |
| `undeploy.yaml` | Remove deployment, free GPU, reset Open WebUI backend |

## Model path from a fine-tune run

If this project serves a model produced by a KFP fine-tune pipeline, the adapter lives at:
```
/home/aaron/shared/huggingface-kfp/adapters/<pipeline-name>/chunk-N/
```

For a merged (full weights) model, it lives at:
```
/home/aaron/shared/huggingface-kfp/models/<pipeline-name>/
```

Update `model.host_path` in `serving-config.yaml` to point at the merged weights directory.
The NIM runtime requires full model weights, not LoRA adapters — merge first if needed.

## To update the model version

1. Edit `model.host_path` (and optionally `model.served_model_name`) in `serving-config.yaml`
2. Run `bash scripts/list-profiles.sh` to confirm compatibility
3. Run the `deploy.yaml` workflow — it substitutes the new path on every deploy

## DGX-only

Model host path is a local DGX path — no GKE manifest exists. Do not add a GKE deploy target.

## Secrets required

- `secrets.NGC_API_KEY` — NGC API key for pulling `nvcr.io/nim/nvidia/llm-nim`
- `secrets.MIRAMAR_ORG_ADMIN_PAT` — for setting repo/org variables and triggering Open WebUI redeploy
