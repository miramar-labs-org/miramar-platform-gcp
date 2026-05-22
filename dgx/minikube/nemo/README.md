# NVidia NeMo Microservices on DGX Spark (minikube)

## Known issues (1/13/2026)

- The current minikube `nvidia-device-plugin` addon has a bug preventing the GB10 GPU from advertising itself. The deploy workflow pins a newer version that contains the fix.
- `guardrails` and `studio` are disabled in `install/values.yaml` — not yet ARM-compatible.
- Current NIM images have a TensorRT bug on Spark DGX; the workflow uses patched image tags.
- The upstream install requires 2 GPUs and GB10 is not on its approved list — both checks are patched.

## References

- [NeMo Framework](https://docs.nvidia.com/nemo-framework/user-guide/latest/overview.html)
- [NeMo Microservices](https://docs.nvidia.com/nemo/microservices/latest/get-started/index.html)
- [NeMo Demo Cluster on minikube](https://docs.nvidia.com/nemo/microservices/25.12.0/get-started/index.html)
- [NGC Catalog](https://catalog.ngc.nvidia.com/)
- [llama-3.1-8b-instruct-dgx-spark](https://catalog.ngc.nvidia.com/orgs/nim/teams/meta/containers/llama-3.1-8b-instruct-dgx-spark?version=1.0.0-variant)
- [meta-llama/Llama-3.1-8B-Instruct](https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct) — request access here

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

Dashboard, JupyterLab, and MLflow are always running via systemd — no manual start needed. Open an SSH tunnel from your laptop:

```sh
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 <user>@spark-79b7.local
```

| Service | URL |
|---|---|
| Kubernetes dashboard | `http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/` |
| JupyterLab | `http://localhost:8888/lab` |
| MLflow | `http://localhost:5000` |

## Python Client SDK

```bash
pip install nemo-microservices
```

```python
from nemo_microservices import NeMoMicroservices

client = NeMoMicroservices(
    base_url="http://nemo.test",
    inference_base_url="http://nim.test"
)

namespaces = client.namespaces.list()
print(namespaces.data)
```
