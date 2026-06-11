# System Flows and Diagrams

This document contains Mermaid diagrams for the Miramar Labs hybrid AI platform. GitHub renders Mermaid diagrams directly in Markdown.

## Hybrid platform overview

```mermaid
flowchart LR
    subgraph GitHub["GitHub"]
        Repo["miramar-platform-gcp repo"]
        Actions["GitHub Actions"]
        GHCR["GitHub Container Registry"]
    end

    subgraph Local["Local / On-Prem Systems"]
        WSL2["WSL2 laptop runner\namd64"]
        DGX["DGX Spark runner\narm64 + GPU"]
        AGX["Jetson AGX Orin runner\narm64 + GPU"]
        MK["DGX k3s"]
        LocalAI["NeMo / NIM / MLflow / Ollama"]
    end

    subgraph GCP["Google Cloud"]
        WIF["Workload Identity Federation"]
        GKE["GKE Standard"]
        GAR["Artifact Registry"]
        GCS["GCS state + snapshots"]
        IAM["IAM service accounts"]
    end

    Repo --> Actions
    Actions --> WSL2
    Actions --> DGX
    Actions --> AGX
    Repo --> GHCR
    GHCR --> WSL2
    GHCR --> DGX
    GHCR --> AGX

    Actions --> WIF
    WIF --> IAM
    IAM --> GKE
    IAM --> GAR
    IAM --> GCS

    DGX --> MK
    MK --> LocalAI
    GAR --> GKE
```

## GitHub Actions to GCP identity flow

```mermaid
sequenceDiagram
    participant Operator
    participant GitHub as GitHub Actions
    participant OIDC as GitHub OIDC Token
    participant WIF as GCP Workload Identity Federation
    participant SA as GCP Service Account
    participant GCP as GCP APIs

    Operator->>GitHub: Start workflow_dispatch
    GitHub->>OIDC: Request short-lived OIDC token
    GitHub->>WIF: Exchange OIDC token
    WIF->>SA: Impersonate allowed service account
    SA->>GCP: Call Terraform / GKE / Artifact Registry APIs
    GCP-->>GitHub: Return operation result
```

## Runner image build and consumption

```mermaid
flowchart TD
    Dockerfile["docker/runner/Dockerfile"] --> Buildx["GitHub Actions Buildx"]
    Buildx --> AMD64["linux/amd64 image"]
    Buildx --> ARM64["linux/arm64 image"]
    AMD64 --> Manifest["Multi-arch image manifest"]
    ARM64 --> Manifest
    Manifest --> GHCR["GHCR mlabs-runner image"]

    GHCR --> WSL2["WSL2 runner host pulls amd64"]
    GHCR --> DGX["DGX Spark pulls arm64"]
    GHCR --> AGX["Jetson AGX Orin pulls arm64"]

    WSL2 --> Jobs1["General orchestration jobs"]
    DGX --> Jobs2["DGX / k3s / GPU jobs"]
    AGX --> Jobs3["Edge / arm64 validation jobs"]
```

## Local AI service lifecycle

```mermaid
flowchart TD
    Start["Operator starts workflow"] --> Runner["DGX self-hosted runner"]
    Runner --> Check["Check host prerequisites"]
    Check --> K3s["Start / verify k3s"]
    K3s --> Storage["Prepare local storage and namespaces"]
    Storage --> Nemo["Deploy NeMo Microservices"]
    Nemo --> MLflow["Deploy MLflow + MinIO"]
    MLflow --> NIM["Deploy NIM workloads"]
    NIM --> Tunnel["Open SSH tunnel or local access path"]
    Tunnel --> Validate["Validate UI/API endpoints"]
```

## GCP platform lifecycle

```mermaid
flowchart TD
    Dispatch["workflow_dispatch"] --> Auth["Authenticate to GCP via WIF"]
    Auth --> Init["terraform init"]
    Init --> Plan["terraform plan"]
    Plan --> Apply["terraform apply"]
    Apply --> GKE["Create / update GKE"]
    Apply --> GAR["Create / update Artifact Registry"]
    Apply --> GCS["Create / update state buckets"]
    GKE --> Deploy["Deploy workloads"]
    GAR --> Deploy
```

## Recommended future production topology

```mermaid
flowchart LR
    subgraph GitHub["GitHub"]
        PR["Pull Request"]
        Checks["Required checks"]
        Env["Protected GitHub Environment"]
    end

    subgraph Security["Security Gates"]
        Actionlint["actionlint"]
        TFLint["tflint"]
        Checkov["checkov / tfsec"]
        Trivy["Trivy scan"]
        Cosign["cosign sign/verify"]
    end

    subgraph GCP["GCP"]
        VPC["Dedicated VPC"]
        PrivateGKE["Private GKE cluster"]
        WI["Workload Identity"]
        SM["Secret Manager"]
        Logs["Cloud Logging / Monitoring"]
    end

    PR --> Checks
    Checks --> Actionlint
    Checks --> TFLint
    Checks --> Checkov
    Checks --> Trivy
    Trivy --> Cosign
    Checks --> Env
    Env --> PrivateGKE

    VPC --> PrivateGKE
    WI --> PrivateGKE
    SM --> PrivateGKE
    PrivateGKE --> Logs
```

## Diagram maintenance notes

- Keep diagrams focused on system responsibilities rather than implementation minutiae.
- Prefer stable component names that match README and workflow names.
- Update this file when new runner hosts, registries, or major platform services are added.
- If a diagram becomes too dense, split it into lifecycle-specific diagrams.
