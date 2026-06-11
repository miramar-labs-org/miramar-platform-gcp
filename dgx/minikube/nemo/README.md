# NVidia NeMo Microservices on DGX Spark (minikube)

## Known issues

- The current minikube `nvidia-device-plugin` addon has a bug preventing the GB10 GPU from advertising itself. The deploy workflow pins a newer version that contains the fix.
- `guardrails` and `studio` are disabled in `install/values.yaml` — not yet ARM-compatible.
- Current NIM images have a TensorRT bug on Spark DGX; the workflow uses patched image tags.
- The upstream install requires 2 GPUs and GB10 is not on its approved list — both checks are patched.

## References

| Technology | GitHub | Docs |
|---|---|---|
| [NeMo Microservices](https://docs.nvidia.com/nemo/microservices/) | — | [docs](https://docs.nvidia.com/nemo/microservices/latest/) · [API reference (25.12)](https://docs.nvidia.com/nemo/microservices/25.12.1/api/index.html) · [get started on minikube](https://docs.nvidia.com/nemo/microservices/25.12.1/get-started/index.html) |
| [NeMo Framework](https://developer.nvidia.com/nemo-framework) | [NVIDIA/NeMo](https://github.com/NVIDIA/NeMo) | [docs](https://docs.nvidia.com/nemo-framework/user-guide/latest/overview.html) |
| [NIM](https://developer.nvidia.com/nim) | — | [docs](https://docs.nvidia.com/nim/) · [supported models](https://docs.nvidia.com/nim/large-language-models/1.15.0/supported-models.html) |
| [JupyterLab](https://jupyter.org) | [jupyterlab/jupyterlab](https://github.com/jupyterlab/jupyterlab) | [docs](https://jupyterlab.readthedocs.io/) |
| [MLflow](https://mlflow.org) | [mlflow/mlflow](https://github.com/mlflow/mlflow) | [docs](https://mlflow.org/docs/latest/index.html) |
| [Helm](https://helm.sh) | [helm/helm](https://github.com/helm/helm) | [docs](https://helm.sh/docs/) |
| [Volcano](https://volcano.sh) | [volcano-sh/volcano](https://github.com/volcano-sh/volcano) | [docs](https://volcano.sh/) |
| [NGC Catalog](https://catalog.ngc.nvidia.com/) | — | — |
| [meta-llama/Llama-3.1-8B-Instruct](https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct) on HuggingFace | — | request access at link |

## Deploying NeMo Microservices

Trigger the **NeMo Deploy** workflow from the GitHub Actions UI:

```
Actions → NeMo Deploy → Run workflow
```

The workflow handles everything: namespace creation, Kubernetes secrets, Volcano scheduler, Helm install of the NeMo Microservices chart, pod readiness wait (~30 min), and `/etc/hosts` DNS entries on the DGX host.

To tear down:

```
Actions → NeMo Undeploy → Run workflow
```

When successful you should see something like:

```
NAME                                                              READY   STATUS    RESTARTS   AGE
modeldeployment-meta-llama-3-1-8b-instruct-dgx-spark-5d5cbj7dnh   1/1     Running   0          139m
nemo-core-api-54674f5989-9kx4d                                    1/1     Running   0          149m
nemo-core-controller-9d9b6b99c-cpkqk                              1/1     Running   7          149m
nemo-customizer-6bd475bfb4-jnt4p                                  1/1     Running   0          110m
nemo-data-designer-6c6df98589-22srb                               1/1     Running   0          149m
nemo-data-store-556cb7ff85-pwzsb                                  1/1     Running   0          149m
nemo-evaluator-7ccf95dc7d-464ss                                   2/2     Running   0          110m
nemo-nim-proxy-b5f6b5765-t7gcv                                    1/1     Running   0          149m
...
```

## Service Endpoints

**Base URL**: `http://nemo.test` — NeMo microservices REST APIs

| Endpoint | Service |
|---|---|
| `http://nemo.test` | All `/v1/*` APIs (entity-store, customizer, evaluator, deployment-management, core-api) |
| `http://nim.test` | NIM Proxy — inference gateway |
| `http://data-store.test` | NeMo Data Store — HuggingFace-compatible API |

```bash
curl http://nim.test/v1/models
curl http://data-store.test/v1/health
curl http://nemo.test/v1/namespaces
curl http://nemo.test/v1/customization/jobs
```

Set the HuggingFace endpoint to route downloads through the Data Store:

```bash
export HF_ENDPOINT=http://data-store.test/v1/hf
```

## UI Access

Dashboard, JupyterLab, and MLflow are always running via systemd — no manual start needed. Both machines can be tunnelled simultaneously on offset local ports:

```sh
# DGX Spark
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 \
    -L 8082:localhost:8082 -L 11434:localhost:11434 $USER@spark-79b7.local

# AGX Orin
ssh -L 8002:localhost:8001 -L 8887:localhost:8888 -L 5001:localhost:5000 \
    -L 8083:localhost:8082 -L 11435:localhost:11434 $USER@orin.local
```

| Service | DGX URL | AGX URL |
|---|---|---|
| JupyterLab | `http://localhost:8888/lab` | `http://localhost:8887/lab` |
| MLflow | `http://localhost:5000` | `http://localhost:5001` |
| NeMo / NIM | `http://nemo.test:8082` | `http://nemo.test:8083` |
| Ollama | `http://localhost:11434` | `http://localhost:11435` |

## Python Client SDK

```bash
pip install nemo-microservices
```

From the **host** (no port needed — direct access via nginx ingress):

```python
from nemo_microservices import NeMoMicroservices

client = NeMoMicroservices(
    base_url="http://nemo.test",
    inference_base_url="http://nim.test"
)
namespaces = client.namespaces.list()
print(namespaces.data)
```

From a **laptop via SSH tunnel** (port required — `nemo.test` alone defaults to port 80):

```python
# DGX tunnel
client = NeMoMicroservices(base_url="http://nemo.test:8082", inference_base_url="http://nim.test:8082")

# AGX tunnel
client = NeMoMicroservices(base_url="http://nemo.test:8083", inference_base_url="http://nim.test:8083")
```
