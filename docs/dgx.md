# DGX Operations

DGX Spark runs the local AI stack: minikube, NeMo Microservices, MLflow, NIM,
and Ollama. The runner label is `dgx`.

AGX Orin runs the same stack minus NIM (no arm64 NIM images exist) — see
[agx.md](agx.md) for AGX-specific details and SSH tunnel port assignments.

## Access

```sh
ssh -L 8001:localhost:8001 \
    -L 8888:localhost:8888 \
    -L 5000:localhost:5000 \
    -L 8080:localhost:8080 \
    -L 8082:localhost:8082 \
    -L 8890:localhost:8890 \
    -L 11434:localhost:11434 \
    aaron@spark-79b7.local
```

| Local port | Service |
| --- | --- |
| `8001` | Kubernetes dashboard proxy |
| `8888` | JupyterLab |
| `5000` | MLflow |
| `8080` | Kubeflow Pipelines UI |
| `8082` | NeMo / NIM / Data Store ingress |
| `8890` | KFP REST API |
| `11434` | Ollama API |

See [../dgx/README.md](../dgx/README.md) and
[../dgx/systemd/README.md](../dgx/systemd/README.md).

## JupyterLab

JupyterLab runs on the DGX at port `8888` via the `jupyterlab.service` systemd unit. Access it through the SSH tunnel at [http://localhost:8888](http://localhost:8888).

Full environment details, installed packages, and project workflow tips: [../dgx/jupyterlab/README.md](../dgx/jupyterlab/README.md).

Project repos live at `~/git-miramar-labs-org/projects/<name>` on the DGX. Each project README has an **Open in JupyterLab** badge that links directly to `http://localhost:8888/lab/tree/git-miramar-labs-org/projects/<name>/notebook.ipynb` — click it with an SSH tunnel active.

### Git integration

`jupyterlab-git` (v0.53.0) is installed and active. It adds a **Git panel** in the left sidebar with full branch switching, staging, committing, and diff viewing — no terminal needed for routine git operations.

To switch branches from JupyterLab without the extension, open a terminal (`File → New → Terminal`) and run:

```sh
cd ~/git-miramar-labs-org/projects/<project-name>
git checkout <branch-name>
```

JupyterLab sees the filesystem live — files update immediately after a branch switch.

### Working on a project

1. Click the **Open in JupyterLab** badge in the project README
2. The notebook opens at `http://localhost:8888/lab/tree/git-miramar-labs-org/projects/<name>/notebook.ipynb`
3. Use the Git panel or terminal to switch to the relevant branch if needed
4. Edit and run cells — MLflow at `http://localhost:5000` tracks experiments automatically

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

The deploy workflow runs a smoke test after deployment (`dgx/minikube/mlflow/verify-mlflow-endpoints.sh`):
- `GET /health` — tracking server up
- `GET /api/2.0/mlflow/experiments/list` — PostgreSQL backend reachable

## Kubeflow Pipelines

Kubeflow Pipelines runs in minikube namespace `kubeflow`. Two systemd services
expose it over SSH tunnels:

- `kubeflow-portfwd.service` (port `8080`) — KFP UI (`svc/ml-pipeline-ui:80`)
- `kfp-api-portfwd.service` (port `8890`) — KFP REST API (`svc/ml-pipeline:8888`)

After deploying, restart both services and open `http://localhost:8080` (UI) or
hit `http://localhost:8890/apis/v2beta1/healthz` (API) through the SSH tunnel.

```text
Actions -> Build KFP arm64 Images    (once per version; covers all 13 arm64 images including MLMD)
Actions -> Kubeflow Undeploy         (clean slate before deploy)
Actions -> Kubeflow Deploy
```

Kubeflow is independent of NeMo and MLflow — it can be deployed on a fresh
minikube cluster without any other workloads.

The deploy workflow runs a smoke test after deployment (`dgx/minikube/kubeflow/verify-kfp-endpoints.sh`):
- `GET /` on `svc/ml-pipeline-ui:80` — UI serving
- `GET /apis/v2beta1/healthz` on `svc/ml-pipeline:8888` — API server healthy

### arm64 images (GHCR)

All 13 KFP images are built natively on the DGX. Full image catalog and patch
details: [../dgx/minikube/kubeflow/arm64/README.md](../dgx/minikube/kubeflow/arm64/README.md)

## Ollama

Ollama runs natively on the DGX host, not inside minikube. The platform
reserves ~28 GB for OS/services, leaving ~100 GB for models; no deployed model
may exceed this budget.

```text
Actions -> Ollama Update      (installs/upgrades binary; writes OLLAMA_VERSION)
Actions -> Ollama Deploy      (auto-undeploys existing model first; rollback on failure)
Actions -> Ollama Undeploy
```

Deploy auto-undeploys any currently loaded Ollama model before pulling the new
one, so you never need to manually undeploy first. If the deploy fails
(OOM, pull error, etc.) the workflow rolls back: unloads any partial load and
clears `CURRENT_OLLAMA_MODEL`. Fails if a NIM is still loaded.

See [../dgx/ollama/README.md](../dgx/ollama/README.md) for the local model
catalog. Browse available models: [ollama.com/library](https://ollama.com/library).

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
`http://nim.test/v1`. NIM Deploy swaps any currently running NIM first and
rolls back (undeploys + clears `CURRENT_NIM_MODEL`) on failure.

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

Available DGX Spark NIMs: [NVIDIA NIM supported models](https://docs.nvidia.com/nim/large-language-models/latest/supported-models.html) · [NGC DGX Spark containers](https://catalog.ngc.nvidia.com/orgs/nim/containers?filters=&orderBy=scoreDESC&query=dgx-spark).
