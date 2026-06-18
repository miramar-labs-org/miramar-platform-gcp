# So What?

## Question

**What did Aaron build, why is it impressive, and what skills does this prove?**

## Answer

Aaron built a **hybrid DGX + GCP AI platform** for running the full applied LLM lifecycle: fine-tuning, evaluation, safety gating, adapter publishing, model serving, RAG evaluation, GPU profiling, observability, and agent-assisted operations.

This is not a sample app, a notebook demo, or a loose collection of scripts. It is a working AI platform pattern for developing, validating, serving, profiling, and operating applied LLM workloads across local GPU systems and Google Cloud.

The platform connects:

```text
GitHub Actions control plane
  ↓
Custom multi-arch self-hosted runner image
  ↓
WSL2 / DGX Spark / Jetson AGX Orin
  ↓
DGX/AGX k3s + GCP/GKE
  ↓
Kubeflow Pipelines · MLflow · Qdrant · NeMo/NIM · Ollama · Nsight Operator
  ↓
ft-eval · serving-vllm · serving-nim · serving-trt-fp8 · serving-trt-engine · RAG pipelines
  ↓
GitHub Pages dashboard · project factory · agent-assisted run operations
```

The core lifecycle is:

```text
Fine-tune and evaluate locally on DGX
  → gate on quality and safety
  → publish only approved non-PHI artifacts
  → serve on DGX / AGX / GKE
  → observe, profile, benchmark, and iterate
```

The platform has been validated through concrete workloads:

* **Qwen2.5 ARC fine-tuning/eval** — a gate-passed LoRA fine-tuning pipeline with baseline eval, fine-tune, post-FT eval, safety eval, and deployment gate.
* **BioMistral oncology fine-tuning** — a gate-passed oncology QA LoRA run with adapter artifacts published to GCS.
* **Qwen2.5 ARC RAG** — a gate-passed RAG pipeline with retrieval, generation, faithfulness, citation coverage, unsupported-claim, and safety metrics.
* **Reusable serving templates** — project types for vLLM LoRA serving, NIM serving, FP8 vLLM serving, and TensorRT-LLM engine serving across DGX, AGX, and GKE targets.

## What the platform includes

The repo demonstrates:

* A custom CUDA-based GitHub Actions runner image.
* Multi-architecture support for `amd64` and `arm64`.
* Self-hosted runners for WSL2, DGX Spark, and Jetson AGX Orin targets.
* Terraform-managed Google Cloud infrastructure.
* GKE platform lifecycle automation.
* Transient GKE L4 GPU pool workflows for cost-controlled serving.
* GHCR and Artifact Registry container publishing.
* Workload Identity Federation for keyless GitHub Actions authentication to GCP.
* DGX/AGX k3s clusters for local GPU platform services.
* Kubeflow Pipelines for fine-tuning, evaluation, RAG, and future optimization pipelines.
* MLflow for experiment tracking and metric history.
* Qdrant for vector search and RAG.
* NeMo/NIM and Ollama for local model serving.
* Nsight Operator for CUDA/NVTX profiling through Kubernetes pod injection.
* GitHub Pages platform dashboard with service state, project inventory, and operational links.
* A project factory that scaffolds new applied AI repos with JupyterLab integration, GitHub Actions workflows, platform endpoints, documentation, and dashboard registration.
* Agent-assisted operations through Claude/Codex workflows for deployment, run monitoring, model-card lookup, status logging, and Nsight report interpretation.
* Optional W&B, LangSmith, and Slack integrations for external tracking, tracing, and operational notifications.
* Repo-quality automation for Terraform, shell, YAML, Dockerfiles, GitHub Actions, and formatting checks.

## Why is this impressive?

It is impressive because it shows a real **AI platform engineering system**, not a toy project.

The difficult part is not any single tool. The difficult part is integrating:

```text
GitHub Actions
Docker
CUDA
GCP
Terraform
Kubernetes / k3s / GKE
GHCR
Artifact Registry
GCS
DGX-class GPU hardware
Kubeflow Pipelines
MLflow
Qdrant
NIM
Ollama
vLLM
TensorRT-LLM
Nsight Operator
agent-assisted operations
dashboard state
security boundaries
CI hygiene
```

into something repeatable, observable, and reviewable.

The platform demonstrates a complete applied LLM lifecycle:

```text
Project creation
  → notebook-first implementation
  → KFP deployment
  → baseline evaluation
  → fine-tuning or RAG execution
  → post-run evaluation
  → safety and quality gates
  → artifact publication
  → serving
  → monitoring and profiling
  → dashboard visibility
```

That is the connective tissue real AI teams need.

## Fine-tuning and evaluation

The `ft-eval` project type provides an eval-first fine-tuning pattern.

A typical pipeline performs:

```text
download_model
  → prepare_dataset
  → baseline_eval
  → baseline_safety_eval
  → fine_tune
  → post_finetune_eval
  → safety_eval
  → deployment_gate
```

This pattern proves more than model training. It proves that the platform can measure whether a fine-tuned model actually improved, whether it regressed on safety, and whether the resulting adapter should be allowed to move toward serving.

The platform has already validated this pattern through Qwen2.5 and BioMistral projects. BioMistral is especially important because it demonstrates a domain-specific oncology QA workload with a gate-passed LoRA adapter published as a reusable artifact.

## RAG evaluation

The platform now also supports a RAG-style evaluation pattern.

The Qwen2.5 ARC RAG project demonstrates:

```text
ingest documents
  → chunk and embed
  → upsert into Qdrant
  → evaluate retrieval quality
  → generate grounded answers
  → judge faithfulness and correctness
  → measure citation coverage
  → measure unsupported claims
  → score safety
  → deployment gate
```

This is important because retrieval alone is not enough. The RAG pipeline shows that a system can retrieve the right context and still fail if the source material is too thin, the prompt is weak, or the answer makes unsupported claims.

The final passing RAG run demonstrates a RAGAS-style evaluation pattern using platform-native KFP components, MLflow logging, LLM judging, and deployment gates.

## Model serving

The platform includes multiple serving project types.

Current serving paths include:

* **`serving-vllm`** — vLLM LoRA adapter serving on DGX, AGX, or GKE.
* **`serving-nim`** — NVIDIA NIM serving using stock NGC images.
* **`serving-trt-fp8`** — FP8-quantized checkpoint serving through vLLM.
* **`serving-trt-engine`** — TensorRT-LLM engine serving through `tensorrt_llm.serve`.

The important architectural idea is that serving is gated by the training/evaluation pipeline.

A model artifact does not simply get deployed because it exists. It is published with a manifest containing evaluation and safety state. Serving workflows can refuse to serve artifacts that did not pass the required gates.

```text
ft-eval PASS
  → publish adapter + manifest
  → serving project reads manifest
  → deploy only if eval_passed and safety_passed
```

That is production-minded AI platform behavior.

## GPU profiling and performance engineering

The platform integrates Nsight Operator as a first-class profiling layer.

That matters because GPU workloads often fail or underperform for reasons that are invisible from application logs alone. Nsight traces can reveal:

* model load behavior
* cold weight migration
* CUDA API overhead
* GPU kernel activity
* memory transfer patterns
* NVTX stage timing
* launch overhead
* serving bottlenecks

The platform also includes agent-assisted profiling interpretation. Instead of manually reading large `.nsys-rep` files every time, the workflow can extract `nsys stats`, send summaries to an LLM, and produce structured bottleneck analysis.

This makes performance work part of the platform, not an afterthought.

## Agent-assisted operations

The platform uses Claude/Codex workflows as operational helpers.

These are not just code-generation prompts. They support real platform operations:

* deploy KFP runs
* monitor KFP pods
* inspect logs and MLflow metrics
* maintain run status files
* summarize failures
* inspect model cards
* interpret Nsight reports
* send terminal run notifications
* preserve public validation summaries while keeping noisy raw logs private

This is a practical example of **agentic DevOps**: using AI tools to operate complex long-running GPU and Kubernetes workflows more reliably.

## Security and PHI boundary

The platform has a clear security model.

Fine-tuning, evaluation, and any future PHI-sensitive workloads stay on DGX-class local hardware. Only approved non-PHI artifacts move to GCP.

The cloud boundary is explicit:

```text
DGX local domain:
  data
  training
  evaluation
  safety checks
  run logs
  raw artifacts

GCP domain:
  approved adapter weights
  manifest metadata
  serving images
  inference endpoints
```

Workload Identity Federation avoids static long-lived GCP service account keys in GitHub Actions. That gives the platform a stronger cloud security posture than workflows that depend on checked-in keys or long-lived JSON secrets.

## What skills does this prove?

This repo proves Aaron can operate as a **hands-on AI platform architect**.

### AI platform engineering

Designing reusable platform patterns rather than one-off notebooks or scripts.

The project factory is a concrete example: a workflow can scaffold a new applied AI repo, wire it into the local platform, set up JupyterLab integration, provide deployment workflows, generate documentation, and register it with the dashboard.

### Applied MLOps

Building eval-first workflows with baseline metrics, post-run metrics, safety checks, deployment gates, MLflow tracking, and artifact publication.

This includes both model fine-tuning and RAG evaluation.

### LLM application engineering

Building RAG pipelines that measure retrieval quality, answer correctness, faithfulness, citation coverage, unsupported-claim rate, and safety.

This proves the platform can support knowledge-grounded LLM applications, not just model training.

### Model serving

Creating reusable serving project types for vLLM, NIM, FP8 vLLM, and TensorRT-LLM engine serving across local and cloud GPU targets.

This proves practical understanding of model deployment tradeoffs: LoRA adapters, quantized checkpoints, precompiled engines, cloud GPU pools, stable model aliases, and OpenAI-compatible APIs.

### GPU systems and profiling

Using DGX-class local hardware, CUDA-enabled containers, arm64-native images, Nsight Operator, and profiling analysis to understand runtime behavior and performance bottlenecks.

### Cloud infrastructure

Provisioning and operating Google Cloud resources with Terraform, GKE, Artifact Registry, GCS, and Workload Identity Federation.

### Kubernetes operations

Working across local k3s clusters and managed GKE. The platform handles local GPU services, cloud GPU serving, Kubernetes namespaces, pod injection, port-forwarded services, and workflow-driven deployment.

### DevOps and CI/CD

Building and operating GitHub Actions workflows, self-hosted runners, custom runner containers, deployment workflows, dashboard deployment, and repo-quality automation.

### Container engineering

Creating custom Docker images with CUDA, CI tooling, cloud CLIs, Kubernetes tooling, Terraform, GitHub CLI, ML frameworks, and repo-quality utilities.

### Multi-architecture systems

Supporting both x86_64 and ARM64 execution targets across runner images, physical systems, and Kubernetes workloads, including custom-built arm64 images where upstream support is incomplete.

### Observability

Combining MLflow, W&B, LangSmith, Nsight Operator, Slack notifications, dashboard state, and run-status files into a practical observability model for LLM workloads.

### Security-aware deployment

Using Workload Identity Federation instead of static cloud keys, keeping raw run logs and local paths out of public git, and enforcing a PHI boundary between local training/evaluation and cloud serving.

### Agentic DevOps

Using Claude/Codex not as a gimmick, but as an operations layer for long-running KFP/GPU workflows: monitoring, triage, run logging, profiling interpretation, and validation summaries.

## Why should a hiring manager care?

This repo shows that Aaron can bridge architecture and implementation.

He is not only describing an AI platform. He is building:

* Docker images
* GitHub Actions workflows
* Terraform infrastructure
* GKE lifecycle automation
* k3s local GPU services
* Kubeflow Pipelines project templates
* fine-tuning/eval pipelines
* RAG evaluation pipelines
* serving templates
* adapter publishing workflows
* dashboard state
* runbooks
* profiling workflows
* agent-assisted operating procedures

That matters because modern AI systems require more than model knowledge. They require the ability to connect:

* GPU hosts
* Kubernetes
* CI/CD
* cloud infrastructure
* model artifacts
* container registries
* experiment tracking
* evaluation and safety gates
* vector search
* RAG evaluation
* model serving
* inference optimization
* profiling
* security boundaries
* developer experience
* operational visibility
* repeatable automation

This repo is evidence that Aaron can design and implement that connective tissue.

## One-line summary

Aaron built a **hybrid DGX + GCP AI platform for the full applied LLM lifecycle — fine-tuning, evaluation, safety gating, adapter publishing, vLLM/NIM/FP8/TRT-LLM serving, RAG evaluation, Nsight profiling, MLflow/W&B/LangSmith observability, dashboard state, and agent-assisted operations — using custom GPU-capable self-hosted GitHub Actions runners across DGX Spark, Jetson AGX Orin, WSL2, and GCP/GKE.**
