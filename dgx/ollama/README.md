# Ollama on DGX Spark

[Ollama](https://ollama.com) ([Model library](https://ollama.com/library) · [GitHub](https://github.com/ollama/ollama) · [API docs](https://github.com/ollama/ollama/blob/main/docs/api.md)) runs on the DGX Spark with full GPU acceleration. The GB10 is sm_121 (Blackwell); Ollama ships
sm_120 binaries that are binary-compatible with sm_121 — confirmed working as of Ollama v0.12.6 +
firmware 580.95.05. As of mid-2026, Ollama is the only local LLM runtime with reliable GPU acceleration
on DGX Spark (vLLM and TGI have open sm_121/aarch64 issues).

Ollama is installed on the DGX host via the **Ollama Update** GHA workflow (`update-ollama.yaml`).

> **NIM and Ollama share the 128 GB unified memory pool.** ~28 GB is reserved for the platform (OS, k3s, services), leaving **~100 GB for AI models** (configurable via `DGX_VRAM_USEABLE` org variable). The deploy workflow auto-undeploys any existing Ollama model before loading a new one. NIM co-deployment is allowed if free memory ≥ 15 GB; it only blocks if headroom is too low.

## GHA Workflows

| Workflow | Purpose |
|---|---|
| **Ollama Deploy** (`deploy-ollama.yaml`) | Pull a model and load it into GPU memory. Blocks if another Ollama model is loaded or free memory < 15 GB. Writes `CURRENT_OLLAMA_MODEL` and `CURRENT_OLLAMA_VRAM_GB`. |
| **Ollama Undeploy** (`undeploy-ollama.yaml`) | Unload the active model from GPU memory. Auto-detects if `model` input is left blank. |
| **Ollama Update** (`update-ollama.yaml`) | Install or upgrade Ollama on the DGX host. |

```
Actions → Ollama Deploy  → model: llama3.3:70b-instruct-q4_K_M
Actions → Ollama Undeploy → (leave model blank to auto-detect)
```

## Scripts

`deploy_ollama.sh` and `undeploy_ollama.sh` run on the DGX **host** (not in the runner container) via SSH.
The workflows pipe them via stdin with `bash -s -- <args>`.

```bash
# Deploy manually (on DGX host)
bash dgx/ollama/deploy_ollama.sh llama3.3:70b-instruct-q4_K_M

# Undeploy manually (on DGX host) — auto-detects loaded model
bash dgx/ollama/undeploy_ollama.sh

# Undeploy and delete from disk
bash dgx/ollama/undeploy_ollama.sh llama3.3:70b-instruct-q4_K_M true
```

Source: [Ollama DGX Spark performance blog](https://ollama.com/blog/nvidia-spark-performance) (official benchmarks, Ollama v0.12.6)

**References:** [Ollama](https://ollama.com) · [Model library](https://ollama.com/library) · [GitHub](https://github.com/ollama/ollama) · [API docs](https://github.com/ollama/ollama/blob/main/docs/api.md) · [NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/) · [CUDA](https://developer.nvidia.com/cuda-toolkit)

## Top 5 Models

| # | Ollama tag | Params | Active | Quant | Size | Context | Tool use | tok/s (DGX) | Best for |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `llama3.3:70b-instruct-q4_K_M` | 70B | 70B | Q4_K_M | 43 GB | 128K | Yes | ~4.4 | General, agentic, tool calling |
| 2 | `deepseek-r1:70b` | 70B | 70B | Q4_K_M | 43 GB | 128K | CoT only | ~4.4 | Reasoning, math, planning |
| 3 | `qwen3:32b-q4_K_M` | 32.8B | 32.8B | Q4_K_M | 20 GB | 131K | Yes | 9.4 | Fast workhorse, coding, agents |
| 4 | `gpt-oss:20b` | 21B | 3.6B (MoE) | MXFP4 | 14 GB | 131K | Yes | **58** | Speed, coding, agentic |
| 5 | `qwen3-coder:30b-a3b-q4_K_M` | 30B | 3B (MoE) | Q4_K_M | 19 GB | 256K | Yes | ~20 | Code, repo-level, SWE |

All five fit within the **100 GB model budget** (only one is loaded at a time; combined sizes are irrelevant).

> **Note:** `qwen3:235b-a22b` at Q4_K_M is 142 GB — 42 GB over the 100 GB model budget. Skip it.

---

## Model Details

### 1. `llama3.3:70b-instruct-q4_K_M` — General / tool calling

```bash
ollama pull llama3.3:70b-instruct-q4_K_M
ollama run llama3.3:70b-instruct-q4_K_M
```

```bash
# Chat completion
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3.3:70b-instruct-q4_K_M",
    "messages": [{"role": "user", "content": "Explain CUDA unified memory in one paragraph."}]
  }' | jq .
```

```bash
# Tool call
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

---

### 2. `deepseek-r1:70b` — Reasoning / math / planning

DeepSeek-R1 distilled into the Llama 3.3 70B base. Produces explicit thinking traces before answering —
excellent for debugging, proofs, math, and code logic. No structured function calling; use Llama 3.3 for
tool-augmented pipelines.

```bash
ollama pull deepseek-r1:70b
ollama run deepseek-r1:70b
```

```bash
# Chat completion (thinking trace visible in output)
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-r1:70b",
    "messages": [{"role": "user", "content": "What is the derivative of x^3 - 2x + 1 at x=2?"}]
  }' | jq .
```

---

### 3. `qwen3:32b-q4_K_M` — Fast workhorse / coding / agents

Officially benchmarked by Ollama on DGX Spark (9.4 tok/s decode). At 20 GB uses only 15% of memory —
ideal as a fast always-available model. Supports `/think` and `/no_think` inline to toggle chain-of-thought.

```bash
ollama pull qwen3:32b-q4_K_M
ollama run qwen3:32b-q4_K_M
```

```bash
# Chat completion
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3:32b-q4_K_M",
    "messages": [{"role": "user", "content": "Write a Python function to parse a JSON log file."}]
  }' | jq .
```

```bash
# With thinking mode enabled
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3:32b-q4_K_M",
    "messages": [{"role": "user", "content": "/think\nDebug this segfault: free() called on pointer not malloc-d."}]
  }' | jq .
```

```bash
# Tool call
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3:32b-q4_K_M",
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

---

### 4. `gpt-oss:20b` — Fastest / coding assistant / agentic

OpenAI's open-weight MoE model. The fastest model on DGX Spark in official Ollama benchmarks — 58 tok/s
decode despite being 21B total parameters (3.6B active per token via MoE + MXFP4). Configurable reasoning
effort (`low`/`medium`/`high`). Apache 2.0 license.

```bash
ollama pull gpt-oss:20b
ollama run gpt-oss:20b
```

```bash
# Chat completion
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-oss:20b",
    "messages": [{"role": "user", "content": "Write a Rust function to parse JSON."}]
  }' | jq .
```

```bash
# Streaming
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-oss:20b",
    "stream": true,
    "messages": [{"role": "user", "content": "Write a Rust function to parse JSON."}]
  }'
```

```bash
# Tool call with configurable reasoning effort
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-oss:20b",
    "messages": [{"role": "user", "content": "What files changed in the last git commit?"}],
    "reasoning_effort": "low",
    "tools": [{
      "type": "function",
      "function": {
        "name": "run_shell",
        "description": "Run a shell command and return output",
        "parameters": {
          "type": "object",
          "properties": {
            "command": {"type": "string"}
          },
          "required": ["command"]
        }
      }
    }],
    "tool_choice": "auto"
  }' | jq .
```

---

### 5. `qwen3-coder:30b-a3b-q4_K_M` — Code / repo-level / SWE

Purpose-built coding MoE model. 256K native context (the largest of the five — fits whole repos). SWE-Bench
score near 60% quantized. 30B total / 3B active per token gives high throughput. Best choice for an offline
coding agent or long-context file editing.

```bash
ollama pull qwen3-coder:30b-a3b-q4_K_M
ollama run qwen3-coder:30b-a3b-q4_K_M
```

```bash
# Chat completion
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-coder:30b-a3b-q4_K_M",
    "messages": [{"role": "user", "content": "Review this Python function for bugs and suggest fixes."}]
  }' | jq .
```

```bash
# Tool call
curl http://localhost:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-coder:30b-a3b-q4_K_M",
    "messages": [{"role": "user", "content": "List all Python files in the current directory."}],
    "tools": [{
      "type": "function",
      "function": {
        "name": "run_shell",
        "description": "Run a shell command and return output",
        "parameters": {
          "type": "object",
          "properties": {
            "command": {"type": "string"}
          },
          "required": ["command"]
        }
      }
    }],
    "tool_choice": "auto"
  }' | jq .
```

---

## API Reference

Ollama exposes an OpenAI-compatible API at `http://localhost:11434/v1`.

```bash
# List loaded/available models
curl http://localhost:11434/v1/models | jq .

# Check which model is currently loaded
curl http://localhost:11434/api/ps | jq .
```

Clients that require an API key: use any non-empty string (e.g. `"ollama"`).

Available endpoints: `/v1/chat/completions`, `/v1/completions`, `/v1/models`, `/v1/embeddings`, `/v1/responses`
