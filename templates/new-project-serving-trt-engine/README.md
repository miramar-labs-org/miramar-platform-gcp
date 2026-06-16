# {{PROJECT_NAME}}

{{DESCRIPTION}}

## Workflows

| Workflow          | Trigger | Description                                                           |
| ----------------- | ------- | --------------------------------------------------------------------- |
| Build and Push    | Manual  | Bake engine_l4/ into TRT-LLM image, push to GAR (GKE only)           |
| Deploy            | Manual  | Deploy TRT-LLM to DGX (engine_gb10) / AGX (engine_sm87) / GKE (L4)  |
| Undeploy          | Manual  | Remove deployment; GKE also tears down GPU node pool                  |

## Quick start

### DGX (no build needed)
1. Fill `serving-config.yaml` — set `compression.project` and `compression.run_id`
2. Ensure engine exists at `~/shared/huggingface-kfp/engines/<project>/<run_id>/engine_gb10/`
3. Run **Deploy** (`host=dgx`)
4. Port-forward and test:
   ```bash
   kubectl port-forward svc/trtllm 8000:8000 -n {{PROJECT_NAME}}
   curl http://localhost:8000/v1/models
   ```
5. Run **Undeploy** when done

### AGX (no build needed)
Same as DGX but `host=agx` and engine subdir is `engine_sm87/`.

### GKE
1. Run **Build and Push** to bake `engine_l4/` into a GAR image
2. Run **Deploy** (`host=gke`, `image_tag=latest`)
3. Run **Undeploy** when done

See [CLAUDE.md](CLAUDE.md) for detailed operating procedures.
