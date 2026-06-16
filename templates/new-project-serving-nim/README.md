# {{PROJECT_NAME}}

{{DESCRIPTION}}

## Workflows

| Workflow  | Trigger | Description                                        |
| --------- | ------- | -------------------------------------------------- |
| Deploy    | Manual  | Pull NIM image from nvcr.io and deploy to DGX/GKE |
| Undeploy  | Manual  | Remove deployment; GKE also tears down GPU node pool |

## Quick start

1. Fill in `serving-config.yaml` — set `nim.org`, `nim.model_name`, and image tags
2. Run **Deploy** (`host=dgx` or `host=gke`)
3. Port-forward and test:
   ```bash
   kubectl port-forward svc/nim 8000:8000 -n {{PROJECT_NAME}}
   curl http://localhost:8000/v1/models
   ```
4. Run **Undeploy** when done

See [CLAUDE.md](CLAUDE.md) for detailed operating procedures.
