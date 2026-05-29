# DGX Spark NIM Catalog

NIM containers built specifically for the DGX Spark (GB10 Grace Blackwell, arm64, 128 GB unified memory).
These use a different base container than standard NIMs (`-variant` tag) and are the only NIMs verified
to run on the Spark's Blackwell GPU.

Sources: [NVIDIA NIM for LLMs — Supported Models](https://docs.nvidia.com/nim/large-language-models/latest/supported-models.html) · [NGC DGX Spark NIM containers](https://catalog.ngc.nvidia.com/orgs/nim/containers?filters=&orderBy=scoreDESC&query=dgx-spark)

## Deploy via NeMo Microservices API

These two NIMs can be deployed via the **NIM Deploy** GHA workflow or `deploy_nim.sh`:

| Model | `nim_name` | `nim_org` | `image_tag` | Params | Quant | Tool Use | Context |
|---|---|---|---|---|---|---|---|
| Meta Llama 3.1 8B Instruct | `llama-3.1-8b-instruct-dgx-spark` | `meta` | `1.0.0-variant` | 8B | FP8 | No | — |
| NVIDIA Nemotron Nano 9B v2 | `nvidia-nemotron-nano-9b-v2-dgx-spark` | `nvidia` | `1.0.0-variant` | 9B | FP8 (vLLM) | Yes (parallel) | — |

### Meta Llama 3.1 8B Instruct

General instruction-following model. No tool call support.

```bash
# Deploy
source ./deploy_nim.sh && deploy_nim meta llama-3.1-8b-instruct-dgx-spark 1.0.0-variant

# Undeploy
source ./undeploy_nim.sh && undeploy_nim meta llama-3.1-8b-instruct-dgx-spark
```

```bash
# Inference
curl http://nim.test/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct-dgx-spark",
    "messages": [{"role": "user", "content": "What is the capital of France?"}]
  }' | jq .
```

GHA workflow: `nim_org=meta`, `nim_name=llama-3.1-8b-instruct-dgx-spark`, `image_tag=1.0.0-variant`

NGC: `catalog.ngc.nvidia.com/orgs/nim/teams/meta/containers/llama-3.1-8b-instruct-dgx-spark`

### NVIDIA Nemotron Nano 9B v2 *(default — tools enabled)*

Supports tool calling and parallel tool calling. This is the platform default NIM.

```bash
# Deploy
source ./deploy_nim.sh && deploy_nim nvidia nvidia-nemotron-nano-9b-v2-dgx-spark 1.0.0-variant

# Undeploy
source ./undeploy_nim.sh && undeploy_nim nvidia nvidia-nemotron-nano-9b-v2-dgx-spark
```

```bash
# Inference
curl http://nim.test/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark",
    "messages": [{"role": "user", "content": "What is the capital of France?"}]
  }' | jq .
```

```bash
# Tool call
curl http://nim.test/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark",
    "messages": [{"role": "user", "content": "What is the weather in Paris?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a city",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {"type": "string"}
          },
          "required": ["city"]
        }
      }
    }],
    "tool_choice": "auto"
  }' | jq .
```

GHA workflow: `nim_org=nvidia`, `nim_name=nvidia-nemotron-nano-9b-v2-dgx-spark`, `image_tag=1.0.0-variant`

NGC: `catalog.ngc.nvidia.com/orgs/nim/teams/nvidia/containers/nvidia-nemotron-nano-9b-v2-dgx-spark`

---

## Standalone Only (not deployable via NeMo/Kubernetes)

| Model | `nim_org` | `nim_name` | `image_tag` | Params | Quant | Tool Use | Notes |
|---|---|---|---|---|---|---|---|
| Qwen3 32B | `qwen` | `qwen3-32b-dgx-spark` | `1.1.0-variant` | 32B | NVFP4 | Yes (parallel) | KServe/K8s not supported |

The Qwen3 32B variant explicitly does not support deployment via KServe or Kubernetes per NVIDIA release notes,
which rules it out for NeMo Microservices on minikube. Run it as a standalone Docker container on the DGX host
if needed (~41.6 GB image, uses ~108 GB of the 128 GB unified memory).

```bash
# Run standalone (on DGX host, not inside minikube)
docker run --rm --gpus all \
  -e NGC_API_KEY="$NVIDIA_API_KEY" \
  -p 8000:8000 \
  nvcr.io/nim/qwen/qwen3-32b-dgx-spark:1.1.0-variant
```

```bash
# Inference (standalone — port 8000 on DGX host)
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/qwen3-32b-dgx-spark",
    "messages": [{"role": "user", "content": "What is the capital of France?"}]
  }' | jq .
```

```bash
# Tool call (standalone)
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/qwen3-32b-dgx-spark",
    "messages": [{"role": "user", "content": "What is the weather in Paris?"}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather for a city",
        "parameters": {
          "type": "object",
          "properties": {
            "city": {"type": "string"}
          },
          "required": ["city"]
        }
      }
    }],
    "tool_choice": "auto"
  }' | jq .
```

NGC: `catalog.ngc.nvidia.com/orgs/nim/teams/qwen/containers/qwen3-32b-dgx-spark`
