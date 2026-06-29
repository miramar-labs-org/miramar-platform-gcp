# {{PROJECT_NAME}}

{{DESCRIPTION}}

## Workflows

| Workflow       | Trigger | Description                                                                    |
| -------------- | ------- | ------------------------------------------------------------------------------ |
| Build and Push | Manual  | Stage compiled TRT-LLM engine, bake into Triton image, push                   |
| Deploy         | Manual  | Deploy Triton+TRT-LLM to target host (GKE L4 spot or DGX K3s), smoke tests   |
| Undeploy       | Manual  | Remove deployment; GKE also tears down GPU node pool                           |

## Quick start

1. Set `compression.project` and `compression.run_id` in `serving-config.yaml`
2. Run **Build and Push** (host=gke for GAR/L4 engine, host=dgx for GHCR/GB10 engine)
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
