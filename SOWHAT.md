# So What?

## Question

**What did Aaron build, why is it impressive, and what skills does this prove?**

## Answer

Aaron built a **hybrid on-prem/cloud AI platform and agent-assisted MLOps workflow** for developing, validating, deploying, profiling, and operating applied AI workloads across local GPU systems and Google Cloud.

The platform connects:

```text
GitHub Actions control plane
  ↓
Custom multi-arch self-hosted runner image
  ↓
WSL2 / DGX Spark / Jetson AGX Orin
  ↓
Local Kubernetes + GCP/GKE
  ↓
MLflow · Qdrant · Kubeflow Pipelines · NeMo/NIM · Ollama
  ↓
Project factory · GitHub Pages dashboard · blog/documentation workflow
  ↓
Agent-assisted run monitoring, debugging, and profiling interpretation
```

This is not just a sample app, notebook, or collection of scripts. It is a working AI platform pattern for building and operating real AI workloads across heterogeneous GPU hardware and cloud infrastructure.

The first concrete workload generated from this platform is a **MedGemma 27B Kubeflow Pipelines fine-tuning and evaluation project**. That project runs an eval-first medical LLM workflow: prepare datasets, evaluate the base model, run baseline safety checks, fine-tune with LoRA, re-evaluate, run safety evaluation, log metrics to MLflow, optionally capture NVIDIA Nsight profiles, and gate deployment based on measured results.

## What the platform includes

The repo demonstrates:

- A custom CUDA-based GitHub Actions runner image.
- Multi-architecture support for `amd64` and `arm64`.
- Self-hosted runners for WSL2, DGX Spark, and Jetson AGX Orin targets.
- Terraform-managed GCP infrastructure.
- GKE platform lifecycle and scaling automation.
- GHCR-based container publishing.
- Workload Identity Federation for keyless GCP authentication.
- Local Kubernetes/minikube workflows for GPU-adjacent AI services.
- MLflow for experiment tracking.
- Qdrant for vector search and RAG.
- Kubeflow Pipelines for pipeline orchestration, including custom arm64 component images.
- NeMo/NIM and Ollama for local model serving.
- A GitHub Pages platform dashboard that tracks generated projects and operational state.
- A project factory that scaffolds new ML repos with JupyterLab kernels, Python environments, platform endpoints, deployment workflows, and documentation/blog scaffolding.
- Repo-quality automation for Terraform, shell, YAML, Dockerfiles, GitHub Actions, and formatting checks.
- Claude/Codex operational skills for KFP deployment, run monitoring, model-card lookup, and NVIDIA Nsight profiling interpretation.

## Why is this impressive?

It is impressive because it shows a real **AI platform engineering system**, not a toy project.

The hard part is not any single tool. The hard part is integrating:

```text
GitHub Actions
Docker
CUDA
GCP
Terraform
Kubernetes
GHCR
GPU hosts
local networking
Kubeflow Pipelines
MLflow
model serving
profiling
agent-assisted operations
CI hygiene
```

into something repeatable, observable, and reviewable.

The platform shows that Aaron is not only experimenting with AI tools. He is building the infrastructure layer needed to run, validate, profile, and operate AI workloads across heterogeneous compute environments.

The MedGemma pipeline makes the platform concrete. It shows how the infrastructure supports an actual applied AI workflow: medical QA dataset preparation, baseline evaluation, LoRA fine-tuning, post-fine-tune evaluation, LLM-as-judge safety checks, MLflow tracking, deployment gates, and NVIDIA profiling.

The agentic operations layer is especially important. Long-running GPU/KFP jobs produce noisy pod logs, MLflow metrics, partial failures, retry states, and profiling artifacts. The Claude/Codex skills turn that operational mess into a structured loop: deploy a run, monitor pods and metrics, write status logs, detect failures, summarize issues, and interpret Nsight reports for bottlenecks and optimization next steps.

That moves the work beyond “I built a pipeline” into “I built the platform, the workload, and the AI-assisted operating model around it.”

## What skills does this prove?

This repo proves Aaron can operate as a **hands-on AI platform architect**.

### AI platform engineering

Designing reusable infrastructure and automation patterns rather than one-off scripts.

The project factory is a concrete example: a workflow can scaffold a new ML project, wire it into the local platform, set up JupyterLab integration, provide deployment hooks, and generate supporting documentation.

### Applied MLOps

Building an eval-first fine-tuning workflow with dataset preparation, baseline metrics, fine-tuned metrics, safety checks, MLflow tracking, and deployment gates.

### Agentic DevOps

Creating Claude/Codex workflows that assist with real operations: KFP deployment, run monitoring, log/status tracking, model-card lookup, and NVIDIA profiling interpretation.

This shows practical understanding of how agentic tools can improve engineering operations, not just generate code.

### GPU and profiling awareness

Using DGX-class local hardware, CUDA-enabled containers, arm64-native builds, and Nsight profiling to understand runtime behavior, bottlenecks, memory movement, idle time, and optimization opportunities.

### DevOps and CI/CD

Building and operating GitHub Actions workflows, self-hosted runners, custom runner containers, repo-quality checks, deployment workflows, and lifecycle automation.

### Container engineering

Creating custom Docker images with CUDA, CI tooling, cloud CLIs, Kubernetes tooling, Terraform, GitHub CLI, ML frameworks, and repo-quality utilities.

### Cloud infrastructure

Provisioning and deploying Google Cloud resources using Terraform and GitHub Actions.

### Kubernetes operations

Working across managed cloud Kubernetes on GKE and local Kubernetes/minikube environments on GPU hardware.

### AI infrastructure

Deploying and integrating the ML lifecycle stack: experiment tracking, pipeline orchestration, vector search, model serving, profiling, and local/cloud workload boundaries.

### Security-aware deployment

Using Workload Identity Federation instead of static long-lived GCP service account keys, while keeping sensitive run logs, local paths, and raw profiling/debug artifacts out of public git.

### Multi-architecture systems

Supporting both x86_64 and ARM64 execution targets across runner images, physical systems, and Kubernetes workloads, including custom-built arm64 images where upstream support is incomplete.

### Engineering hygiene

Adding checks for Terraform formatting and validation, shell formatting and linting, YAML linting, GitHub Actions linting, Dockerfile linting, and Markdown/YAML/JSON formatting.

## Why should a hiring manager care?

This repo shows that Aaron can bridge architecture and implementation.

He is not only describing an AI platform. He is building the Docker images, workflows, Terraform, scripts, local services, cloud infrastructure, project templates, runbooks, and agent-assisted operating procedures himself.

That matters because modern AI systems require more than model knowledge. They require the ability to connect:

- GPU hosts
- Kubernetes
- CI/CD
- cloud infrastructure
- container registries
- security boundaries
- experiment tracking
- pipeline orchestration
- model serving
- evaluation and safety gates
- profiling and performance tuning
- developer experience
- agent-assisted operational workflows
- repeatable automation

This repo is evidence that Aaron can design and implement that connective tissue.

## One-line summary

Aaron built a **hybrid on-prem/cloud AI platform and agent-assisted MLOps workflow that uses custom GPU-capable self-hosted GitHub Actions runners to provision, validate, profile, and operate applied AI workloads across DGX Spark, Jetson AGX Orin, WSL2, and GCP/GKE — including a MedGemma 27B Kubeflow fine-tuning/evaluation pipeline with MLflow tracking, safety gates, Nsight profiling, and Claude/Codex run-operations skills.**
