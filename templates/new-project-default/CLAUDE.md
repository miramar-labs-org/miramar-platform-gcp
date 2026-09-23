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

Only Ollama and JupyterLab run on the AGX (no k3s stack; see the platform repo's `docs/agx.md`). Reach it by IP:

```sh
ssh -L 11435:localhost:11434 -L 8887:localhost:8888 aaron@192.168.1.202
```

| Service    | URL                                        |
| ---------- | ------------------------------------------ |
| JupyterLab | http://localhost:8887                      |
| Ollama     | http://localhost:11435                     |

Add to laptop `/etc/hosts`: `127.0.0.1 nemo.test nim.test data-store.test`

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
