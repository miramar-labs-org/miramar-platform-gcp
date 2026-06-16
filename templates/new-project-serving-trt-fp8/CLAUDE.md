# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — serves an FP8-quantized model checkpoint via vLLM on the Miramar platform.

## Key files

| File                             | Purpose                                                                                    |
| -------------------------------- | ------------------------------------------------------------------------------------------ |
| `serving-config.yaml`            | Project config — compression source project, run ID, vLLM settings                        |
| `Dockerfile.serve`               | GKE image — checkpoint baked in at `/model/` at build time                                 |
| `k8s/vllm-trt-fp8-k3s.yaml`     | K3s manifest — hostPath volume for local checkpoint, vLLM with `--quantization=fp8`        |
| `k8s/vllm-trt-fp8.yaml`         | GKE manifest — checkpoint in image at `/model/`, L4 nodeSelector                          |
| `smoke_test_prompts.jsonl`       | Prompts to run after deploy to confirm model is responding                                 |

## GPU cost

L4 spot GPU node pool is not persistent on GKE. Expanded on every deploy (host=gke) run and torn down on every undeploy (host=gke) run.

## Workflows

| Workflow          | Inputs                                          | Effect                                                                  |
| ----------------- | ----------------------------------------------- | ----------------------------------------------------------------------- |
| `build-push.yaml` | `run_id` (default: latest)                      | Stage FP8 checkpoint, build vLLM image with checkpoint at /model/, push to GAR |
| `deploy.yaml`     | `host` (dgx\|agx\|gke), `run_id`, `image_tag`  | Deploy FP8-vLLM (hostPath on K3s, baked image on GKE), smoke test      |
| `undeploy.yaml`   | `host` (dgx\|agx\|gke)                         | Remove deployment; GKE also restores GPU node pool                      |

## Model path (DGX/AGX)

The FP8 checkpoint is read from:
```
~/shared/huggingface-kfp/quantization/<compression_project>/<run_id>/
```
Set `compression.project` and `compression.run_id` in `serving-config.yaml`.
Use `run_id: latest` to automatically pick the most recent run directory.

## Port-forward access

```bash
kubectl port-forward svc/vllm 8000:8000 -n {{PROJECT_NAME}}
curl http://localhost:8000/v1/models
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"{{SERVED_MODEL_NAME}}","messages":[{"role":"user","content":"Hello"}],"max_tokens":200}'
```

## Secrets required

- `secrets.WIF_PROVIDER` / `secrets.GCP_SERVICE_ACCOUNT` — GCP auth
- `secrets.MIRAMAR_ORG_ADMIN_PAT` — for setting repo variables and triggering gke-expand-gpu
