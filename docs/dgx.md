# DGX Operations

DGX Spark runs the local AI stack: minikube, NeMo Microservices, MLflow, NIM,
and Ollama. The runner label is `dgx`.

## Access

The DGX user services are reached through SSH tunnels:

```sh
ssh -L 8001:localhost:8001 \
    -L 8888:localhost:8888 \
    -L 5000:localhost:5000 \
    -L 8080:localhost:8080 \
    -L 11434:localhost:11434 \
    <user>@spark-79b7.local
```

| Port | Service |
| --- | --- |
| `8001` | Kubernetes dashboard proxy |
| `8888` | JupyterLab |
| `5000` | MLflow |
| `8080` | Kubeflow Pipelines UI |
| `11434` | Ollama API |

See [../dgx/README.md](../dgx/README.md) and
[../dgx/systemd/README.md](../dgx/systemd/README.md).

## minikube

DGX minikube hosts NeMo Microservices, MLflow, MinIO, and NIM deployments.

Lifecycle workflows:

```text
Actions -> Minikube Install
Actions -> Minikube Toggle
Actions -> Minikube Uninstall
```

Stack deployment order:

```text
Minikube Install -> NeMo Deploy -> MLflow Deploy -> NIM Deploy
```

See [../dgx/minikube/](../dgx/minikube/).

## MLflow

MLflow runs in minikube namespace `mlflow-system` behind
`svc/mlflow-tracking`. The `mlflow-portfwd.service` forwards port `5000`.

```text
Actions -> MLflow Deploy
Actions -> MLflow Undeploy
```

NeMo must be deployed before MLflow because MLflow uses NeMo's postgres backend.

## Kubeflow Pipelines

Kubeflow Pipelines runs in minikube namespace `kubeflow` behind
`svc/ml-pipeline-ui:80`. The `kubeflow-portfwd.service` forwards port `8080`.
After deploying, restart the service and open `http://localhost:8080` through
an SSH tunnel.

```text
Actions -> Build MLMD arm64 Images   (once per version, or after version bump)
Actions -> Kubeflow Deploy
Actions -> Kubeflow Undeploy
```

Kubeflow is independent of NeMo and MLflow — it can be deployed on a fresh
minikube cluster without any other workloads.

### arm64 MLMD images (GHCR)

The upstream MLMD images are amd64-only. These are our arm64 builds:

| Image | GHCR |
| --- | --- |
| `ml_metadata_store_server:1.14.0-arm64` | [ghcr.io/miramar-labs-org/ml_metadata_store_server](https://github.com/miramar-labs-org/miramar-platform-gcp/pkgs/container/ml_metadata_store_server) |
| `kfp-metadata-writer:2.16.1-arm64` | [ghcr.io/miramar-labs-org/kfp-metadata-writer](https://github.com/miramar-labs-org/miramar-platform-gcp/pkgs/container/kfp-metadata-writer) |

Build details and patches: [../dgx/minikube/kubeflow/arm64/README.md](../dgx/minikube/kubeflow/arm64/README.md)

## Ollama

Ollama runs natively on the DGX host, not inside minikube.

```text
Actions -> Ollama Update
Actions -> Ollama Deploy
Actions -> Ollama Undeploy
```

Deploy fails clearly if a NIM or another Ollama model is already occupying the
128 GB GPU pool. See [../dgx/ollama/README.md](../dgx/ollama/README.md).

## NeMo Microservices

NeMo runs in namespace `nemo-microservices` and provides the deployment API used
by NIM. It requires `NVIDIA_API_KEY`.

```text
Actions -> NeMo Deploy
Actions -> NeMo Undeploy
```

Deploy installs NeMo and Volcano. Undeploy removes NeMo, Volcano, DNS entries,
and postgres PVCs to avoid password drift on redeploy.

## NIM

NIMs are deployed through the NeMo deployment API and serve at
`http://nim.test/v1`.

```text
Actions -> NIM Deploy
Actions -> NIM Undeploy
```

Common DGX Spark models:

| Model | org | nim_name |
| --- | --- | --- |
| Nemotron Nano 9B v2 | `nvidia` | `nvidia-nemotron-nano-9b-v2-dgx-spark` |
| Llama 3.1 8B Instruct | `meta` | `llama-3.1-8b-instruct-dgx-spark` |

After deployment:

```sh
curl http://nim.test/v1/models
```
