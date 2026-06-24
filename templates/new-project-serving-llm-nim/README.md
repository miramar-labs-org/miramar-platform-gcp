# {{PROJECT_NAME}}

Model serving on DGX Spark via the NVIDIA Multi-LLM NIM runtime (`nvcr.io/nim/nvidia/llm-nim`).
Supports local host-path models and HuggingFace models. Exposes an OpenAI-compatible REST API
(`/v1/chat/completions`, `/v1/models`).

## Model

| | |
|---|---|
| **Source** | `{{MODEL_PATH}}` |
| **Container name** | `{{MODEL_NAME}}` |
| **Served as** | `{{SERVED_MODEL_NAME}}` |
| **NIM image** | `nvcr.io/nim/nvidia/llm-nim:{{NIM_IMAGE_TAG}}` |

## Quick start

```bash
# 1. Deploy via GHA workflow
gh workflow run deploy.yaml --repo miramar-labs-org/{{PROJECT_NAME}}

# 2. Access the endpoint (workflow sets up port-forward internally; for local access:)
kubectl port-forward svc/nim 8000:8000 -n {{PROJECT_NAME}}
curl http://localhost:8000/v1/models
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"{{SERVED_MODEL_NAME}}","messages":[{"role":"user","content":"Hello"}],"max_tokens":200}'

# 3. Undeploy when done to free GPU memory
gh workflow run undeploy.yaml --repo miramar-labs-org/{{PROJECT_NAME}}
```

## Model source modes

The deploy workflow auto-detects the mode from `model.model_path` in `serving-config.yaml`:

| `model_path` value | Mode | Behaviour |
|---|---|---|
| `/absolute/path` | **local** | Mounts model dir from DGX host via hostPath; TRT-LLM engine compiled on first run (~30–60 min), cached in `~/shared/nim-cache`. **Only supported mode on DGX Spark (GB10).** |
| `hf://org/model` or `org/model` | **hf** | NIM downloads weights from HuggingFace at startup; `HF_TOKEN` secret used if set. **Requires an NGC profile for the target GPU — not available for GB10. Do not use on DGX Spark.** |

## Configuration

Edit `serving-config.yaml` to update the model source, name, or NIM image tag:

```yaml
nim:
  image_tag: "latest"           # pin to a specific tag for reproducibility

model:
  model_path: "/path/to/model"  # /abs/path  OR  hf://org/model  OR  org/model
  container_name: "my-model"    # short name (local mode: volume name + mountPath)
  served_model_name: "my-model" # name clients use in API requests
```

After editing, run `deploy.yaml` again — it picks up the new values on each run.

## Model requirements (local mode)

- HuggingFace safetensors or PyTorch `.bin` format
- `config.json`, `tokenizer_config.json`, and tokenizer files present
- Fits within available DGX VRAM (~100 GiB usable on GB10)
- Full model weights required — LoRA adapters must be merged first

## Troubleshooting

**Pod stuck in `ContainerCreating`**
The `nim-cache` hostPath at `~/shared/nim-cache` must be writable. The deploy workflow runs
`sudo chmod 777 ~/shared/nim-cache` during preflight, but verify it exists on the DGX host.

**Pod stuck in `Pending`**
No GPU available. Check `kubectl describe pod -n {{PROJECT_NAME}}` for `Insufficient nvidia.com/gpu`.
Undeploy any other GPU workload (NIM, Ollama, vLLM) first.

**Slow first startup (30–60 min)**
Local mode: first run compiles TRT-LLM engines for your model architecture. Results are cached
in `~/shared/nim-cache` and reused on subsequent starts — redeploys are fast.

**`/v1/models` returns empty list**
The model failed to load. Check container logs:
```bash
kubectl logs -n {{PROJECT_NAME}} deployment/nim --follow
```
