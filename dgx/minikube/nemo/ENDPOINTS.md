# DGX Spark — Endpoint Reference

All endpoints are reachable **from the DGX host** directly. To reach them **from your laptop**, open an SSH tunnel first:

```bash
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 -L 8082:localhost:8082 <user>@spark-79b7.local
```

> **NIM and Ollama share the 128 GB unified memory pool.** ~28 GB is reserved for system use (minikube, OS), leaving ~100 GB for workloads. They can coexist as long as their combined memory fits within that budget.

---

## Contents

- [Hosts at a glance](#hosts-at-a-glance)
- [NIM inference — `http://nim.test`](#nim-inference----httpnimtest)
- [NeMo management — `http://nemo.test`](#nemo-management----httpnemotest)
- [NeMo Data Store — `http://data-store.test`](#nemo-data-store----httpdata-storetest)
- [Ollama — `http://localhost:11434`](#ollama----httplocalhost11434)
- [Qwen3 32B standalone — `http://localhost:8000`](#qwen3-32b-standalone----httplocalhost8000)
- [UI services (SSH tunnel)](#ui-services-ssh-tunnel)

---

## Hosts at a glance

| Host | DGX port | Laptop port | What it is | Requires |
|---|---|---|---|---|
| `nim.test` | 80 | 8082 | NIM inference gateway (OpenAI-compatible) | NeMo deployed + NIM deployed |
| `nemo.test` | 80 | 8082 | NeMo microservices REST API | NeMo deployed |
| `data-store.test` | 80 | 8082 | HuggingFace-compatible data/model store | NeMo deployed |
| `localhost:11434` | 11434 | 11434 (via tunnel) | Ollama (host service, GPU-accelerated) | Ollama model loaded |
| `localhost:8000` | 8000 | 8000 (via tunnel) | Qwen3 32B standalone Docker NIM | Running `docker run …` manually |
| `localhost:8001` | 8001 | 8001 (via tunnel) | Kubernetes dashboard (via `kubectl proxy`) | minikube running |
| `localhost:8888` | 8888 | 8888 (via tunnel) | JupyterLab | minikube running |
| `localhost:5000` | 5000 | 5000 (via tunnel) | MLflow Tracking UI | NeMo + MLflow deployed |

DNS entries (`nemo.test`, `nim.test`, `data-store.test`) are added to `/etc/hosts` on the DGX host by the **NeMo Deploy** workflow. They resolve to the minikube cluster IP (`192.168.49.2`). Source files: [`hosts.dgx`](hosts.dgx) (DGX), [`hosts.win`](hosts.win) (Windows/WSL2, for use with SSH tunnel on port 8082).

---

## NIM inference — `http://nim.test`

Routes to the `nemo-nim-proxy` service inside minikube. Fully OpenAI-compatible.

### List deployed models

```bash
curl http://nim.test/v1/models | jq .
```

### Chat completion

```bash
curl http://nim.test/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark",
    "messages": [{"role": "user", "content": "What is the capital of France?"}]
  }' | jq .
```

```bash
# Llama 3.1 8B (no tool support)
curl http://nim.test/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta/llama-3.1-8b-instruct-dgx-spark",
    "messages": [{"role": "user", "content": "What is the capital of France?"}]
  }' | jq .
```

### Tool calling (Nemotron Nano 9B v2 — parallel tools enabled)

```bash
curl http://nim.test/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark",
    "messages": [{"role": "user", "content": "What is the weather in Paris and Tokyo?"}],
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

### Streaming

```bash
curl http://nim.test/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark",
    "stream": true,
    "messages": [{"role": "user", "content": "Tell me a short story."}]
  }'
```

---

## NeMo management — `http://nemo.test`

All management APIs route through the NeMo NGINX ingress. Path prefix determines the backend service.

### NIM deployment management

```bash
# List all deployed NIMs
curl http://nemo.test/v1/deployment/model-deployments | jq .

# Get status of a specific NIM
curl http://nemo.test/v1/deployment/model-deployments/nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark \
  | jq '.status_details.status'

# Deploy a NIM
curl -X POST http://nemo.test/v1/deployment/model-deployments \
  -H "Content-Type: application/json" \
  -d '{
    "name": "nvidia-nemotron-nano-9b-v2-dgx-spark",
    "namespace": "nvidia",
    "config": {
      "model": "nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark",
      "nim_deployment": {
        "image_name": "nvcr.io/nim/nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark",
        "image_tag": "1.0.0-variant",
        "pvc_size": "25Gi",
        "gpu": 1,
        "additional_envs": {
          "NIM_GUIDED_DECODING_BACKEND": "fast_outlines"
        }
      }
    }
  }' | jq .

# Undeploy a NIM (404 = already gone, treated as success)
curl -X DELETE \
  http://nemo.test/v1/deployment/model-deployments/nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark
```

### Entity store (namespaces, projects, datasets, models)

```bash
# List namespaces
curl http://nemo.test/v1/namespaces | jq .

# List projects
curl http://nemo.test/v1/projects | jq .

# List datasets
curl http://nemo.test/v1/datasets | jq .

# List models in the registry
curl http://nemo.test/v1/models | jq .
```

### Customization (fine-tuning)

```bash
# List customization jobs
curl http://nemo.test/v1/customization/jobs | jq .
```

### Evaluation

Both `/v1/evaluation` and `/v2/evaluation` route to `nemo-evaluator:7331`.

```bash
# List evaluation jobs
curl http://nemo.test/v1/evaluation/jobs | jq .

# Get a specific job
curl http://nemo.test/v1/evaluation/jobs/<job_id> | jq .

# Get job results
curl http://nemo.test/v1/evaluation/jobs/<job_id>/results | jq .

# Cancel / delete a job
curl -X DELETE http://nemo.test/v1/evaluation/jobs/<job_id>

# List available evaluation targets (benchmarks)
curl http://nemo.test/v1/evaluation/targets | jq .
```

#### Create an evaluation job

```bash
curl -X POST http://nemo.test/v1/evaluation/jobs \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-eval-run",
    "namespace": "default",
    "target": {
      "type": "model",
      "model": "meta/llama-3.1-8b-instruct-dgx-spark",
      "base_url": "http://nim.test"
    },
    "tasks": [
      {
        "type": "chat",
        "dataset": {
          "namespace": "default",
          "name": "my-eval-dataset"
        }
      }
    ]
  }' | jq .
```

#### Poll until complete

```bash
JOB_ID="<job_id>"
while true; do
  STATUS=$(curl -s http://nemo.test/v1/evaluation/jobs/$JOB_ID | jq -r '.status')
  echo "$(date -u +%H:%M:%S) $STATUS"
  [[ "$STATUS" == "completed" || "$STATUS" == "failed" ]] && break
  sleep 10
done

# Fetch results
curl http://nemo.test/v1/evaluation/jobs/$JOB_ID/results | jq .
```

#### v2 API

`/v2/evaluation` routes to the same `nemo-evaluator:7331` service. Use `v2` if you need API features not available in `v1` (newer schema, extended fields). The path structure mirrors `v1`:

```bash
curl http://nemo.test/v2/evaluation/jobs | jq .
curl http://nemo.test/v2/evaluation/jobs/<job_id> | jq .
curl http://nemo.test/v2/evaluation/jobs/<job_id>/results | jq .
```

#### Direct service access (bypass ingress)

```bash
kubectl -n default port-forward svc/nemo-evaluator 7331:7331 &
curl http://localhost:7331/v1/evaluation/jobs | jq .
# Health check (ingress does not expose /health — use port-forward)
curl http://localhost:7331/health | jq .
```

### Data Designer (synthetic data generation)

```bash
# List data designer jobs
curl http://nemo.test/v1/data-designer/jobs | jq .
```

### Jobs (core API)

```bash
# List all training/pipeline jobs
curl http://nemo.test/v1/jobs | jq .
```

---

## NeMo Data Store — `http://data-store.test`

HuggingFace Hub-compatible API backed by MinIO (inside minikube).

```bash
# Health check
curl http://data-store.test/v1/health | jq .

# Use as HuggingFace endpoint (route model downloads through the local store)
export HF_ENDPOINT=http://data-store.test/v1/hf
```

With `HF_ENDPOINT` set, standard HuggingFace tooling (`huggingface_hub`, `transformers`, `datasets`) will
pull from and push to the local data store instead of `huggingface.co`.

---

## Ollama — `http://localhost:11434`

Runs as a systemd service on the DGX **host** (not inside minikube). OpenAI-compatible API.

> Ollama is GPU-accelerated on the DGX Spark GB10 (sm_120 binaries, binary-compatible with sm_121/Blackwell).

### Check what's loaded

```bash
curl http://localhost:11434/api/ps | jq .
```

### List available models

```bash
curl http://localhost:11434/v1/models | jq .
```

### Chat completion

```bash
# llama3.3:70b-instruct-q4_K_M — general / tool calling / ~4.4 tok/s
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.3:70b-instruct-q4_K_M",
    "messages": [{"role": "user", "content": "Explain CUDA unified memory in one paragraph."}]
  }' | jq .

# deepseek-r1:70b — reasoning / math / planning (thinking traces in output)
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1:70b",
    "messages": [{"role": "user", "content": "What is the derivative of x^3 - 2x + 1 at x=2?"}]
  }' | jq .

# qwen3:32b-q4_K_M — fast workhorse / coding / agents (~9.4 tok/s)
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3:32b-q4_K_M",
    "messages": [{"role": "user", "content": "Write a Python function to parse a JSON log file."}]
  }' | jq .

# gpt-oss:20b — fastest model on Spark (~58 tok/s, MoE, coding + agentic)
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-oss:20b",
    "messages": [{"role": "user", "content": "Write a Rust function to parse JSON."}]
  }' | jq .

# qwen3-coder:30b-a3b-q4_K_M — code / SWE / 256K context
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-coder:30b-a3b-q4_K_M",
    "messages": [{"role": "user", "content": "Review this Python function for bugs and suggest fixes."}]
  }' | jq .
```

### Tool calling

```bash
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.3:70b-instruct-q4_K_M",
    "messages": [{"role": "user", "content": "What is the weather in San Francisco?"}],
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

### Streaming

```bash
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-oss:20b",
    "stream": true,
    "messages": [{"role": "user", "content": "Write a Rust function to parse JSON."}]
  }'
```

### Embeddings

```bash
curl http://localhost:11434/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.3:70b-instruct-q4_K_M",
    "input": "The quick brown fox jumps over the lazy dog."
  }' | jq .
```

### Qwen3 thinking mode (toggle inline)

```bash
# Enable chain-of-thought with /think prefix
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3:32b-q4_K_M",
    "messages": [{"role": "user", "content": "/think\nDebug this segfault: free() called on pointer not malloc-d."}]
  }' | jq .

# Disable with /no_think
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3:32b-q4_K_M",
    "messages": [{"role": "user", "content": "/no_think\nSummarise this in one sentence: …"}]
  }' | jq .
```

### Ollama model quick reference

| Tag | Params | Active | Quant | Size | tok/s | Tool use | Best for |
|---|---|---|---|---|---|---|---|
| `llama3.3:70b-instruct-q4_K_M` | 70B | 70B | Q4_K_M | 43 GB | ~4.4 | ✅ | General, agentic |
| `deepseek-r1:70b` | 70B | 70B | Q4_K_M | 43 GB | ~4.4 | CoT only | Reasoning, math |
| `qwen3:32b-q4_K_M` | 32.8B | 32.8B | Q4_K_M | 20 GB | 9.4 | ✅ | Fast workhorse |
| `gpt-oss:20b` | 21B | 3.6B (MoE) | MXFP4 | 14 GB | **58** | ✅ | Speed, coding |
| `qwen3-coder:30b-a3b-q4_K_M` | 30B | 3B (MoE) | Q4_K_M | 19 GB | ~20 | ✅ | Code, 256K ctx |

---

## Qwen3 32B standalone — `http://localhost:8000`

Qwen3 32B does **not** support KServe/Kubernetes deployment — run it as a standalone Docker container on the DGX host. Uses ~108 GB of the 128 GB unified memory pool.

```bash
# Start (blocks; runs in foreground)
docker run --rm --gpus all \
  -e NGC_API_KEY="$NVIDIA_API_KEY" \
  -p 8000:8000 \
  nvcr.io/nim/qwen/qwen3-32b-dgx-spark:1.1.0-variant
```

```bash
# Chat completion
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/qwen3-32b-dgx-spark",
    "messages": [{"role": "user", "content": "What is the capital of France?"}]
  }' | jq .
```

```bash
# Tool call (parallel tool calling supported)
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen/qwen3-32b-dgx-spark",
    "messages": [{"role": "user", "content": "What is the weather in Paris and Tokyo?"}],
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

---

## UI services (SSH tunnel)

Always running via systemd on the DGX — no manual start needed.

```bash
# Open tunnel from your laptop
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 -L 8082:localhost:8082 <user>@spark-79b7.local
```

| Service | URL |
|---|---|
| Kubernetes dashboard | `http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/` |
| JupyterLab | `http://localhost:8888/lab` |
| MLflow Tracking | `http://localhost:5000` |

```bash
# Set MLflow tracking URI (from inside the mlabs-runner container or any host-networked process)
export MLFLOW_TRACKING_URI=http://host.docker.internal:5000
```

---

## Python SDK

```bash
pip install nemo-microservices
```

```python
from nemo_microservices import NeMoMicroservices

client = NeMoMicroservices(
    base_url="http://nemo.test",
    inference_base_url="http://nim.test"
)

# List namespaces
namespaces = client.namespaces.list()

# Chat via NIM proxy
response = client.inference.chat.completions.create(
    model="nvidia/nvidia-nemotron-nano-9b-v2-dgx-spark",
    messages=[{"role": "user", "content": "Hello!"}]
)
```

For the OpenAI SDK pointed at Ollama or NIM:

```python
from openai import OpenAI

# NIM (via nim.test)
nim = OpenAI(base_url="http://nim.test/v1", api_key="unused")

# Ollama
ollama = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")
```
