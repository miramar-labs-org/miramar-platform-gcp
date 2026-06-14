# {{PROJECT_NAME}}

Serve a LoRA-adapted LLM via vLLM on GKE (L4 spot GPU) or K3s (DGX/AGX) — part of the [Miramar serving architecture](https://github.com/miramar-labs-org/miramar-platform-gcp).

## Workflows

| Workflow       | Trigger | Description                                                   |
| -------------- | ------- | ------------------------------------------------------------- |
| Build and Push | Manual  | Find latest gate-passing adapter, bake into image, push       |
| Deploy         | Manual  | Deploy vLLM to target host (GKE L4 spot or K3s), smoke tests |
| Undeploy       | Manual  | Remove deployment; GKE also tears down GPU node pool          |

## Quick start

1. Set `adapter.ft_project` in `serving-config.yaml` — points to the ft-eval project repo
2. Run **Build and Push** (once after ft-eval gate passes, or on `Dockerfile.serve` changes)
3. Run **Deploy** with the image tag from step 2
4. Port-forward and test:
   ```bash
   kubectl port-forward svc/vllm 8000:8000 -n {{PROJECT_NAME}}
   curl http://localhost:8000/v1/models
   ```
5. Run **Undeploy** when done

See [CLAUDE.md](CLAUDE.md) for detailed operating procedures.
