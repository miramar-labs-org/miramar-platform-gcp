# So What?

## Question

**What did Aaron build, why is it impressive, and what skills does this prove?**

## Answer

Aaron built a **hybrid AI infrastructure platform** that connects local GPU hardware, self-hosted GitHub Actions runners, and Google Cloud into one operational system.

At a high level, the platform looks like this:

```text
GitHub Actions (control plane)
   ↓
Custom multi-arch self-hosted runner image (linux/amd64 + linux/arm64)
   ↓
WSL2 / DGX Spark (GB10 Blackwell, 128 GB unified VRAM) / Jetson AGX Orin (64 GB unified VRAM)
   ↓
Local Kubernetes (minikube) + GCP/GKE
   ↓
MLflow · Qdrant · Kubeflow Pipelines · NeMo/NIM · Ollama
   ↓
GitHub Pages dashboard · project scaffolding · blog integration
```

This is not just a sample app or a collection of scripts. It is a working platform pattern for building, validating, deploying, and operating AI infrastructure and local AI services across both **on-prem GPU hardware** and **cloud infrastructure**.

## What the platform includes

The repo demonstrates:

- A custom CUDA-based GitHub Actions runner image.
- Multi-architecture support for `amd64` and `arm64`.
- Self-hosted runners for WSL2, DGX Spark, and Jetson AGX Orin targets.
- Terraform-managed GCP infrastructure.
- GKE platform lifecycle and scaling automation.
- GHCR-based container publishing.
- Workload Identity Federation for keyless GCP authentication.
- Local Kubernetes (minikube) workflows for GPU-adjacent AI services.
- **MLflow** for experiment tracking, **Qdrant** for vector search and RAG, **Kubeflow Pipelines** for pipeline orchestration (with custom arm64 images for all 13 KFP components), **NeMo/NIM** and **Ollama** for model serving.
- A live **GitHub Pages platform dashboard** showing per-service active/inactive state, a project table with JupyterLab links, and one-click project creation and deletion.
- A **project creation system** that scaffolds new ML repos with JupyterLab kernels, Python venvs, platform endpoint references, and a draft blog post PR — in a single workflow dispatch.
- Repo-quality automation using Terraform, shell, YAML, Dockerfile, GitHub Actions, and Prettier checks.

## Why is this impressive?

It is impressive because it shows a real **AI platform engineering system** with multiple moving parts that must work together reliably.

The difficult part is not any single tool. The difficult part is integrating:

```text
GitHub Actions + Docker + CUDA + GCP + Terraform + Kubernetes + GHCR + GPU hosts + local networking + CI hygiene
```

into something repeatable and reviewable.

The repo shows that Aaron is not only experimenting with AI tools. He is building the infrastructure layer needed to run, deploy, validate, and operate AI workloads across heterogeneous compute environments.

The platform covers the **full ML lifecycle**:

- **Experiment tracking** → MLflow (deployed in-cluster, accessible from JupyterLab and runner containers)
- **Pipeline orchestration** → Kubeflow Pipelines (KFP v2, arm64-native images built on DGX Spark)
- **Vector search / RAG** → Qdrant (deployed in-cluster, REST + gRPC, web UI, persisted via PVC)
- **Model serving** → NIM on DGX Spark (Blackwell-optimized), Ollama on DGX and AGX Orin

That lifecycle runs on genuinely unusual hardware: the DGX Spark carries a GB10 Blackwell superchip with 128 GB of unified CPU/GPU memory; the AGX Orin provides 64 GB unified memory on Ampere. Both run the same arm64 platform stack.

It also shows good platform judgment:

- Local GPU hardware is used where GPU locality, experimentation, and cost control matter.
- GCP/GKE is used for cloud deployment patterns.
- GitHub Actions provides the automation control plane.
- Custom self-hosted runners provide the execution layer.
- Workload Identity Federation avoids static long-lived GCP service account keys.
- Repo-quality workflows move the project from personal automation toward a reviewable engineering artifact.

## What skills does this prove?

This repo proves Aaron can operate as a **hands-on AI platform architect**.

It demonstrates practical strength in:

### Platform engineering

Designing reusable automation and infrastructure patterns rather than one-off scripts. The project creation system — a single workflow that scaffolds a new ML repo, provisions a JupyterLab kernel and venv, wires in platform endpoints, and opens a draft blog post PR — is a concrete example of platform UX thinking applied to developer experience.

### DevOps and CI/CD

Building and operating GitHub Actions workflows, custom runners, repo-quality checks, and deployment automation.

### Container engineering

Creating custom Docker images with CUDA, CI tooling, cloud CLIs, Kubernetes tooling, Terraform, GitHub CLI, ML frameworks, and repo-quality utilities. Building native arm64 images for all 13 Kubeflow Pipelines components to run on DGX Spark and AGX Orin.

### Cloud infrastructure

Provisioning and deploying Google Cloud resources using Terraform and GitHub Actions.

### Kubernetes operations

Working across both managed cloud Kubernetes on GKE and local Kubernetes/minikube environments on DGX-class hardware.

### AI infrastructure

Deploying and integrating the full ML lifecycle stack: experiment tracking (MLflow), pipeline orchestration (KFP), vector search (Qdrant), and model serving (NIM, Ollama) — wired together so each service is reachable from JupyterLab notebooks and CI runner containers alike.

### Security-aware deployment

Using Workload Identity Federation instead of relying on static long-lived cloud keys.

### Multi-architecture systems

Supporting both x86_64 and ARM64 execution targets across runner images, physical systems, and Kubernetes workloads — including custom-built arm64 images where upstream does not provide them.

### Engineering hygiene

Adding checks for Terraform formatting and validation, shell formatting and linting, YAML linting, GitHub Actions linting, Dockerfile linting, and Markdown/YAML/JSON formatting.

## Why should a hiring manager care?

This repo shows that Aaron can bridge architecture and implementation.

He is not only describing a platform. He is building the Docker images, workflows, Terraform, scripts, and operational structure himself.

That matters for AI infrastructure roles because modern AI systems require more than model knowledge. They require the ability to connect:

- GPU hosts
- Kubernetes
- CI/CD
- cloud infrastructure
- container registries
- security boundaries
- experiment tracking, pipeline orchestration, vector search, and model serving
- developer experience
- repeatable automation

This repo is evidence that Aaron can design and implement that connective tissue.

## One-line summary

Aaron built a **hybrid on-prem/cloud AI infrastructure platform that uses custom self-hosted GPU-capable GitHub Actions runners to provision, validate, and operate a full ML lifecycle stack — MLflow, Qdrant, Kubeflow Pipelines, NeMo/NIM, and Ollama — across a DGX Spark (128 GB Blackwell), Jetson AGX Orin (64 GB), WSL2, and GCP/GKE**, proving hands-on strength in AI platform engineering, DevOps, Kubernetes, Terraform, Docker, GCP, and production-minded automation.
