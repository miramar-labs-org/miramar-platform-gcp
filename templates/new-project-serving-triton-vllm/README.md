# {{PROJECT_NAME}}

{{DESCRIPTION}}

## Workflows

| Workflow       | Trigger | Description                                                              |
| -------------- | ------- | ------------------------------------------------------------------------ |
| Build and Push | Manual  | Find latest gate-passing adapter, bake into Triton image, push           |
| Deploy         | Manual  | Deploy Triton+vLLM to target host (GKE L4 spot or DGX K3s), smoke tests |
| Undeploy       | Manual  | Remove deployment; GKE also tears down GPU node pool                     |

## Quick start

1. Set `adapter.ft_project` in `serving-config.yaml` — points to the ft-eval project repo
2. Run **Build and Push** (once after ft-eval gate passes, or on `Dockerfile.serve` changes)
3. Run **Deploy** with the image tag from step 2
4. Port-forward and test:
   ```bash
   kubectl port-forward svc/triton 8000:8000 -n {{PROJECT_NAME}}
   # Health check
   curl http://localhost:8000/v2/health/ready
   # Inference via Triton generate API
   curl -X POST http://localhost:8000/v2/models/model/generate \
     -H "Content-Type: application/json" \
     -d '{"inputs":[{"name":"text_input","shape":[1,1],"datatype":"BYTES","data":["Hello!"]}]}'
   ```
5. Run **Undeploy** when done

See [CLAUDE.md](CLAUDE.md) for detailed operating procedures.
