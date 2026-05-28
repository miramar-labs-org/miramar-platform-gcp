# So What?

## Question

**What did Aaron build, why is it impressive, and what skills does this prove?**

## Answer

Aaron built a **hybrid AI infrastructure platform** that connects local GPU hardware, self-hosted GitHub Actions runners, and Google Cloud into one operational system.

At a high level, the platform looks like this:

```text
GitHub Actions
   ↓
Custom multi-arch self-hosted runner image
   ↓
WSL2 / DGX / Jetson runner fleet
   ↓
Local DGX Kubernetes + GCP/GKE infrastructure
   ↓
MLflow, NeMo/NIM, Ollama, container builds, deployments, and repo-quality automation
```

This is not just a sample app or a collection of scripts. It is a working platform pattern for building, validating, deploying, and operating AI infrastructure and local AI services across both **on-prem GPU hardware** and **cloud infrastructure**.

## What the platform includes

The repo demonstrates:

- A custom CUDA-based GitHub Actions runner image.
- Multi-architecture support for `amd64` and `arm64`.
- Self-hosted runners for WSL2, DGX, and Jetson AGX Orin targets.
- Terraform-managed GCP infrastructure.
- GKE platform lifecycle and scaling automation.
- GHCR-based container publishing.
- Workload Identity Federation for keyless GCP authentication.
- Local DGX/minikube workflows for GPU-adjacent AI services.
- MLflow, NeMo/NIM, Ollama, PyTorch, Hugging Face, and related AI tooling.
- Manual repo-quality automation using Terraform, shell, YAML, Dockerfile, GitHub Actions, and Prettier checks.

## Why is this impressive?

It is impressive because it shows a real **AI platform engineering system** with multiple moving parts that must work together reliably.

The difficult part is not any single tool. The difficult part is integrating:

```text
GitHub Actions + Docker + CUDA + GCP + Terraform + Kubernetes + GHCR + GPU hosts + local networking + CI hygiene
```

into something repeatable and reviewable.

The repo shows that Aaron is not only experimenting with AI tools. He is building the infrastructure layer needed to run, deploy, validate, and operate AI workloads across heterogeneous compute environments.

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

Designing reusable automation and infrastructure patterns rather than one-off scripts.

### DevOps and CI/CD

Building and operating GitHub Actions workflows, custom runners, repo-quality checks, and deployment automation.

### Container engineering

Creating custom Docker images with CUDA, CI tooling, cloud CLIs, Kubernetes tooling, Terraform, GitHub CLI, ML frameworks, and repo-quality utilities.

### Cloud infrastructure

Provisioning and deploying Google Cloud resources using Terraform and GitHub Actions.

### Kubernetes operations

Working across both managed cloud Kubernetes on GKE and local Kubernetes/minikube-style environments on DGX-class hardware.

### AI infrastructure

Preparing infrastructure for PyTorch, Hugging Face, MLflow, NeMo/NIM, Ollama, GPU-aware services, and model-development workflows.

### Security-aware deployment

Using Workload Identity Federation instead of relying on static long-lived cloud keys.

### Multi-architecture systems

Supporting both x86_64 and ARM64 execution targets across runner images and physical systems.

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
- experiment tracking, validation workflows, and operational checks
- developer experience
- repeatable automation

This repo is evidence that Aaron can design and implement that connective tissue.

## One-line summary

Aaron built a **hybrid on-prem/cloud AI infrastructure platform that uses custom self-hosted GPU-capable GitHub Actions runners to provision, validate, and operate local AI services and GCP/GKE infrastructure across DGX, Jetson Orin, WSL2, and Google Cloud**, proving hands-on strength in AI platform engineering, DevOps, Kubernetes, Terraform, Docker, GCP, and production-minded automation.
