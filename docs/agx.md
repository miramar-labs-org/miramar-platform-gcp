# AGX Orin Operations

AGX Orin runs the same local AI stack as the DGX Spark: minikube, NeMo
Microservices, MLflow, Qdrant, and Ollama. The runner label is `agx`.

> **NIM is not available on AGX.** All NIM LLM containers on NGC are
> `linux/amd64` only — no `linux/arm64` images exist. Use Ollama for inference
> on AGX instead.

Hardware: 64 GB unified memory (Ampere sm_87, JetPack 6.x).
Memory budget: ~24 GB OS/platform, **~40 GB for AI models** (`AGX_VRAM_USEABLE=40`).

## Access

AGX services are reached on different local ports from the laptop to avoid
conflicts with the DGX tunnel running simultaneously:

```sh
ssh -L 8002:localhost:8001 \
    -L 8887:localhost:8888 \
    -L 5001:localhost:5000 \
    -L 8081:localhost:8080 \
    -L 8083:localhost:8082 \
    -L 8891:localhost:8890 \
    -L 11435:localhost:11434 \
    -L 6335:localhost:6333 \
    -L 6336:localhost:6334 \
    $USER@orin.local
```

| Local port | AGX port | Service |
| --- | --- | --- |
| `8002` | `8001` | Kubernetes dashboard proxy |
| `8887` | `8888` | JupyterLab |
| `5001` | `5000` | MLflow |
| `8081` | `8080` | Kubeflow Pipelines UI |
| `8083` | `8082` | NeMo / NIM / Data Store ingress |
| `8891` | `8890` | KFP REST API |
| `11435` | `11434` | Ollama API |
| `6335` | `6333` | Qdrant REST API + web UI (`/dashboard`) |
| `6336` | `6334` | Qdrant gRPC |

See [../agx/systemd/README.md](../agx/systemd/README.md) for the service units.

## minikube

AGX minikube hosts the same workloads as DGX. All minikube workflows accept
a `runner` input — set it to `agx` to target the AGX cluster.

Stack deployment order:

```text
Actions -> Minikube Install   (runner: agx)
Actions -> NeMo Deploy        (runner: agx)
Actions -> MLflow Deploy      (runner: agx)
Actions -> Qdrant Deploy      (runner: agx)
Actions -> Kubeflow Deploy    (runner: agx)
Actions -> Ollama Deploy      (runner: agx)
```

## MLflow

Same setup as DGX — `mlflow-portfwd.service` forwards port `5000` on the AGX
host. Access via tunnel on local port `5001`.

```text
Actions -> MLflow Deploy    (runner: agx)
Actions -> MLflow Undeploy  (runner: agx)
```

Web UI (with AGX SSH tunnel active): [http://localhost:5001](http://localhost:5001)

## Qdrant

Same setup as DGX — `qdrant-portfwd.service` forwards ports `6333` (REST) and
`6334` (gRPC) on the AGX host. Access via tunnel on local ports `6335` (REST)
and `6336` (gRPC).

```text
Actions -> Qdrant Deploy    (runner: agx)
Actions -> Qdrant Undeploy  (runner: agx)
```

Web UI (with AGX SSH tunnel active): [http://localhost:6335/dashboard](http://localhost:6335/dashboard)

## Kubeflow Pipelines

Same arm64 images as DGX — no rebuild needed (both are `linux/arm64`).
Access via tunnel on local ports `8081` (UI) and `8891` (API).

```text
Actions -> Kubeflow Deploy    (runner: agx)
Actions -> Kubeflow Undeploy  (runner: agx)
```

## Ollama

Ollama runs natively on the AGX host (not in minikube), same as DGX.
Memory budget: ~40 GB for models. No NIM conflict check in the AGX deploy
script — the two machines are independent.

```text
Actions -> Ollama Update    (runner: agx)
Actions -> Ollama Deploy    (runner: agx)
Actions -> Ollama Undeploy  (runner: agx)
```

State variables: `CURRENT_OLLAMA_MODEL_AGX`, `CURRENT_OLLAMA_VRAM_GB_AGX`.

## NeMo Microservices

Same Helm chart and values as DGX (`dgx/minikube/nemo/install/values.yaml`).
Hosts file for minikube DNS: `agx/minikube/nemo/hosts.agx` (updated on deploy).

```text
Actions -> NeMo Deploy    (runner: agx)
Actions -> NeMo Undeploy  (runner: agx)
```

## NIM

NIM is **not supported on AGX Orin**. All NIM LLM containers on NGC are
`linux/amd64` only; there are no `linux/arm64` images. `CURRENT_NIM_MODEL_AGX`
stays `none`. Use Ollama for GPU inference on AGX.

