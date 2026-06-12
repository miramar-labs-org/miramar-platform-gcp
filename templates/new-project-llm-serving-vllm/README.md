# {{PROJECT_NAME}}

Serve a LoRA-adapted LLM via vLLM on GKE (L4 spot GPU) — part of the [Miramar serving architecture](https://github.com/miramar-labs-org/miramar-platform-gcp).

## Workflows

| Workflow | Trigger | Description |
|---|---|---|
| Build and Push | Manual | Build `Dockerfile.serve`, push to GAR |
| Deploy | Manual | Expand L4 spot GPU, deploy vLLM, run smoke tests |
| Undeploy | Manual | Remove deployment, restore GPU pool (stop costs) |

## Quick start

1. Set `adapter.manifest_uri` in `serving-config.yaml` — publish the adapter first via `publish-adapter.yaml` on the fine-tuning project
2. Run **Build and Push** (once, then only on `Dockerfile.serve` changes)
3. Run **Deploy**
4. Port-forward and test:
   ```bash
   kubectl port-forward svc/vllm 8000:8000 -n {{PROJECT_NAME}}
   curl http://localhost:8000/v1/models
   ```
5. Run **Undeploy** when done

See [CLAUDE.md](CLAUDE.md) for detailed operating procedures.
