# Workflow Catalog

All workflows are manually dispatchable unless noted otherwise.

## Platform Lifecycle

| Workflow             | File                        | Purpose                                                               |
| -------------------- | --------------------------- | --------------------------------------------------------------------- |
| GCP Platform Create  | `gcp-platform-create.yaml`  | Create state bucket, run Terraform, then apply Kubernetes setup       |
| GCP Platform Destroy | `gcp-platform-destroy.yaml` | Destroy GKE/Artifact Registry/state bucket; optional project deletion |

Destroy has three guards: exact project name, `i_confirm`, and optional
`delete_project`.

## GKE Scaling

| Workflow          | File                     | Purpose                                                      |
| ----------------- | ------------------------ | ------------------------------------------------------------ |
| GKE Expand        | `gke-expand.yaml`        | Snapshot node pool state, then resize CPU node pool          |
| GKE Restore       | `gke-restore.yaml`       | Restore node count from the saved GCS snapshot               |
| GKE Expand GPU    | `gke-expand-gpu.yaml`    | Add isolated GPU node pool, device plugin, and quota changes |
| GKE Restore GPU   | `gke-restore-gpu.yaml`   | Delete GPU node pool and restore namespace quota             |
| Find GPU Capacity | `find-gpu-capacity.yaml` | Probe GPU availability and print usable workflow settings    |

CPU and GPU expansion are independent. A typical heavy-workload sequence is:

```text
Find GPU Capacity -> GKE Expand -> GKE Expand GPU -> deploy workload -> GKE Restore GPU -> GKE Restore
```

Run **Find GPU Capacity** first to confirm availability and get the recommended zone and accelerator type before expanding.

## Local AI Stack (DGX + AGX)

All workflows accept a `runner` input (`dgx` or `agx`) to target either machine.

| Workflow        | File                   | Purpose                                                                                                                                                                                                                                                |
| --------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| K3s Install     | `install-k3s.yaml`     | Install k3s with NVIDIA device plugin + nginx-ingress; update kubeconfig secret; writes `{MACHINE}_K3S_ACTIVE` org var. Inputs: `runner`                                                                                                               |
| K3s Uninstall   | `uninstall-k3s.yaml`   | Run k3s-uninstall.sh and remove kubeconfig; clears `{MACHINE}_K3S_ACTIVE` org var. Inputs: `runner`                                                                                                                                                    |
| NeMo Deploy     | `deploy-nemo.yaml`     | Install NeMo Microservices and Volcano; `nemo_version` input; auto-commits doc/SDK updates; writes `{MACHINE}_NEMO_ACTIVE` org var. Inputs: `runner`, `nemo_version`                                                                                   |
| NeMo Undeploy   | `undeploy-nemo.yaml`   | Remove NeMo, Volcano, DNS entries, and postgres PVCs; clears `{MACHINE}_NEMO_ACTIVE` org var. Inputs: `runner`                                                                                                                                         |
| MLflow Deploy   | `deploy-mlflow.yaml`   | Deploy MLflow + MinIO into k3s `mlflow-system` namespace; writes `{MACHINE}_MLFLOW_ACTIVE` org var. Inputs: `runner`                                                                                                                                   |
| MLflow Undeploy | `undeploy-mlflow.yaml` | Remove MLflow namespace; clears `{MACHINE}_MLFLOW_ACTIVE` org var. Inputs: `runner`                                                                                                                                                                    |
| Qdrant Deploy   | `deploy-qdrant.yaml`   | Deploy Qdrant vector database into k3s `qdrant-system` namespace; restarts `qdrant-portfwd` on host; writes `{MACHINE}_QDRANT_ACTIVE` org var. Inputs: `runner`                                                                                        |
| Qdrant Undeploy | `undeploy-qdrant.yaml` | Remove Qdrant and delete namespace; clears `{MACHINE}_QDRANT_ACTIVE` org var. Inputs: `runner`                                                                                                                                                         |
| NIM Deploy      | `deploy-nim.yaml`      | Deploy a NIM via NeMo API; swaps conflicting NIM; rollback on failure; writes `CURRENT_NIM_MODEL[_AGX]` + `CURRENT_NIM_VRAM_GB[_AGX]`. Inputs: `runner`                                                                                                |
| NIM Undeploy    | `undeploy-nim.yaml`    | Remove a NIM deployment; clears `CURRENT_NIM_MODEL[_AGX]` + `CURRENT_NIM_VRAM_GB[_AGX]`. Inputs: `runner`                                                                                                                                              |
| Ollama Deploy   | `deploy-ollama.yaml`   | Auto-undeploy existing model, pull + load new one; NIM co-deployment allowed if free memory ≥ 15 GB; rollback on failure; writes `CURRENT_OLLAMA_MODEL[_AGX]` + `CURRENT_OLLAMA_VRAM_GB[_AGX]` and `{MACHINE}_OLLAMA_ACTIVE` org var. Inputs: `runner` |
| Ollama Undeploy | `undeploy-ollama.yaml` | Unload/delete an Ollama model; clears `CURRENT_OLLAMA_MODEL[_AGX]` + `CURRENT_OLLAMA_VRAM_GB[_AGX]` and `{MACHINE}_OLLAMA_ACTIVE` org var. Inputs: `runner`                                                                                            |
| Ollama Update   | `update-ollama.yaml`   | Install or upgrade Ollama on target host; writes `OLLAMA_VERSION`. Inputs: `runner`                                                                                                                                                                    |

| Nsight Operator Deploy      | `deploy-nsight-operator.yaml`      | Install NVIDIA Nsight Operator via Helm on DGX/AGX; writes `{MACHINE}_NSIGHT_OPERATOR_ACTIVE`. Inputs: `runner` |
| Nsight Operator Undeploy    | `undeploy-nsight-operator.yaml`    | Helm uninstall Nsight Operator; clears `{MACHINE}_NSIGHT_OPERATOR_ACTIVE`. Inputs: `runner` |
| Nsight Operator Deploy GKE  | `deploy-nsight-operator-gke.yaml`  | Install Nsight Operator on GKE with dynamic PVC; wsl2 runner; writes `GKE_NSIGHT_OPERATOR_ACTIVE` |
| Nsight Operator Undeploy GKE | `undeploy-nsight-operator-gke.yaml` | Helm uninstall Nsight Operator from GKE; clears `GKE_NSIGHT_OPERATOR_ACTIVE` |
| Open WebUI Deploy       | `deploy-openwebui.yaml`       | Deploy Open WebUI on DGX/AGX/GKE; wires to active serving backend (NIM, Ollama, or vLLM); writes `{MACHINE}_OPENWEBUI_ACTIVE`. Inputs: `host` |
| Open WebUI Undeploy     | `undeploy-openwebui.yaml`     | Remove Open WebUI; stop port-forward; clears `{MACHINE}_OPENWEBUI_ACTIVE`. Inputs: `host` |

| Build KFP Base Images  | `build-kfp-base-images.yaml` | Build `kfp-base-cpu` + `kfp-base-gpu` pre-built base images; push to GHCR; upserts `ghcr-pull-secret` in kubeflow namespace. Input: `image: cpu \| gpu \| both`. Run this when adding packages to any KFP pipeline stage type. |
| Build KFP arm64 Images | `build-kfp-arm64.yaml`   | Build all 13 KFP arm64 images on DGX; optional `component` input to rebuild one. Images are reusable on AGX (both `linux/arm64`).                                                                                                         |
| Kubeflow Deploy        | `deploy-kubeflow.yaml`   | Deploy KFP standalone with native arm64 images; creates `hf-model-cache` (200 Gi) and `nsight-reports` (50 Gi) PVs + PVCs in the `kubeflow` namespace backed by k3s hostPath PVs; writes `{MACHINE}_KFP_ACTIVE` org var. Inputs: `runner` |
| Kubeflow Undeploy      | `undeploy-kubeflow.yaml` | Remove KFP and cluster-scoped resources; clears `{MACHINE}_KFP_ACTIVE` org var. Inputs: `runner`                                                                                                                                          |

Stack deployment order:

```text
DGX: K3s Install -> NeMo Deploy -> MLflow Deploy -> Qdrant Deploy -> Kubeflow Deploy -> NIM Deploy (or Ollama Deploy)
AGX: K3s Install -> NeMo Deploy -> MLflow Deploy -> Qdrant Deploy -> Kubeflow Deploy -> Ollama Deploy
```

NIM is DGX-only — all NIM LLM containers are `linux/amd64`; no `linux/arm64` images exist.

**Platform state repo variables** (NIM/Ollama current model + VRAM):

| Variable                     | Written by          | Cleared by                      | Default |
| ---------------------------- | ------------------- | ------------------------------- | ------- |
| `CURRENT_NIM_MODEL`          | NIM Deploy (dgx)    | NIM Undeploy, rollback          | `none`  |
| `CURRENT_OLLAMA_MODEL`       | Ollama Deploy (dgx) | Ollama Undeploy, rollback       | `none`  |
| `CURRENT_NIM_VRAM_GB`        | NIM Deploy (dgx)    | NIM Undeploy, rollback          | `0`     |
| `CURRENT_OLLAMA_VRAM_GB`     | Ollama Deploy (dgx) | Ollama Undeploy, rollback       | `0`     |
| `CURRENT_NIM_MODEL_AGX`      | NIM Deploy (agx)    | NIM Undeploy (agx), rollback    | `none`  |
| `CURRENT_OLLAMA_MODEL_AGX`   | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback | `none`  |
| `CURRENT_NIM_VRAM_GB_AGX`    | NIM Deploy (agx)    | NIM Undeploy (agx), rollback    | `0`     |
| `CURRENT_OLLAMA_VRAM_GB_AGX` | Ollama Deploy (agx) | Ollama Undeploy (agx), rollback | `0`     |

**Active state org variables** (drive the green/red dashboard badges; seed with `gh api` on fresh install):

| Variable              | Set to `true` by      | Set to `false` by               |
| --------------------- | --------------------- | ------------------------------- |
| `DGX_K3S_ACTIVE`      | K3s Install (dgx)     | K3s Uninstall (dgx)             |
| `AGX_K3S_ACTIVE`      | K3s Install (agx)     | K3s Uninstall (agx)             |
| `DGX_NEMO_ACTIVE`     | NeMo Deploy (dgx)     | NeMo Undeploy (dgx)             |
| `AGX_NEMO_ACTIVE`     | NeMo Deploy (agx)     | NeMo Undeploy (agx)             |
| `DGX_MLFLOW_ACTIVE`   | MLflow Deploy (dgx)   | MLflow Undeploy (dgx)           |
| `AGX_MLFLOW_ACTIVE`   | MLflow Deploy (agx)   | MLflow Undeploy (agx)           |
| `DGX_QDRANT_ACTIVE`   | Qdrant Deploy (dgx)   | Qdrant Undeploy (dgx)           |
| `AGX_QDRANT_ACTIVE`   | Qdrant Deploy (agx)   | Qdrant Undeploy (agx)           |
| `DGX_KFP_ACTIVE`      | Kubeflow Deploy (dgx) | Kubeflow Undeploy (dgx)         |
| `AGX_KFP_ACTIVE`      | Kubeflow Deploy (agx) | Kubeflow Undeploy (agx)         |
| `DGX_OLLAMA_ACTIVE`          | Ollama Deploy (dgx)                             | Ollama Undeploy (dgx), rollback |
| `AGX_OLLAMA_ACTIVE`          | Ollama Deploy (agx)                             | Ollama Undeploy (agx), rollback |
| `DGX_NSIGHT_OPERATOR_ACTIVE` | Nsight Operator Deploy (dgx)                    | Nsight Operator Undeploy (dgx)  |
| `AGX_NSIGHT_OPERATOR_ACTIVE` | Nsight Operator Deploy (agx)                    | Nsight Operator Undeploy (agx)  |
| `GKE_NSIGHT_OPERATOR_ACTIVE` | Nsight Operator Deploy GKE; GCP Platform Create | Nsight Operator Undeploy GKE    |
| `GKE_GPU_POOL_ACTIVE`        | GKE Expand GPU                                  | GKE Restore GPU                 |

**GCP pool org variables** (drive the CPU/GPU pool badges on the dashboard):

| Variable              | Set by                                                      | Reset by                                        | Default |
| --------------------- | ----------------------------------------------------------- | ----------------------------------------------- | ------- |
| `GKE_CLUSTER_ACTIVE`  | GCP Platform Create                                         | GCP Platform Destroy (resets to `false`)        | `false` |
| `GKE_NODE_COUNT`      | GKE Expand (value: target node count)                       | GKE Restore (resets to `1`), GCP Platform Destroy | `1`   |
| `GKE_GPU_POOL_ACTIVE` | GKE Expand GPU                                              | GKE Restore GPU, GCP Platform Destroy           | `false` |
| `GKE_GPU_TYPE`        | GKE Expand GPU (value: accelerator type, e.g. `nvidia-l4`) | GKE Restore GPU, GCP Platform Destroy           | `none`  |

On a fresh install, seed the active state with `gh api` PATCH→POST upserts using `GITHUB_ORG_ADMIN_PAT` to reflect actual current state.

See [dgx.md](dgx.md), [../dgx/minikube/](../dgx/minikube/),
[../dgx/minikube/qdrant/README.md](../dgx/minikube/qdrant/README.md), and
[../dgx/ollama/README.md](../dgx/ollama/README.md).

## Projects and Dashboard

| Workflow                  | File                    | Purpose                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Create Project            | `create-project.yaml`   | Create a new org repo pre-wired for the platform. `host` input (dgx/agx) sets which machine clones the repo and writes `PROJECT_HOST`. Tags repo `miramar-project` + `miramar-<type>` for the dashboard. Opens a draft blog post PR. See project types and Python environment below.                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Delete Project            | `delete-project.yaml`   | Permanently delete a platform repo. Verifies repo exists first (fails fast with a clear error). Double-entry confirmation guard. Cleans up blog draft PR/branch, local clone on host, and JupyterLab kernel. Triggers dashboard refresh on completion. Requires `delete_repo` scope on `GITHUB_ORG_ADMIN_PAT`.                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| Deploy Platform Dashboard | `deploy-dashboard.yaml` | Build and publish the GitHub Pages project dashboard. Three status bars: DGX Spark, AGX Orin (NeMo/KFP/Ollama/NIM model+VRAM/k3s/MLflow/Qdrant), and GCP (GKE cluster link, Zone, Node type, CPU pool node count, GPU pool badge, State bucket, GAR link). Header includes a + New Project button that opens a form modal and dispatches `create-project.yaml`. Project table includes Host column, JupyterLab links, and a 🗑 delete button per row that fires `delete-project.yaml` via GitHub API using `DASHBOARD_DISPATCH_TOKEN` (fine-grained PAT baked into HTML at generation time — no browser input required). Runs hourly + on completion of any state-writing workflow. URL: https://miramar-labs-org.github.io/miramar-platform-gcp/ |
| List Blog Posts           | `list-blog-posts.yaml`  | List all live posts and open draft PRs in `miramar-labs-org/miramar-labs-org.github.io`. Run before Delete Blog Post to get the exact filename.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| Delete Blog Post          | `delete-blog-post.yaml` | Delete a post from `miramar-labs-org/miramar-labs-org.github.io` by filename; closes any open draft PR and removes the draft branch. GitHub Pages rebuilds in ~60s.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |

### Project types

| Type               | Template includes                                                                                                                                                                                                                                                                                                                                                                                     | Extra packages added to `requirements.txt` |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| `default`          | Notebook + platform endpoint reference                                                                                                                                                                                                                                                                                                                                                                | —                                          |
| `kfp`              | KFP v2 pipeline stub, notebook, `deploy-kfp.yaml` / `undeploy-kfp.yaml` workflows + CI badges                                                                                                                                                                                                                                                                                                         | `kfp>=2.0.0`                               |
| `ft-eval`          | KFP v2 eval-first fine-tuning pipeline: 8-stage pipeline (download_model → prepare_dataset → baseline_eval → baseline_safety_eval → fine_tune → post_finetune_eval → safety_eval → deployment_gate), config-driven via `config.yaml` + `formatters.py` + `loaders.py`, Build cell to regenerate `pipeline.py`, `deploy-to-kfp.yaml` / `undeploy-from-kfp.yaml` workflows + CI badges. Topic tag `miramar-ft-eval`. | `kfp>=2.0.0`                               |
| `nemo-ft-eval`     | NeMo Customizer fine-tuning + eval pipeline: 9-stage pipeline (download_model → prepare_dataset → baseline_eval → baseline_safety_eval → fine_tune → export_adapter → post_finetune_eval → safety_eval → deployment_gate), async NeMo Customizer job, `nemo2hf` checkpoint export, `deploy-to-kfp.yaml` / `undeploy-from-kfp.yaml` workflows + CI badges. Topic tag `miramar-nemo-ft-eval`. | `kfp>=2.0.0 kfp-kubernetes nemo-microservices` |
| `serving-vllm`     | vLLM LoRA adapter serving on GKE L4 spot: `serving-config.yaml` (base model, stable alias, manifest URI), `Dockerfile.serve`, `k8s/vllm.yaml` (init container pulls adapter from GCS, main container runs vLLM), `build-push.yaml` / `deploy.yaml` / `undeploy.yaml` workflows + CI badges, `smoke_test_prompts.jsonl`                                                                                      | —                                          |
| `serving-nim`      | Stock NGC NIM model serving on DGX/AGX/GKE: `serving-config.yaml` (NIM org/model/image tags), `k8s/nim-k3s.yaml` (K3s, nvcr-pull secret, NIM cache hostPath), `k8s/nim.yaml` (GKE, emptyDir cache), `deploy.yaml` / `undeploy.yaml` workflows + CI badges, `smoke_test_prompts.jsonl`. No build step — pulls NGC image at deploy time.                                                                        | —                                          |
| `serving-llm-nim`  | Local or HuggingFace model serving on DGX via NVIDIA Multi-LLM NIM (`nvcr.io/nim/nvidia/llm-nim`). Two modes auto-detected from `model.model_path` in `serving-config.yaml`: **local** (`/abs/path` → `k8s/nim-local-k3s.yaml`, hostPath volume mount, TRT-LLM engine compiled on first start and cached in `~/shared/nim-cache`) / **hf** (`hf://org/model` or `org/model` → `k8s/nim-hf-k3s.yaml`, NIM downloads weights, optional `HF_TOKEN` secret). Sets `DGX_SERVING_ACTIVE` on success. DGX K3s only — no GKE target. Naming convention: `<model-descriptor>-serving-llm-nim`. | —                                          |
| `serving-trt-fp8`  | FP8-quantized HF checkpoint served via vLLM on DGX/AGX/GKE: `serving-config.yaml` (compression project + run_id, vLLM flags), `Dockerfile.serve` (bakes quantized model into image for GKE), `k8s/vllm-trt-fp8-k3s.yaml` (K3s, model hostPath from `~/shared/huggingface-kfp/quantization/`), `k8s/vllm-trt-fp8.yaml` (GKE, GAR image), `build-push.yaml` (GKE only) / `deploy.yaml` / `undeploy.yaml`. | —                                          |
| `serving-trt-engine` | Compiled TRT-LLM engine served via `tensorrt_llm.serve` on DGX/AGX/GKE: `serving-config.yaml` (compression project + run_id), GPU-arch engine subdirs (`engine_gb10/` DGX, `engine_sm87/` AGX, `engine_l4/` GKE) under `~/shared/huggingface-kfp/engines/`, `k8s/trtllm-k3s.yaml` (K3s, nvcr-pull secret, engine hostPath), `Dockerfile.serve` + `build-push.yaml` (GKE only) / `deploy.yaml` / `undeploy.yaml`. | —                                      |
| `kfp-rag`          | KFP v2 RAG pipeline with eval-first design: 6-stage pipeline (ingest_documents → retrieval_eval → generation_eval → faithfulness_eval → safety_eval → deployment_gate), Qdrant-backed (`BAAI/bge-small-en-v1.5` CPU embeddings), LLM-as-judge scoring (RAGAS-style metrics — faithfulness, citation coverage, safety — no `ragas` package), MLflow per-stage logging, optional LangSmith tracing, `deploy-to-kfp.yaml` / `undeploy-from-kfp.yaml` workflows + CI badges. ingest_documents and deployment_gate are fully implemented; the four eval steps are USER CODE BLOCKs with patterns in `WORKBOOK.md`. Topic tag `miramar-rag`. | `kfp>=2.0.0 kfp-kubernetes langchain langchain-text-splitters langchain-qdrant langsmith qdrant-client sentence-transformers` |
| `kfp-nemo-curator`      | KFP v2 NeMo Curator data-curation pipeline: 6-stage pipeline (preflight_check → extract_text → quality_filter → deduplication → pii_redaction → curator_report). CPU stages use `python:3.11-slim`; GPU stages (`quality_filter`, `deduplication`) use `nvcr.io/nvidia/pytorch:26.04-py3` + RAPIDS cuDF backend via `nemo-curator[cuda12x]` from `pypi.nvidia.com`. MLflow per-stage metrics (docs_in/out, rejection_rate, exact/fuzzy_removed, PII instances). preflight_check and curator_report are fully implemented; the four curation steps are USER CODE BLOCKs with patterns in `WORKBOOK.md`. RAPIDS arm64 wheel availability is the key first-run risk — see WORKBOOK.md fallback. Topic tag `miramar-curator`. | `kfp>=2.0.0 kfp-kubernetes nemo-curator trafilatura ftfy presidio-analyzer presidio-anonymizer spacy` |

### Model serving (serving-* projects)

Per-project workflows in every `serving-vllm` repo:

| Workflow       | File              | Runner | Purpose                                                                                                                                                                                              |
| -------------- | ----------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Build and Push | `build-push.yaml` | `wsl2` | Build `Dockerfile.serve` (amd64 for GKE), push to GAR as `:latest` + commit SHA tag                                                                                                                  |
| Deploy         | `deploy.yaml`     | `wsl2` | Resolve + validate manifest (blocks if `eval_passed` or `safety_passed` is false), expand L4 spot GPU pool, apply `k8s/vllm.yaml`, wait for rollout, run smoke tests from `smoke_test_prompts.jsonl` |
| Undeploy       | `undeploy.yaml`   | `wsl2` | Delete deployment and service, trigger `gke-restore-gpu.yaml` to tear down the GPU pool and stop costs                                                                                               |

Per-project workflows in every `serving-nim` repo:

| Workflow | File             | Runner             | Purpose                                                                                                    |
| -------- | ---------------- | ------------------ | ---------------------------------------------------------------------------------------------------------- |
| Deploy   | `deploy.yaml`    | `dgx` / `agx` / `ubuntu-latest` | Pull NGC NIM image, create `nvcr-pull` secret, deploy to K3s or GKE, 30-min rollout wait, smoke tests |
| Undeploy | `undeploy.yaml`  | `dgx` / `agx` / `ubuntu-latest` | Delete `nim` deployment + service; GKE also triggers `gke-restore-gpu.yaml`                            |

Per-project workflows in every `serving-llm-nim` repo:

| Workflow | File            | Job ID               | Runner | Purpose                                                                                                                                                         |
| -------- | --------------- | -------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deploy   | `deploy.yaml`   | `deploy-llm-nim-dgx` | `dgx`  | Read `serving-config.yaml`, detect mode (local vs hf), preflight (verify path or log HF model ID, `chmod 777` nim-cache), unserve Ollama, apply manifest, 60-min rollout wait, smoke test, set `DGX_SERVING_ACTIVE=true`, wire Open WebUI backend |
| Undeploy | `undeploy.yaml` | `undeploy-llm-nim-dgx` | `dgx` | Delete `nim` deployment + service, set `DGX_SERVING_ACTIVE=false`, clear Open WebUI backend URL                                                                |

Per-project workflows in every `serving-trt-fp8` repo:

| Workflow       | File              | Runner             | Purpose                                                                                                                      |
| -------------- | ----------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| Build and Push | `build-push.yaml` | `wsl2`             | Resolve FP8 quantized checkpoint from `~/shared/huggingface-kfp/quantization/`, build `Dockerfile.serve`, push to GAR       |
| Deploy         | `deploy.yaml`     | `dgx` / `agx` / `ubuntu-latest` | Mount quantized model via hostPath (K3s) or GAR image (GKE), deploy vLLM with `--quantization=fp8`, smoke tests |
| Undeploy       | `undeploy.yaml`   | `dgx` / `agx` / `ubuntu-latest` | Delete `vllm` deployment + service; GKE also triggers `gke-restore-gpu.yaml`                                     |

Per-project workflows in every `serving-trt-engine` repo:

| Workflow | File             | Runner             | Purpose                                                                                                                           |
| -------- | ---------------- | ------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| Build and Push | `build-push.yaml` | `wsl2`       | Resolve `engine_l4/` artifact from `~/shared/huggingface-kfp/engines/`, build `Dockerfile.serve`, push to GAR (GKE only)        |
| Deploy   | `deploy.yaml`    | `dgx` / `agx` / `ubuntu-latest` | Mount engine via hostPath (K3s: `engine_gb10/` DGX, `engine_sm87/` AGX) or GAR image (GKE), serve via `tensorrt_llm.serve` |
| Undeploy | `undeploy.yaml`  | `dgx` / `agx` / `ubuntu-latest` | Delete `trtllm` deployment + service; GKE also triggers `gke-restore-gpu.yaml`                                             |

**Publish adapter** — in `ft-eval` projects (after a gate-passed KFP run):

| Workflow               | File                   | Runner | Purpose                                                                                                                                      |
| ---------------------- | ---------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Publish Adapter to GCS | `publish-adapter.yaml` | `dgx`  | Extract eval metrics, generate `manifest.json` + `model_card.md`, upload full bundle to `gs://miramar-platform-ft-adapters/<project>/<run>/` |

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

| Workflow                 | File                       | Purpose                                         |
| ------------------------ | -------------------------- | ----------------------------------------------- |
| Setup Shared SSH Store   | `setup-shared-ssh.yaml`    | Initialize Spark shared SSH store and wire Orin |
| WSL2 Provision           | `provision-wsl2.yaml`      | Import a WSL2 distro from template and wire SSH |
| WSL2 Verify SSH Topology | `verify-ssh-topology.yaml` | Test supported Spark/Orin/WSL2 paths            |
| WSL2 Unprovision         | `unprovision-wsl2.yaml`    | Unregister a distro and update `WSL2_DISTROS`   |

## Maintenance

| Workflow          | File                      | Trigger                    | Purpose                                                                                       |
| ----------------- | ------------------------- | -------------------------- | --------------------------------------------------------------------------------------------- |
| Repo Code Quality | `repo-quality-manual.yaml` | `workflow_dispatch`        | Run formatters/linters (shfmt, shellcheck, yamllint) in check mode; set `fix_mode=true` to auto-fix |
| Build MLABS Runner | `build-mlabs-runner.yml` | push to `main` + `workflow_dispatch` | Build + push multi-arch `mlabs-runner` image to GHCR (`linux/amd64`, `linux/arm64`)   |

See [../wsl2/README.md](../wsl2/README.md),
[../wsl2/TECHNICAL.md](../wsl2/TECHNICAL.md), and
[ssh-runbook.md](ssh-runbook.md).
