# NIM Notes

list NIMs:

    curl -sS http://nim.test/v1/models | jq .


deploy a NIM:

    source ./deploy_nim.sh && deploy_nim meta llama-3.1-8b-instruct-dgx-spark 1.0.0-variant

undeploy a NIM:

    source ./undeploy_nim.sh && undeploy_nim meta llama-3.1-8b-instruct-dgx-spark

## Current (2/14/26) NIM's built for Spark:

[Llama-3.1-8b-Instruct-DGX-Spark](https://docs.nvidia.com/nim/large-language-models/1.15.0/supported-models.html#llama-3-1-8b-instruct-dgx-spark)

    source ./deploy_nim.sh && deploy_nim meta llama-3.1-8b-instruct-dgx-spark 1.0.0-variant

    source ./undeploy_nim.sh && undeploy_nim meta llama-3.1-8b-instruct-dgx-spark

[NVIDIA-Nemotron-Nano-9B-v2-DGX-Spark](https://docs.nvidia.com/nim/large-language-models/1.15.0/supported-models.html#nvidia-nemotron-nano-9b-v2-dgx-spark)

    source ./deploy_nim.sh && deploy_nim nvidia nvidia-nemotron-nano-9b-v2-dgx-spark 1.0.0-variant

    source ./undeploy_nim.sh && undeploy_nim nvidia nvidia-nemotron-nano-9b-v2-dgx-spark

(this one has tools enabled!)