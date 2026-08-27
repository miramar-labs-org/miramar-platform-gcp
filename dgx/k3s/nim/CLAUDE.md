# CLAUDE.md — dgx/k3s/nim

NIM inference scripts for the DGX Spark k3s cluster. Requires NeMo Microservices to be
deployed first (see `../nemo/` and the **NeMo Deploy** GHA workflow).

## Scripts

`deploy_nim.sh` and `undeploy_nim.sh` are **sourced**, not executed — they define shell functions:

```bash
# Deploy a NIM
source ./deploy_nim.sh && deploy_nim <org> <model> <version>

# Undeploy a NIM
source ./undeploy_nim.sh && undeploy_nim <org> <model>

# Tail NIM pod logs
./nimlogs.sh
```

## Available NIMs for DGX Spark

```bash
# Llama 3.1 8B Instruct
source ./deploy_nim.sh && deploy_nim meta llama-3.1-8b-instruct-dgx-spark 1.0.0-variant
source ./undeploy_nim.sh && undeploy_nim meta llama-3.1-8b-instruct-dgx-spark

# Nemotron Nano 9B v2 (has tools enabled)
source ./deploy_nim.sh && deploy_nim nvidia nvidia-nemotron-nano-9b-v2-dgx-spark 1.0.0-variant
source ./undeploy_nim.sh && undeploy_nim nvidia nvidia-nemotron-nano-9b-v2-dgx-spark
```

## Inference endpoint

```bash
curl http://nim.test/v1/models
curl http://nim.test/v1/chat/completions -H "Content-Type: application/json" -d '{...}'
```
