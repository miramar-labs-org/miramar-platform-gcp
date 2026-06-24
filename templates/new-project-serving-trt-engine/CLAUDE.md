# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — serves a pre-compiled TRT-LLM engine via `trtllm-serve` on the Miramar platform.

## Key files

| File                       | Purpose                                                                                      |
| -------------------------- | -------------------------------------------------------------------------------------------- |
| `serving-config.yaml`      | Project config — compression project/run, HF model path for tokenizer                        |
| `Dockerfile.serve`         | GKE image — engine_l4/ baked in at `/engine/` at build time                                 |
| `k8s/trtllm-k3s.yaml`      | K3s manifest — engine + HF model hostPath volumes, `trtllm-serve --backend tensorrt`        |
| `k8s/trtllm.yaml`          | GKE manifest — engine in image at `/engine/`, L4 nodeSelector                               |
| `smoke_test_prompts.jsonl` | Prompts to run after deploy to confirm model is responding                                   |

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

## serving-config.yaml fields

| Field                    | Required | Notes                                                                 |
| ------------------------ | -------- | --------------------------------------------------------------------- |
| `model.served_model_name`| yes      | HuggingFace model ID (metadata only — model ID in /v1/models is `engine`) |
| `model.hf_path`          | yes      | Path to HF model dir relative to `~/shared/huggingface-kfp/` — used for `--tokenizer` |
| `compression.project`    | yes      | Name of the compression pipeline project that produced the engine    |
| `compression.run_id`     | yes      | Run directory name, or `latest` to auto-detect most recent           |

## Engine path (DGX/AGX)

Engines are read from:
```
~/shared/huggingface-kfp/engines/<compression_project>/<run_id>/engine_<target_gpu>/
```

The engine dir must contain `rank0.engine` and `config.json`. Tokenizer files are NOT required in the engine dir — the HF model dir is mounted separately at `/model` and passed via `--tokenizer /model`.

## TRT-LLM runtime notes

- **Image**: `nvcr.io/nvidia/tensorrt-llm/release:1.2.1` (pinned; requires `nvcr-pull` secret)
- **Binary**: `trtllm-serve` (not `python3 -m tensorrt_llm.serve` — that module has no `__main__`)
- **Backend**: `--backend tensorrt` required for compiled engines; default is `pytorch`
- **Batch size**: `--max_batch_size` is read from `engine/config.json build_config.max_batch_size` at deploy time; runtime value cannot exceed compile-time value
- **Tokenizer**: `--tokenizer /model` where `/model` is the HF model dir; needed so `OpenAIServer` can load `model_type` from HF `config.json`
- **Model ID**: `/v1/models` returns `engine` (the engine dir name), not the HF model ID
- **Health endpoint**: `/health` (returns 200); `/v1/health/ready` and `/v1/health/live` return 404 in 1.2.1
- **LD_LIBRARY_PATH**: must be set explicitly in K8s manifest — k3s containerd does not inject `/usr/local/tensorrt/lib` the way Docker's NVIDIA runtime does

## Port-forward access

```bash
kubectl port-forward svc/trtllm 8000:8000 -n {{PROJECT_NAME}}
curl http://localhost:8000/v1/models          # returns id: "engine"
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"engine","messages":[{"role":"user","content":"Hello"}],"max_tokens":200}'
```

## Secrets required

- `secrets.NGC_API_KEY` — for pulling nvcr.io/nvidia/tensorrt-llm (K3s targets)
- `secrets.WIF_PROVIDER` / `secrets.GCP_SERVICE_ACCOUNT` — GCP auth
- `secrets.MIRAMAR_ORG_ADMIN_PAT` — for setting repo variables and triggering gke-expand-gpu
