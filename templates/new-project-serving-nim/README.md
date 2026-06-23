# {{PROJECT_NAME}}

{{DESCRIPTION}}

## Workflows

| Workflow  | Trigger | Description                                        |
| --------- | ------- | -------------------------------------------------- |
| Deploy    | Manual  | Pull NIM image from nvcr.io and deploy to DGX/GKE |
| Undeploy  | Manual  | Remove deployment; GKE also tears down GPU node pool |

## Quick start

1. Fill in `serving-config.yaml` — set `nim.org`, `nim.model_name`, and image tags
2. Run **Deploy** (`host=dgx` or `host=gke`)
3. Port-forward and test:
   ```bash
   kubectl port-forward svc/nim 8000:8000 -n {{PROJECT_NAME}}
   curl http://localhost:8000/v1/models
   ```
4. Run **Undeploy** when done

See [CLAUDE.md](CLAUDE.md) for detailed operating procedures.

## DGX Spark Compatible NIMs

| NIM / container | Type | DGX Spark note |
| --- | --- | --- |
| **Llama-3.1-8B-Instruct-DGX-Spark** | LLM | Dedicated DGX Spark container. NGC says it houses the Llama 3.1 8B Instruct NIM for DGX Spark. ([NVIDIA NGC][1]) |
| **Qwen3-32B-DGX-Spark** | LLM | Dedicated DGX Spark container; NVIDIA docs say "This NIM only runs on DGX Spark," NVFP4, 1 GPU, ~41.6 GB disk. Standalone-only — K8s/KServe not supported. ([NVIDIA Docs][2]) |
| **NVIDIA-Nemotron-Nano-9B-v2-DGX-Spark** | LLM | Dedicated DGX Spark container; NVIDIA docs say "This NIM only runs on DGX Spark," NVFP4 throughput profile, 1 GPU, ~7.85 GB disk. ([NVIDIA Docs][2]) |
| **Multi-LLM NIM** | LLM runtime/container | NGC search result explicitly shows **DGX Spark Supported**. ([NVIDIA NGC][3]) |
| **NVIDIA Nemotron 3 Nano / Nemotron-3-Nano 30B-A3B** | LLM | NVIDIA docs list DGX Spark under supported vLLM profiles for FP8 and BF16, using 1 DGX Spark / GH200 480GB class entry. ([NVIDIA Docs][2]) |
| **GPT-OSS-120B** | LLM | NVIDIA docs list DGX Spark support with MXFP4, 1 GPU, and MXFP4 LoRA, 1 GPU. ([NVIDIA Docs][2]) |
| **Llama-3.3-Nemotron-Super-49B-v1.5** | LLM | NGC search result lists DGX Spark among supported targets. ([NVIDIA NGC][4]) |
| **MiniMax-M2.5** | LLM | NGC search result says NVIDIA Blackwell support includes **GB10 / DGX Spark two-node**. May require stacked/two-Spark configuration, not a single box. ([NVIDIA NGC][5]) |
| **Cosmos Reason-2-8B** | Vision/reasoning / Cosmos NIM | NGC search result lists DGX Spark among supported targets. ([NVIDIA NGC][6]) |
| **Boltz-2** | Bio / molecular NIM | NGC search result lists DGX Spark among supported targets. ([NVIDIA NGC][7]) |
| **Magpie TTS Multilingual NIM** | Text-to-speech / Riva | NGC search result lists DGX Spark, H100, L40S. ([NVIDIA NGC][8]) |
| **Parakeet 1.1B RNNT Multilingual Speech-to-Text** | ASR / Riva | NGC search result lists DGX Spark, H100, L40S. ([NVIDIA NGC][9]) |
| **Parakeet 1.1B CTC en-US** | ASR / Riva | NGC search result lists DGX Spark, H100, L40S. ([NVIDIA NGC][10]) |

[1]: https://catalog.ngc.nvidia.com/orgs/nim/teams/meta/containers/llama-3.1-8b-instruct-dgx-spark "Llama-3.1-8b-Instruct-DGX-Spark - NGC Catalog - NVIDIA"
[2]: https://docs.nvidia.com/nim/large-language-models/1.15.0/supported-models.html "Supported Models for NVIDIA NIM for LLMs"
[3]: https://catalog.ngc.nvidia.com/orgs/nim/teams/nvidia/containers/llm-nim "Multi-LLM NIM - NGC Catalog - NVIDIA"
[4]: https://catalog.ngc.nvidia.com/orgs/nim/teams/nvidia/containers/llama-3.3-nemotron-super-49b-v1.5 "Llama-3.3-nemotron-super-49b-v1.5 - NGC Catalog - NVIDIA"
[5]: https://catalog.ngc.nvidia.com/orgs/nim/teams/minimax-ai/containers/minimax-m25 "MiniMax-M2.5 NIM Container Overview - NGC Catalog - NVIDIA"
[6]: https://catalog.ngc.nvidia.com/orgs/nim/teams/nvidia/containers/cosmos-reason2-8b "Cosmos Reason-2-8B - NGC Catalog - NVIDIA"
[7]: https://catalog.ngc.nvidia.com/orgs/nim/teams/mit/containers/boltz2 "Boltz-2 - NGC Catalog - NVIDIA"
[8]: https://catalog.ngc.nvidia.com/orgs/nim/teams/nvidia/containers/magpie-tts-multilingual "Magpie TTS Multilingual NIM - NGC Catalog - NVIDIA"
[9]: https://catalog.ngc.nvidia.com/orgs/nim/teams/nvidia/containers/parakeet-1-1b-rnnt-multilingual "Parakeet 1.1b RNNT Multilingual Speech to Text - NGC Catalog - NVIDIA"
[10]: https://catalog.ngc.nvidia.com/orgs/nim/teams/nvidia/containers/parakeet-1-1b-ctc-en-us "ASR Parakeet 1.1b CTC en-US - NGC Catalog - NVIDIA"
