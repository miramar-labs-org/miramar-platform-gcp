# So What?

## Question

**What did Aaron build, why is it impressive, and what skills does this prove?**

## Answer

Aaron built a **hybrid DGX + GCP AI workload platform** for generating, validating, serving, profiling, and operating reproducible AI projects across local GPU systems and Google Cloud.

This is not a sample app, a notebook demo, or a loose collection of scripts. It is a working platform pattern for the applied AI lifecycle:

```text
data curation
  → supervised fine-tuning / evaluation
  → RAG evaluation
  → sequence classification
  → safety and quality gates
  → artifact publishing
  → model serving / routing / gateway
  → profiling, observability, and agent-assisted operations
```

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
Project factory templates for LLMs, RAG, data curation, serving, and sequence models
  ↓
GitHub Pages dashboard · run histories · agent-assisted run operations
```

The core idea is simple: create a reusable factory for real AI workloads, then prove it through concrete projects that run end to end, record metrics, publish artifacts only after gates pass, and expose enough documentation that the work is reviewable.

## Validated workloads

The platform has been validated through multiple workload families:

* **Qwen2.5 ARC fine-tuning/eval** — a gate-passed LoRA fine-tuning pipeline with baseline evaluation, fine-tuning, post-fine-tune evaluation, safety evaluation, and deployment gate.
* **Qwen2.5 MedMCQA fine-tuning/eval** — a medical exam QA pipeline that improved measured accuracy while preserving safety score.
* **BioMistral oncology fine-tuning** — a domain-specific oncology QA LoRA run with adapter artifacts published to GCS.
* **MedGemma 27B MedMCQA fine-tuning/eval** — a large-model medical QA run that passed safety/evaluation gates while also exposing the practical constraint that a short training budget produced no accuracy gain.
* **Qwen2.5 ARC RAG** — a gate-passed RAG pipeline with retrieval, generation, faithfulness, citation coverage, unsupported-claim, and safety metrics.
* **NeMo Curator verification** — a KFP data-curation pipeline that extracts text, applies GPU quality filtering, deduplicates documents, redacts PII, writes curated output, and logs MLflow metrics/artifacts.
* **DNABERT2 ClinVar sequence classification** — a non-generative biological sequence-classification pipeline using `AutoModelForSequenceClassification` to predict variant pathogenicity from raw DNA sequence inputs.
* **Reusable serving templates** — project types for vLLM LoRA serving, NIM serving, multi-LLM NIM serving, FP8 vLLM serving, TensorRT-LLM engine serving, Triton + vLLM, and Triton + TensorRT-LLM across DGX, AGX, and GKE targets.

That range matters. It shows the platform is not merely an LLM demo. It can support multiple applied AI patterns: generative LLM fine-tuning, RAG evaluation, data curation, model serving, inference optimization, and encoder-based biological sequence classification.

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
* Kubeflow Pipelines for fine-tuning, evaluation, RAG, data curation, and sequence-classification workloads.
* MLflow for experiment tracking, metrics, and artifact history.
* Qdrant for vector search and RAG.
* NeMo/NIM and Ollama for local model serving.
* Nsight Operator for CUDA/NVTX profiling through Kubernetes pod injection.
* vLLM, NIM, TensorRT-LLM, and Triton serving project templates.
* GKE Gateway / stable API routing patterns for external inference endpoints.
* GitHub Pages platform dashboard with service state, project inventory, and operational links.
* A project factory that scaffolds new applied AI repos with JupyterLab integration, GitHub Actions workflows, platform endpoints, documentation, and dashboard registration.
* Agent-assisted operations through Claude/Codex workflows for deployment, run monitoring, model-card lookup, status logging, failure triage, and Nsight report interpretation.
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
NeMo / NIM
Ollama
vLLM
TensorRT-LLM
Triton
Nsight Operator
RAPIDS / cuDF
HuggingFace Trainer
LLM-as-judge evaluation
agent-assisted operations
dashboard state
security boundaries
CI hygiene
```

into something repeatable, observable, and reviewable.

The platform demonstrates a broader applied AI lifecycle:

```text
Project creation
  → notebook-first implementation
  → KFP deployment
  → data preparation or model/task setup
  → baseline evaluation
  → fine-tuning, RAG execution, curation, or sequence classification
  → post-run evaluation
  → safety and quality gates
  → artifact publication
  → serving or downstream reuse
  → monitoring and profiling
  → dashboard visibility
```

That is the connective tissue real AI teams need.

## Data curation

The `kfp-nemo-curator` project type adds a data-preparation layer to the platform.

A typical curation pipeline performs:

```text
preflight_check
  → extract_text
  → quality_filter
  → deduplication
  → pii_redaction
  → curator_report
```

This matters because model quality depends on data quality. The pipeline demonstrates a repeatable pattern for turning raw documents into a cleaned, filtered, deduplicated, PII-redacted dataset with stage-level metrics.

It also proves GPU data-processing integration. Quality filtering and deduplication can use RAPIDS/cuDF-backed components, while PII redaction and reporting can run on CPU components. That CPU/GPU split is the kind of practical orchestration detail that shows platform maturity.

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

The platform has validated this pattern across multiple workloads, including Qwen2.5 ARC, Qwen2.5 MedMCQA, BioMistral oncology QA, and MedGemma 27B medical QA.

The MedGemma run is useful even where the improvement was limited. It shows the platform records both successful gates and practical training constraints, rather than hiding weak or inconclusive outcomes. That kind of honest run history is valuable in real MLOps.

## RAG evaluation

The platform supports a RAG-style evaluation pattern.

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
  → deployment_gate
```

This is important because retrieval alone is not enough. The RAG pipeline shows that a system can retrieve the right context and still fail if the source material is too thin, the prompt is weak, or the answer makes unsupported claims.

The final passing RAG run demonstrates a RAGAS-style evaluation pattern using platform-native KFP components, MLflow logging, LLM judging, and deployment gates.

## Sequence classification and non-generative ML

The DNABERT2 ClinVar project expands the platform beyond text-generation LLM workflows.

That project uses a sequence encoder rather than a chat model:

```text
DNA sequence
  → DNABERT2 encoder
  → [CLS] embedding
  → classification head
  → pathogenic / benign probability
```

This is a different ML pattern from LoRA fine-tuning a generative LLM. It uses `AutoModelForSequenceClassification`, HuggingFace `Trainer`, labeled biological sequence examples, and classification metrics such as accuracy and AUC.

That matters because it proves the platform factory is not locked to one model family or one task shape. It can support non-generative AI workloads where the output is a class probability rather than generated text.

## Model serving

The platform includes multiple serving project types.

Current serving paths include:

* **`serving-vllm`** — vLLM LoRA adapter serving on DGX, AGX, or GKE.
* **`serving-nim`** — NVIDIA NIM serving using stock NGC images.
* **`serving-llm-nim`** — multi-LLM NIM runtime with local or HuggingFace model source detection.
* **`serving-trt-fp8`** — FP8-quantized checkpoint serving through vLLM.
* **`serving-trt-engine`** — TensorRT-LLM engine serving through `trtllm-serve` / `tensorrt_llm.serve`.
* **`serving-triton-vllm`** — Triton Inference Server with the vLLM backend.
* **`serving-triton-trtllm`** — Triton Inference Server with the TensorRT-LLM backend.

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

Fine-tuning, evaluation, data curation, and any future PHI-sensitive workloads stay on DGX-class local hardware. Only approved non-PHI artifacts move to GCP.

The cloud boundary is explicit:

```text
DGX local domain:
  raw data
  data curation
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

This includes model fine-tuning, RAG evaluation, data curation, and sequence classification.

### LLM application engineering

Building RAG pipelines that measure retrieval quality, answer correctness, faithfulness, citation coverage, unsupported-claim rate, and safety.

This proves the platform can support knowledge-grounded LLM applications, not just model training.

### Bio/sequence model engineering

Building classification pipelines for biological sequence encoders such as DNABERT2.

This proves the platform can support non-generative AI models that operate on raw sequence inputs and produce class probabilities rather than natural-language completions.

### Model serving

Creating reusable serving project types for vLLM, NIM, FP8 vLLM, TensorRT-LLM engine serving, and Triton-backed serving across local and cloud GPU targets.

This proves practical understanding of model deployment tradeoffs: LoRA adapters, quantized checkpoints, precompiled engines, cloud GPU pools, stable model aliases, OpenAI-compatible APIs, and gateway/routing patterns.

### GPU systems and profiling

Using DGX-class local hardware, CUDA-enabled containers, arm64-native images, Nsight Operator, RAPIDS/cuDF, and profiling analysis to understand runtime behavior and performance bottlenecks.

### Cloud infrastructure

Provisioning and operating Google Cloud resources with Terraform, GKE, Artifact Registry, GCS, Gateway API, and Workload Identity Federation.

### Kubernetes operations

Working across local k3s clusters and managed GKE. The platform handles local GPU services, cloud GPU serving, Kubernetes namespaces, pod injection, port-forwarded services, and workflow-driven deployment.

### DevOps and CI/CD

Building and operating GitHub Actions workflows, self-hosted runners, custom runner containers, deployment workflows, dashboard deployment, and repo-quality automation.

### Container engineering

Creating custom Docker images with CUDA, CI tooling, cloud CLIs, Kubernetes tooling, Terraform, GitHub CLI, ML frameworks, RAPIDS/cuDF, and repo-quality utilities.

### Multi-architecture systems

Supporting both x86_64 and ARM64 execution targets across runner images, physical systems, and Kubernetes workloads, including custom-built arm64 images where upstream support is incomplete.

### Observability

Combining MLflow, W&B, LangSmith, Nsight Operator, Slack notifications, dashboard state, and run-status files into a practical observability model for AI workloads.

### Security-aware deployment

Using Workload Identity Federation instead of static cloud keys, keeping raw run logs and local paths out of public git, and enforcing a boundary between local training/evaluation/data handling and cloud serving.

### Agentic DevOps

Using Claude/Codex not as a gimmick, but as an operations layer for long-running KFP/GPU workflows: monitoring, triage, run logging, profiling interpretation, validation summaries, and terminal notifications.

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
* data-curation pipelines
* biological sequence-classification pipelines
* serving templates
* adapter publishing workflows
* model-router and gateway patterns
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
* curated datasets
* vector search
* RAG evaluation
* sequence-model training
* model serving
* inference optimization
* profiling
* security boundaries
* developer experience
* operational visibility
* repeatable automation

This repo is evidence that Aaron can design and implement that connective tissue.

## One-line summary

Aaron built a **hybrid DGX + GCP AI workload platform and project factory for the applied AI lifecycle — data curation, LLM fine-tuning/evaluation, RAG evaluation, biological sequence classification, safety gating, artifact publishing, vLLM/NIM/FP8/TRT-LLM/Triton serving, GPU profiling, MLflow/W&B/LangSmith observability, dashboard state, and agent-assisted operations — using custom GPU-capable self-hosted GitHub Actions runners across DGX Spark, Jetson AGX Orin, WSL2, and GCP/GKE.**
