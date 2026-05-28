# DGX Operations

DGX Spark runs the local AI stack: minikube, NeMo Microservices, MLflow, NIM,
and Ollama. The runner label is `dgx`.

## Access

The DGX user services are reached through SSH tunnels:

```sh
ssh -L 8001:localhost:8001 \
    -L 8888:localhost:8888 \
    -L 5000:localhost:5000 \
    -L 11434:localhost:11434 \
    <user>@spark-79b7.local
```

| Port | Service |
| --- | --- |
| `8001` | Kubernetes dashboard proxy |
| `8888` | JupyterLab |
| `5000` | MLflow |
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
