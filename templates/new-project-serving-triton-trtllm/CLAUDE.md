# CLAUDE.md — serving-triton-trtllm

This project serves a compiled TensorRT-LLM (TRT-LLM) engine via NVIDIA Triton Inference
Server using the `trtllm-python-py3` backend. The engine is GPU-arch specific and baked
into the image at build time — no model download at startup.

## What this project is

A **Stage 9** serving template that wraps a TRT-LLM engine (produced by a
`serving-trt-*` compression pipeline) in Triton's Python backend. Compared to
`serving-triton-vllm` (Stage 8), this variant:

- Does not download base weights at startup (engine is pre-compiled and baked in)
- Does not support LoRA adapters (quantized engines are single-model)
- Starts in ~30 seconds instead of 5–10 minutes (no HF Hub download)
- Is strictly faster at inference time (TRT-LLM compiled execution vs. PyTorch)
- Requires a recompile when the base model or target GPU changes

## Directory layout

```
serving-config.yaml            # Runtime config: model name, engine source, Triton image
Dockerfile.serve               # FROM tritonserver:*-trtllm-python-py3; COPY engine/ model_repo/
model_repo/
  model/
    config.pbtxt               # Triton Python backend config (inputs/outputs)
    1/
      model.py                 # TritonPythonModel: TRT-LLM LLM API, synchronous
k8s/
  triton.yaml                  # GKE manifest: L4 spot, emptyDir (no HF cache needed)
  triton-k3s.yaml              # DGX K3s manifest: GHCR image, Recreate strategy
.github/workflows/
  build-push.yaml              # Stage engine → Dockerfile → GAR (GKE) or GHCR (DGX)
  deploy.yaml                  # Deploy to GKE or DGX; smoke test; register model router
  undeploy.yaml                # Deregister from router; delete namespace; restore GPU pool
smoke_test_prompts.jsonl       # Three clinical prompts in Triton tensor JSON format
README.md
CLAUDE.md                      # This file
```

## Platform compatibility

| Host | Supported | Image | Notes |
|------|-----------|-------|-------|
| GKE (L4) | Yes | GAR (`linux/amd64`) | Engine: `engine_l4/` (sm_89) |
| DGX Spark | Yes | GHCR (native arm64) | Engine: `engine_gb10/` (GB10 Blackwell) |
| AGX Orin | No | — | `trtllm-python-py3` not validated for sm_87 arm64 |
| WSL2 | No | — | No GPU in runner |

DGX Spark (Grace+Blackwell, arm64) uses the GB10 Blackwell engine. The
`nvcr.io/nvidia/tritonserver:*-trtllm-python-py3` image supports both x86_64 (GKE L4)
and arm64 (DGX Spark) but is not validated for AGX Orin's Ampere architecture (sm_87).

## Engine architecture mapping

| Target GPU | Engine dir | `sm` | Build workflow |
|-----------|------------|------|----------------|
| GKE L4 | `engine_l4/` | sm_89 | compression pipeline, `target_gpu=l4` |
| DGX Spark GB10 | `engine_gb10/` | Blackwell | compression pipeline, `target_gpu=gb10` |

Engines are written to `~/shared/huggingface-kfp/engines/<compression.project>/<run_id>/`
by the compression pipeline. `build-push.yaml` stages the appropriate arch dir into the
Docker build context as `engine/`, which Dockerfile.serve copies to `/engine/`.

## Key difference from serving-triton-vllm (Stage 8)

Stage 8 uses `AsyncLLMEngine` (PyTorch, async, requires a background event loop thread).
This stage uses `TRT-LLM LLM` (compiled execution, synchronous, no threading needed):

```python
# Stage 9 — TRT-LLM (this template)
from tensorrt_llm import LLM
self.llm = LLM(model="/engine")
outputs = list(self.llm.generate([text], sampling_params))

# Stage 8 — vLLM (serving-triton-vllm)
from vllm import AsyncLLMEngine
self._loop = asyncio.new_event_loop()
future = asyncio.run_coroutine_threadsafe(engine.generate(...), self._loop)
```

No `HF_TOKEN` required. No `HF_HOME` volume. No LoRA paths.

## Triton API endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /v2/health/ready` | Readiness probe |
| `GET /v2/health/live` | Liveness probe |
| `GET /v2/models/model` | Model metadata |
| `POST /v2/models/model/generate` | Non-streaming inference |

## LiteLLM model router config entry

```yaml
- model_name: {{SERVED_MODEL_NAME}}
  litellm_params:
    model: triton/model
    api_base: http://triton.{{PROJECT_NAME}}.svc.cluster.local:8000
    api_key: none
```

The `triton/` prefix tells LiteLLM to use the Triton provider, which translates
OpenAI `/v1/chat/completions` → Triton `/v2/models/model/generate` tensor format.

## Smoke test format

Triton tensor JSON (used in smoke_test_prompts.jsonl and deploy.yaml):

```bash
curl -X POST http://localhost:8000/v2/models/model/generate \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [
      {"name": "text_input", "shape": [1,1], "datatype": "BYTES", "data": ["Patient presents with fever."]},
      {"name": "sampling_parameters", "shape": [1,1], "datatype": "BYTES", "data": ["{\"max_tokens\": 100}"]}
    ]
  }'
```

After LiteLLM model router is running:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "{{SERVED_MODEL_NAME}}", "messages": [{"role": "user", "content": "Patient presents with fever."}]}'
```

## Workflow sequence

1. **Compression pipeline** (from the `serving-trt-*` project) produces validated engines:
   - `engine_l4/` for GKE target
   - `engine_gb10/` for DGX target
2. Fill `serving-config.yaml` `compression.project` and `compression.run_id` (or leave `latest`)
3. Run **Build and Push** (`host=gke` or `host=dgx`) — stages engine, builds image, pushes
4. Run **Deploy** (`host=gke` or `host=dgx`) — applies K8s manifests, smoke tests, registers model router
5. Run **Undeploy** when done — deregisters, deletes namespace, restores GPU pool (GKE only)

## Port-forward (local testing)

```bash
kubectl port-forward svc/triton 8000:8000 -n {{PROJECT_NAME}}
curl http://localhost:8000/v2/health/ready
```

## Cost notes

- GKE L4 spot: ~$0.35/hr; always undeploy when not actively evaluating
- DGX K3s: no cloud cost; GPU is locally owned
- No persistent volume or Load Balancer costs (ClusterIP only)
