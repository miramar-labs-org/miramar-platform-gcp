# {{PROJECT_NAME}}

{{DESCRIPTION}}

## Workflows

| Workflow          | Trigger | Description                                                      |
| ----------------- | ------- | ---------------------------------------------------------------- |
| Build and Push    | Manual  | Bake FP8 checkpoint into image, push to GAR (GKE only)          |
| Deploy            | Manual  | Deploy FP8-vLLM to DGX/AGX (hostPath) or GKE (baked image)      |
| Undeploy          | Manual  | Remove deployment; GKE also tears down GPU node pool             |

## Quick start

### DGX or AGX (no build needed)
1. Fill `serving-config.yaml` — set `compression.project` and `compression.run_id`
2. Ensure the FP8 checkpoint exists at `~/shared/huggingface-kfp/quantization/<project>/<run_id>/`
3. Run **Deploy** (`host=dgx` or `host=agx`)
4. Port-forward and test:
   ```bash
   kubectl port-forward svc/vllm 8000:8000 -n {{PROJECT_NAME}}
   curl http://localhost:8000/v1/models
   ```
5. Run **Undeploy** when done

### GKE
1. Run **Build and Push** to bake the checkpoint into a GAR image
2. Run **Deploy** (`host=gke`, `image_tag=latest`)
3. Run **Undeploy** when done

See [CLAUDE.md](CLAUDE.md) for detailed operating procedures.
