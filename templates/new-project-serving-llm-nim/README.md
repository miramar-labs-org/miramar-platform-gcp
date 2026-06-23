# {{PROJECT_NAME}}

Local model serving on DGX Spark via the NVIDIA Multi-LLM NIM runtime (`nvcr.io/nim/nvidia/llm-nim`).

This is **not** an NGC-certified catalog NIM. The model directory lives on the DGX host and is
mounted into the generic `llm-nim` runtime container, which exposes an OpenAI-compatible REST
API (`/v1/chat/completions`, `/v1/models`).

## Model

| | |
|---|---|
| **Model directory** | `{{MODEL_HOST_PATH}}` |
| **Container name** | `{{MODEL_NAME}}` |
| **Served as** | `{{SERVED_MODEL_NAME}}` |
| **NIM image** | `nvcr.io/nim/nvidia/llm-nim:{{NIM_IMAGE_TAG}}` |

## Quick start

```bash
# 1. Check NIM compatibility (optional but recommended before first deploy)
export NGC_API_KEY=<your key>
bash scripts/list-profiles.sh

# 2. Deploy via GHA workflow
gh workflow run deploy.yaml --repo miramar-labs-org/{{PROJECT_NAME}}

# 3. Access the endpoint
kubectl port-forward svc/nim 8000:8000 -n {{PROJECT_NAME}}
curl http://localhost:8000/v1/models
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"{{SERVED_MODEL_NAME}}","messages":[{"role":"user","content":"Hello"}],"max_tokens":200}'

# 4. Undeploy when done to free GPU memory
gh workflow run undeploy.yaml --repo miramar-labs-org/{{PROJECT_NAME}}
```

## Model requirements

The `llm-nim` runtime accepts any HuggingFace-compatible model directory. Your model must:
- Be in HuggingFace safetensors format (or PyTorch `.bin`)
- Include `config.json`, `tokenizer_config.json`, and tokenizer files
- Fit within available DGX VRAM (~100 GiB usable on GB10)

Run `bash scripts/list-profiles.sh` to confirm the runtime can load your model architecture
before deploying to K3s. The output lists supported GPU profiles and any compatibility errors.

## Configuration

Edit `serving-config.yaml` to update model path, name, or NIM image tag:

```yaml
nim:
  image_tag: "latest"        # pin to a specific tag for reproducibility

model:
  host_path: "/path/to/model"   # absolute path on DGX
  container_name: "my-model"    # dir name inside the container
  served_model_name: "my-model" # name clients use in API requests
```

After editing, run `deploy.yaml` again — it picks up the new values on each run.

## Troubleshooting

**list-model-profiles returns no profiles**
The model architecture may not be supported by the current `llm-nim` version. Try a newer
`image_tag` or check the [Multi-LLM NIM release notes](https://docs.nvidia.com/nim/llm-nim/latest/).

**Pod stuck in `ContainerCreating`**
The `nim-cache` volume at `~/shared/nim-cache` must exist on the DGX host:
```bash
mkdir -p ~/shared/nim-cache
```

**Pod stuck in `Pending`**
No GPU available — check `kubectl describe pod -n {{PROJECT_NAME}}` for `Insufficient nvidia.com/gpu`.
Undeploy any other GPU workload (NIM, vLLM) first.

**Slow first startup (10–20 min)**
The first run compiles optimized TRT-LLM engines for your model. Results are cached in
`~/shared/nim-cache` and reused on subsequent starts.

**`/v1/models` returns empty list**
The model failed to load. Check container logs:
```bash
kubectl logs -n {{PROJECT_NAME}} deployment/nim --follow
```
