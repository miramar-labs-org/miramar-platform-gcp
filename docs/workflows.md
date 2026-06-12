# Workflow Catalog

All workflows are manually dispatchable unless noted otherwise.

## Platform Lifecycle

| Workflow | File | Purpose |
| --- | --- | --- |
| GCP Platform Create | `gcp-platform-create.yaml` | Create state bucket, run Terraform, then apply Kubernetes setup |
| GCP Platform Destroy | `gcp-platform-destroy.yaml` | Destroy GKE/Artifact Registry/state bucket; optional project deletion |

Destroy has three guards: exact project name, `i_confirm`, and optional
`delete_project`.

## GKE Scaling

| Workflow | File | Purpose |
| --- | --- | --- |
| GKE Expand | `gke-expand.yaml` | Snapshot node pool state, then resize CPU node pool |
| GKE Restore | `gke-restore.yaml` | Restore node count from the saved GCS snapshot |
| GKE Expand GPU | `gke-expand-gpu.yaml` | Add isolated GPU node pool, device plugin, and quota changes |
| GKE Restore GPU | `gke-restore-gpu.yaml` | Delete GPU node pool and restore namespace quota |
| Find GPU Capacity | `find-gpu-capacity.yaml` | Probe GPU availability and print usable workflow settings |

CPU and GPU expansion are independent. A typical heavy-workload sequence is:

```text
Find GPU Capacity -> GKE Expand -> GKE Expand GPU -> deploy workload -> GKE Restore GPU -> GKE Restore
```

Run **Find GPU Capacity** first to confirm availability and get the recommended zone and accelerator type before expanding.

## Local AI Stack (DGX + AGX)

All workflows accept a `runner` input (`dgx` or `agx`) to target either machine.

| Workflow | File | Purpose |
| --- | --- | --- |
| K3s Install | `install-k3s.yaml` | Install k3s with NVIDIA device plugin + nginx-ingress; update kubeconfig secret; writes `{MACHINE}_K3S_ACTIVE` org var. Inputs: `runner` |
| K3s Uninstall | `uninstall-k3s.yaml` | Run k3s-uninstall.sh and remove kubeconfig; clears `{MACHINE}_K3S_ACTIVE` org var. Inputs: `runner` |
| NeMo Deploy | `deploy-nemo.yaml` | Install NeMo Microservices and Volcano; `nemo_version` input; auto-commits doc/SDK updates; writes `{MACHINE}_NEMO_ACTIVE` org var. Inputs: `runner`, `nemo_version` |
| NeMo Undeploy | `undeploy-nemo.yaml` | Remove NeMo, Volcano, DNS entries, and postgres PVCs; clears `{MACHINE}_NEMO_ACTIVE` org var. Inputs: `runner` |
| MLflow Deploy | `deploy-mlflow.yaml` | Deploy MLflow + MinIO into k3s `mlflow-system` namespace; writes `{MACHINE}_MLFLOW_ACTIVE` org var. Inputs: `runner` |
| MLflow Undeploy | `undeploy-mlflow.yaml` | Remove MLflow namespace; clears `{MACHINE}_MLFLOW_ACTIVE` org var. Inputs: `runner` |
| Qdrant Deploy | `deploy-qdrant.yaml` | Deploy Qdrant vector database into k3s `qdrant-system` namespace; restarts `qdrant-portfwd` on host; writes `{MACHINE}_QDRANT_ACTIVE` org var. Inputs: `runner` |
| Qdrant Undeploy | `undeploy-qdrant.yaml` | Remove Qdrant and delete namespace; clears `{MACHINE}_QDRANT_ACTIVE` org var. Inputs: `runner` |
| NIM Deploy | `deploy-nim.yaml` | Deploy a NIM via NeMo API; swaps conflicting NIM; rollback on failure; writes `CURRENT_NIM_MODEL[_AGX]` + `CURRENT_NIM_VRAM_GB[_AGX]`. Inputs: `runner` |
| NIM Undeploy | `undeploy-nim.yaml` | Remove a NIM deployment; clears `CURRENT_NIM_MODEL[_AGX]` + `CURRENT_NIM_VRAM_GB[_AGX]`. Inputs: `runner` |
| Ollama Deploy | `deploy-ollama.yaml` | Auto-undeploy existing model, pull + load new one; NIM co-deployment allowed if free memory ≥ 15 GB; rollback on failure; writes `CURRENT_OLLAMA_MODEL[_AGX]` + `CURRENT_OLLAMA_VRAM_GB[_AGX]` and `{MACHINE}_OLLAMA_ACTIVE` org var. Inputs: `runner` |
| Ollama Undeploy | `undeploy-ollama.yaml` | Unload/delete an Ollama model; clears `CURRENT_OLLAMA_MODEL[_AGX]` + `CURRENT_OLLAMA_VRAM_GB[_AGX]` and `{MACHINE}_OLLAMA_ACTIVE` org var. Inputs: `runner` |
| Ollama Update | `update-ollama.yaml` | Install or upgrade Ollama on target host; writes `OLLAMA_VERSION`. Inputs: `runner` |

| Build KFP arm64 Images | `build-kfp-arm64.yaml` | Build all 13 KFP arm64 images on DGX; optional `component` input to rebuild one. Images are reusable on AGX (both `linux/arm64`). |
| Kubeflow Deploy | `deploy-kubeflow.yaml` | Deploy KFP standalone with native arm64 images; creates `hf-model-cache` (200 Gi) and `nsight-reports` (50 Gi) PVs + PVCs in the `kubeflow` namespace backed by k3s hostPath PVs; writes `{MACHINE}_KFP_ACTIVE` org var. Inputs: `runner` |
| Kubeflow Undeploy | `undeploy-kubeflow.yaml` | Remove KFP and cluster-scoped resources; clears `{MACHINE}_KFP_ACTIVE` org var. Inputs: `runner` |

Stack deployment order:

```text
DGX: K3s Install -> NeMo Deploy -> MLflow Deploy -> Qdrant Deploy -> Kubeflow Deploy -> NIM Deploy (or Ollama Deploy)
AGX: K3s Install -> NeMo Deploy -> MLflow Deploy -> Qdrant Deploy -> Kubeflow Deploy -> Ollama Deploy
```

NIM is DGX-only — all NIM LLM containers are `linux/amd64`; no `linux/arm64` images exist.

**Platform state repo variables** (NIM/Ollama current model + VRAM):

| Variable | Written by | Cleared by | Default |
| --- | --- | --- | --- |
| `CURRENT_NIM_MODEL` | NIM Deploy (dgx) | NIM Undeploy, rollback | `none` |
| `CURRENT_OLLAMA_MODEL` | Ollama Deploy (dgx) | Ollama Undeploy, rollback | `none` |
| `CURRENT_NIM_VRAM_GB` | NIM Deploy (dgx) | NIM Undeploy, rollback | `0` |
| `CURRENT_OLLAMA_VRAM_GB` | Ollama Deploy (dgx) | Ollama Undeploy, rollback | `0` |
| `CURRENT_NIM_MODEL_AGX` | NIM Deploy (agx) | NIM Undeploy (agx), rollback | `none` |
| `CURRENT_OLLAMA_MODEL_AGX` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback | `none` |
| `CURRENT_NIM_VRAM_GB_AGX` | NIM Deploy (agx) | NIM Undeploy (agx), rollback | `0` |
| `CURRENT_OLLAMA_VRAM_GB_AGX` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback | `0` |

**Active state org variables** (drive the green/red dashboard badges; seed with `gh api` on fresh install):

| Variable | Set to `true` by | Set to `false` by |
| --- | --- | --- |
| `DGX_K3S_ACTIVE` | K3s Install (dgx) | K3s Uninstall (dgx) |
| `AGX_K3S_ACTIVE` | K3s Install (agx) | K3s Uninstall (agx) |
| `DGX_NEMO_ACTIVE` | NeMo Deploy (dgx) | NeMo Undeploy (dgx) |
| `AGX_NEMO_ACTIVE` | NeMo Deploy (agx) | NeMo Undeploy (agx) |
| `DGX_MLFLOW_ACTIVE` | MLflow Deploy (dgx) | MLflow Undeploy (dgx) |
| `AGX_MLFLOW_ACTIVE` | MLflow Deploy (agx) | MLflow Undeploy (agx) |
| `DGX_QDRANT_ACTIVE` | Qdrant Deploy (dgx) | Qdrant Undeploy (dgx) |
| `AGX_QDRANT_ACTIVE` | Qdrant Deploy (agx) | Qdrant Undeploy (agx) |
| `DGX_KFP_ACTIVE` | Kubeflow Deploy (dgx) | Kubeflow Undeploy (dgx) |
| `AGX_KFP_ACTIVE` | Kubeflow Deploy (agx) | Kubeflow Undeploy (agx) |
| `DGX_OLLAMA_ACTIVE` | Ollama Deploy (dgx) | Ollama Undeploy (dgx), rollback |
| `AGX_OLLAMA_ACTIVE` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback |
| `GKE_GPU_POOL_ACTIVE` | GKE Expand GPU | GKE Restore GPU |

**GCP pool org variables** (drive the CPU/GPU pool badges on the dashboard):

| Variable | Set by | Reset by | Default |
| --- | --- | --- | --- |
| `GKE_NODE_COUNT` | GKE Expand (expanded count) | GKE Restore (resets to `1`) | `1` |
| `GKE_GPU_POOL_ACTIVE` | GKE Expand GPU | GKE Restore GPU | `false` |
| `GKE_GPU_TYPE` | GKE Expand GPU (e.g. `nvidia-l4`) | GKE Restore GPU | `none` |

On a fresh install, seed the active state with `gh api` PATCH→POST upserts using `GITHUB_ORG_ADMIN_PAT` to reflect actual current state.

See [dgx.md](dgx.md), [../dgx/minikube/](../dgx/minikube/),
[../dgx/minikube/qdrant/README.md](../dgx/minikube/qdrant/README.md), and
[../dgx/ollama/README.md](../dgx/ollama/README.md).

## Projects and Dashboard

| Workflow | File | Purpose |
| --- | --- | --- |
| Create Project | `create-project.yaml` | Create a new org repo pre-wired for the platform. `host` input (dgx/agx) sets which machine clones the repo and writes `PROJECT_HOST`. Tags repo `miramar-project` + `miramar-<type>` for the dashboard. Opens a draft blog post PR. See project types and Python environment below. |
| Delete Project | `delete-project.yaml` | Permanently delete a platform repo. Verifies repo exists first (fails fast with a clear error). Double-entry confirmation guard. Cleans up blog draft PR/branch, local clone on host, and JupyterLab kernel. Triggers dashboard refresh on completion. Requires `delete_repo` scope on `GITHUB_ORG_ADMIN_PAT`. |
| Deploy Platform Dashboard | `deploy-dashboard.yaml` | Build and publish the GitHub Pages project dashboard. Three status bars: DGX Spark, AGX Orin (NeMo/KFP/Ollama/NIM model+VRAM/k3s/MLflow/Qdrant), and GCP (GKE cluster link, Zone, Node type, CPU pool node count, GPU pool badge, State bucket, GAR link). Header includes a + New Project button that opens a form modal and dispatches `create-project.yaml`. Project table includes Host column, JupyterLab links, and a 🗑 delete button per row that fires `delete-project.yaml` via GitHub API using `DASHBOARD_DISPATCH_TOKEN` (fine-grained PAT baked into HTML at generation time — no browser input required). Runs hourly + on completion of any state-writing workflow. URL: https://miramar-labs-org.github.io/miramar-platform-gcp/ |
| List Blog Posts | `list-blog-posts.yaml` | List all live posts and open draft PRs in `miramar-labs-org/miramar-labs-org.github.io`. Run before Delete Blog Post to get the exact filename. |
| Delete Blog Post | `delete-blog-post.yaml` | Delete a post from `miramar-labs-org/miramar-labs-org.github.io` by filename; closes any open draft PR and removes the draft branch. GitHub Pages rebuilds in ~60s. |

### Project types

| Type | Template includes | Extra packages added to `requirements.txt` |
| --- | --- | --- |
| `default` | Notebook + platform endpoint reference | — |
| `kfp` | KFP v2 pipeline stub, notebook, `deploy-kfp.yaml` / `undeploy-kfp.yaml` workflows + CI badges | `kfp>=2.0.0` |
| `kfp-ft-eval` | KFP v2 eval-first fine-tuning pipeline: 6 `@dsl.component` steps (prepare_dataset → baseline_eval → baseline_safety_eval → fine_tune → post_finetune_eval → safety_eval → deployment_gate), config-driven via `config.yaml` + `formatters.py` + `loaders.py`, Build cell to regenerate `pipeline.py`, `deploy-kfp.yaml` / `undeploy-kfp.yaml` workflows + CI badges. Topic tag `miramar-kfp-ft-eval`. | `kfp>=2.0.0` |
| `nemo` | NeMo training config, notebook, `deploy-nemo.yaml` / `undeploy-nemo.yaml` workflows + CI badges | `nemo-microservices` |
| `llm-serving-vllm` | vLLM LoRA adapter serving on GKE L4 spot: `serving-config.yaml` (base model, stable alias, manifest URI), `Dockerfile.serve`, `k8s/vllm.yaml` (init container pulls adapter from GCS, main container runs vLLM), `build-push.yaml` / `deploy.yaml` / `undeploy.yaml` workflows + CI badges, `smoke_test_prompts.jsonl` | — |

### Model serving (llm-serving-vllm projects)

Per-project workflows in every `llm-serving-vllm` repo:

| Workflow | File | Runner | Purpose |
| --- | --- | --- | --- |
| Build and Push | `build-push.yaml` | `wsl2` | Build `Dockerfile.serve` (amd64 for GKE), push to GAR as `:latest` + commit SHA tag |
| Deploy | `deploy.yaml` | `wsl2` | Resolve + validate manifest (blocks if `eval_passed` or `safety_passed` is false), expand L4 spot GPU pool, apply `k8s/vllm.yaml`, wait for rollout, run smoke tests from `smoke_test_prompts.jsonl` |
| Undeploy | `undeploy.yaml` | `wsl2` | Delete deployment and service, trigger `gke-restore-gpu.yaml` to tear down the GPU pool and stop costs |

**Publish adapter** — in `kfp-ft-eval` projects (after a gate-passed KFP run):

| Workflow | File | Runner | Purpose |
| --- | --- | --- | --- |
| Publish Adapter to GCS | `publish-adapter.yaml` | `dgx` | Extract eval metrics, generate `manifest.json` + `model_card.md`, upload full bundle to `gs://miramar-platform-ft-adapters/<project>/<run>/` |

The `manifest.json` is the stable contract between FT and serving projects. Set `adapter.manifest_uri` in `serving-config.yaml` after publishing, then trigger `deploy.yaml`.

### Python environment

On creation, `requirements.txt` is generated from the `requirements` workflow input (space-separated pip package names), with type-specific packages appended automatically. After the repo is cloned to the target host, a per-project `.venv` is created inside the repo, packages are installed from `requirements.txt`, and the environment is registered as a named kernel in the shared JupyterLab instance — visible as `<project-name>` in the kernel selector.

Default packages (pre-filled in the workflow input, edit freely):

```
ipykernel ipywidgets numpy pandas matplotlib seaborn scikit-learn tqdm
transformers datasets huggingface_hub evaluate accelerate
openai anthropic mlflow qdrant-client pyyaml requests python-dotenv nvidia-ml-py
```

## WSL2 and SSH

| Workflow | File | Purpose |
| --- | --- | --- |
| Setup Shared SSH Store | `setup-shared-ssh.yaml` | Initialize Spark shared SSH store and wire Orin |
| WSL2 Provision | `provision-wsl2.yaml` | Import a WSL2 distro from template and wire SSH |
| WSL2 Verify SSH Topology | `verify-ssh-topology.yaml` | Test supported Spark/Orin/WSL2 paths |
| WSL2 Unprovision | `unprovision-wsl2.yaml` | Unregister a distro and update `WSL2_DISTROS` |

See [../wsl2/README.md](../wsl2/README.md),
[../wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md), and
[ssh-runbook.md](ssh-runbook.md).
