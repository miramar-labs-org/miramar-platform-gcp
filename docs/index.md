# Documentation Index

Use this as the source-of-truth map when changing docs or looking for the right
operational procedure.

**[Platform Dashboard](https://miramar-labs-org.github.io/miramar-platform-gcp/)** — live table of all public Miramar projects (auto-refreshed hourly via `deploy-dashboard.yaml`).

> **One-time setup:** repo Settings → Pages → Source → **GitHub Actions**. After enabling, trigger `Deploy Platform Dashboard` via `workflow_dispatch` to seed the first deployment.

| Area | Start here | Source of truth |
| --- | --- | --- |
| Repo purpose and positioning | [SOWHAT.md](../SOWHAT.md) | [README.md](../README.md), [SOWHAT.md](../SOWHAT.md) |
| Developer workflow | [development.md](development.md) | [development.md](development.md) |
| CLI reference (`gh`, `gcloud`, Terraform, `kubectl`, MLflow) | [cli.md](cli.md) | [cli.md](cli.md) |
| Platform architecture | [architecture.md](architecture.md) | [README.md](../README.md), [architecture.md](architecture.md) |
| Diagrams | [diagrams.md](diagrams.md) | [diagrams.md](diagrams.md) |
| Security model | [security-model.md](security-model.md) | [security-model.md](security-model.md) |
| Configuration | [configuration.md](configuration.md) | [configuration.md](configuration.md) |
| GCP lifecycle | [gcp.md](gcp.md) | `gcp/terraform/`, `gcp/terraform-gpu/`, `.github/workflows/miramar-platform-*.yaml` |
| Workflow catalog | [workflows.md](workflows.md) | [workflows.md](workflows.md), `.github/workflows/` |
| Adding a new project template | [adding-a-project-template.md](adding-a-project-template.md) | [adding-a-project-template.md](adding-a-project-template.md), `templates/`, `create-project.yaml`, `generate-dashboard.sh` |
| GKE GPU quota and capacity | [gpu-quota-request.md](gpu-quota-request.md) | [gpu-quota-request.md](gpu-quota-request.md), `.github/workflows/find-gpu-capacity.yaml` |
| Self-hosted runners | [runners.md](runners.md) | `mlabs-runner/`, `scripts/gha/`, `.github/workflows/build-mlabs-runner.yml` |
| DGX k3s, NeMo, MLflow, NIM, Ollama, Qdrant | [dgx.md](dgx.md) | [dgx.md](dgx.md), `dgx/`, `.github/workflows/*k3s*.yaml`, `.github/workflows/*nemo*.yaml`, `.github/workflows/*mlflow*.yaml`, `.github/workflows/*nim*.yaml`, `.github/workflows/*ollama*.yaml`, `.github/workflows/*qdrant*.yaml` |
| GPU profiling (Nsight Systems) in KFP | [kfp-skills.md § Nsight Profiling](kfp-skills.md#nsight-profiling-in-kfp) | [kfp-skills.md](kfp-skills.md), `~/.claude/commands/nsight-interpret.md` |
| Model serving — vLLM on GKE (publish adapter, deploy, undeploy) | [workflows.md § Model Serving](workflows.md#model-serving-llm-serving-vllm-projects) | `templates/new-project-llm-serving-vllm/`, `templates/new-project-kfp-ft-eval/.github/workflows/publish-adapter.yaml` |
| KFP run lifecycle — `/kfp-deploy`, `/kfp-monitor`, `/nsight-interpret` | [kfp-skills.md](kfp-skills.md) | `~/.claude/commands/kfp-deploy.md`, `~/.claude/commands/kfp-monitor.md`, `~/.claude/commands/nsight-interpret.md` |
| JupyterLab environment, packages, project workflow | [dgx/jupyterlab/README.md](../dgx/jupyterlab/README.md) | [dgx/jupyterlab/README.md](../dgx/jupyterlab/README.md), `dgx/jupyterlab/requirements.txt` |
| AGX Orin (identical stack, separate tunnel ports) | [agx.md](agx.md) | [agx.md](agx.md), `agx/` |
| Adding a new machine to the platform | [onboarding.md](onboarding.md) | [onboarding.md](onboarding.md) |
| WSL2 operator flow | [wsl2/README.md](../wsl2/README.md) | [wsl2/README.md](../wsl2/README.md) |
| WSL2 architecture and template details | [wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md) | [wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md) |
| Windows OpenSSH for WSL2 workflows | [wsl2/ssh-win.md](../wsl2/ssh-win.md) | [wsl2/ssh-win.md](../wsl2/ssh-win.md) |
| SSH topology and troubleshooting | [ssh-runbook.md](ssh-runbook.md) | [ssh-runbook.md](ssh-runbook.md), [wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md) |
| Shared DGX/WSL2 folder | [shared.md](shared.md) | [shared.md](shared.md) |

## Drift Rules

- Keep `README.md` as the high-level operator overview.
- Keep config tables in [configuration.md](configuration.md), runner details in
  [runners.md](runners.md), GCP internals in [gcp.md](gcp.md), and workflow
  details in [workflows.md](workflows.md).
- Keep long WSL2 rationale and manual template procedures in
  [wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md), not in the root README.
- Keep current WSL2 commands in [wsl2/README.md](../wsl2/README.md) and
  lifecycle/template details in [wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md).
  The SSH runbook should describe the current topology, not legacy direct-port
  setup.
- When workflow behavior changes, update both the workflow file and the
  matching docs row above.

### Multi-session build architecture

- [arm64 sub-agent build architecture](../dgx/minikube/kubeflow/arm64/README-SUBAGENTS.md)
  — how the full KFP arm64 port is run across sessions: the plan file as the
  cross-session spine, the `arm64-builder` sub-agent for parallel builds, and
  handoffs for hard components. Read this before starting or resuming the port.