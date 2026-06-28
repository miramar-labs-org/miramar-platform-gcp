# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a Miramar platform project on the DGX Spark / AGX Orin.

<!-- Replace the line above with a one-sentence description. -->

## JupyterLab

Click the **Open in JupyterLab** badge in the README (requires SSH tunnel). The project repo is at `~/git-miramar-labs-org/projects/{{PROJECT_NAME}}` on the DGX.

## Platform endpoints

### DGX Spark

```sh
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 \
    -L 8080:localhost:8080 -L 8082:localhost:8082 -L 8890:localhost:8890 \
    -L 11434:localhost:11434 -L 6333:localhost:6333 \
    -L 8889:localhost:8889 -L 8084:localhost:8084 aaron@spark-79b7.local
```

| Service    | URL                                        |
| ---------- | ------------------------------------------ |
| JupyterLab | http://localhost:8888                      |
| KFP UI     | http://localhost:8080                      |
| KFP API    | http://localhost:8890/apis/v2beta1/healthz |
| MLflow     | http://localhost:5000                      |
| NeMo / NIM | http://nemo.test:8082                      |
| Ollama     | http://localhost:11434                     |
| Qdrant     | http://localhost:6333/dashboard            |
| Nsight UI  | http://localhost:8889                      |
| Open WebUI | http://localhost:8084                      |

### AGX Orin

```sh
ssh -L 8002:localhost:8001 -L 8887:localhost:8888 -L 5001:localhost:5000 \
    -L 8081:localhost:8080 -L 8083:localhost:8082 -L 8891:localhost:8890 \
    -L 11435:localhost:11434 -L 6335:localhost:6333 \
    -L 8892:localhost:8889 -L 8085:localhost:8084 aaron@orin.local
```

| Service    | URL                                        |
| ---------- | ------------------------------------------ |
| JupyterLab | http://localhost:8887                      |
| KFP UI     | http://localhost:8081                      |
| KFP API    | http://localhost:8891/apis/v2beta1/healthz |
| MLflow     | http://localhost:5001                      |
| NeMo / NIM | http://nemo.test:8083                      |
| Ollama     | http://localhost:11435                     |
| Qdrant     | http://localhost:6335/dashboard            |
| Nsight UI  | http://localhost:8892                      |
| Open WebUI | http://localhost:8085                      |

Add to laptop `/etc/hosts`: `127.0.0.1 nemo.test nim.test data-store.test`

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
