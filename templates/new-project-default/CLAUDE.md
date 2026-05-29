# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a Miramar platform project on the DGX Spark.

<!-- Replace the line above with a one-sentence description. -->

## Workflows

| Workflow | Effect |
|---|---|
| **Open in JupyterLab** | Sync repo to DGX and open in JupyterLab |

## Platform endpoints

SSH tunnel from your laptop:

```sh
ssh -L 8001:localhost:8001 -L 8888:localhost:8888 -L 5000:localhost:5000 -L 8080:localhost:8080 -L 8082:localhost:8082 -L 8890:localhost:8890 -L 11434:localhost:11434 <user>@spark-79b7.local
```

| Service | URL |
|---|---|
| JupyterLab | http://localhost:8888 |
| KFP UI | http://localhost:8080 |
| KFP API | http://localhost:8890/apis/v2beta1/healthz |
| MLflow | http://localhost:5000 |
| NeMo / NIM | http://nemo.test:8082 (requires /etc/hosts: 127.0.0.1 nemo.test nim.test) |
| Ollama | http://localhost:11434 |

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
