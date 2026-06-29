# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a Triton Inference Server + vLLM backend serving project on the Miramar
platform (GKE or DGX K3s). The vLLM Python backend runs inside Triton, exposing the model via
Triton's HTTP API on port 8000, which LiteLLM's triton provider routes to the model router.

## Key files

| File                               | Purpose                                                                                       |
| ---------------------------------- | --------------------------------------------------------------------------------------------- |
| `serving-config.yaml`              | Project config — base model, stable alias, adapter source (ft_project), Triton image tag     |
| `Dockerfile.serve`                 | Triton+vLLM image — model repo and adapter baked in at build time; base model fetched at runtime |
| `model_repo/model/config.pbtxt`    | Triton model config — Python backend, input/output tensor shapes                             |
| `model_repo/model/1/model.py`      | vLLM TritonPythonModel — AsyncLLMEngine with LoRA support, compatible with LiteLLM triton provider |
| `k8s/triton.yaml`                  | GKE manifest — namespace, deployment (Triton), ClusterIP service                             |
| `k8s/triton-k3s.yaml`              | DGX K3s manifest — deployment (Triton, GHCR image pull), ClusterIP service                   |
| `smoke_test_prompts.jsonl`         | 3–5 prompts to run after deploy to confirm model is responding                                |

## Platform compatibility

| Host | Supported | Notes |
|---|---|---|
| GKE (L4 spot) | ✅ | amd64, GAR image |
| DGX K3s (Grace+Blackwell) | ✅ | arm64, GHCR image |
| AGX K3s (Orin/Ampere) | ❌ | Triton vllm-python-py3 arm64 not validated for Orin; use serving-vllm |

## GPU cost

The L4 spot GPU node pool is **not persistent** on GKE. It is expanded on every `deploy.yaml`
(host=gke) run and torn down on every `undeploy.yaml` (host=gke) run. L4 spot costs ~$0.22/hr.
Always run `undeploy.yaml` when done.

On DGX K3s there is no node pool cost, but the GPU is occupied while the pod is running.

## Workflows

| Workflow          | Inputs                         | Effect                                                                                    |
| ----------------- | ------------------------------ | ----------------------------------------------------------------------------------------- |
| `build-push.yaml` | `host` (gke\|dgx, default: dgx) | Find latest gate-passing run, bake adapter + model repo into Triton image, push to registry |
| `deploy.yaml`     | `host` (gke\|dgx), `image_tag` | Deploy Triton to target host, run smoke tests, register with model router                 |
| `undeploy.yaml`   | `host` (gke\|dgx)             | Remove deployment; deregister from model router; GKE also restores GPU node pool          |

## Adapter source

Same pattern as `serving-vllm`: adapter baked into the Docker image at build time.
`build-push.yaml` reads `adapter.ft_project` from `serving-config.yaml`, scans
`~/shared/huggingface-kfp/runs/<ft_project>/*/gate_result.json` for the latest gate-passing run,
copies that adapter into `/adapter/` in the image.

## Model router integration

Unlike `serving-vllm` (which uses `openai/<name>`), this template uses LiteLLM's **triton provider**:

```yaml
# LiteLLM litellm-config.yaml entry (written by deploy.yaml)
- model_name: {{SERVED_MODEL_NAME}}    # client-facing alias
  litellm_params:
    model: triton/model                # Triton model directory name (always "model")
    api_base: http://triton.{{PROJECT_NAME}}.svc.cluster.local:8000
    api_key: none
```

Clients call the model router with standard OpenAI format; LiteLLM translates to
Triton's `/v2/models/model/generate` HTTP API.

## Health and inference endpoints

| Endpoint | Purpose |
|---|---|
| `GET /v2/health/live` | Triton server liveness |
| `GET /v2/health/ready` | Triton server ready (model loaded) |
| `POST /v2/models/model/generate` | Triton inference (non-streaming) |

## Port-forward access (local testing)

```bash
kubectl port-forward svc/triton 8000:8000 -n {{PROJECT_NAME}}

# Health check
curl http://localhost:8000/v2/health/ready

# Inference
curl -X POST http://localhost:8000/v2/models/model/generate \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": [
      {"name": "text_input", "shape": [1,1], "datatype": "BYTES", "data": ["Your prompt here"]},
      {"name": "sampling_parameters", "shape": [1,1], "datatype": "BYTES", "data": ["{\"max_tokens\": 200}"]}
    ]
  }'
```

Via LiteLLM model router (after deploy, model router running):
```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "{{SERVED_MODEL_NAME}}", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 100}'
```

## Cold-start time

First deploy downloads the base model from HuggingFace Hub (~5–10 min for 7B models).
Adapter and model repo are already in the image. Subsequent deploys on the same node are instant.
Triton's ready probe uses `initialDelaySeconds: 180` to accommodate model loading.

## Upgrading Triton image tag

Update `triton.image_tag` in `serving-config.yaml` and the `FROM` line in `Dockerfile.serve`
together, then re-run `build-push.yaml`. The current pinned version is `25.06-vllm-python-py3`.

## Namespace

The K8s namespace is `{{PROJECT_NAME}}`. Created idempotently by `deploy.yaml`.
`undeploy.yaml` removes the entire namespace (deployment, service, secrets).

## Secrets

`deploy.yaml` creates the `hf-token` K8s secret from `secrets.HF_TOKEN`.
On DGX K3s, it also creates the `ghcr-pull` image pull secret.
Ensure `HF_TOKEN` is set as a GitHub Actions secret on this repo (or inherited from org).

## Stage 9 forward compatibility

`serving-triton-trtllm` (Stage 9) uses the same model repo structure and deploy pattern.
The only differences: base image (`trtllm-python-py3` vs `vllm-python-py3`),
`model.py` implementation (TRT-LLM backend vs vLLM), and no adapter scanning
(engine is baked from a compression project). The K8s manifests and workflow structure
are identical — same health endpoints, same LiteLLM triton provider.
