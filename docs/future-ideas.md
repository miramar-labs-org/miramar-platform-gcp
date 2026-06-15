# Future Ideas

Backlog of dataset, model, and pipeline ideas for future projects on the Miramar platform.

---

## Oncology Fine-Tuning

### Datasets

| Dataset                                     | HF ID                | Format       | Size   | Notes                                                                                                                                                     |
| ------------------------------------------- | -------------------- | ------------ | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **MedMCQA**                                 | `medmcqa`            | 4-option MC  | 194K Q | Indian medical entrance exams; broad clinical coverage incl. oncology, hematology, pharmacology; drop-in ARC-Challenge replacement — same formatter shape |
| **MedQA-USMLE**                             | `bigbio/med_qa`      | 4-option MC  | ~12K Q | US board exam questions; harder/more reasoning-heavy than MedMCQA; oncology subset present                                                                |
| **PubMedQA**                                | `pubmed_qa`          | yes/no/maybe | 211K Q | QA over PubMed abstracts; large oncology slice; different format — new formatter needed                                                                   |
| **ClinicalTrials.gov eligibility criteria** | (no HF loader)       | free text    | large  | Inclusion/exclusion criteria, cancer staging, treatment protocols; public but requires custom scraper → formatter                                         |
| **TCGA clinical notes**                     | (dbGaP credentialed) | free text    | —      | De-identified pathology reports and clinical summaries; requires NIH credentialing; good for structured extraction (staging, histology)                   |

**Easiest starting point:** MedMCQA — no credentialing, same 4-option MC format as ARC-Challenge, `config.yaml` + a new formatter + a new loader is all that changes.

### Models

| Model                   | HF ID                          | Base       | Notes                                                                                            |
| ----------------------- | ------------------------------ | ---------- | ------------------------------------------------------------------------------------------------ |
| **Meditron-7B**         | `epfl-llm/meditron-7b`         | Llama-2 7B | EPFL; fine-tuned on medical guidelines + PubMed; strong clinical reasoning                       |
| **BioMistral-7B**       | `BioMistral/BioMistral-7B`     | Mistral 7B | Fine-tuned on PubMed Central; good biomedical baseline                                           |
| **OpenBioLLM-8B**       | `aaditya/Llama3-OpenBioLLM-8B` | Llama-3 8B | Strong 2024 medical benchmarks                                                                   |
| **Qwen2.5-7B-Instruct** | (current)                      | —          | Already at 0.89 on ARC-Challenge; fine-tuning on MedMCQA would specialize without changing infra |

### Recommended sequence

1. **MedMCQA + Qwen2.5-7B-Instruct** — lowest friction; establishes oncology/clinical baseline delta on known strong model
2. **MedMCQA + Meditron-7B** — same dataset, swap base model; compare domain-adapted base vs general base
3. **MedQA-USMLE + best model from step 2** — harder eval set; validate that fine-tuning generalizes beyond the training distribution

---

## Medical Arc — Three-Project Clinical ML Template

Full lifecycle template arc for clinical ML on the Miramar platform. Each project is a reusable template for a clinical task category.

1. **`medgemma-kfp-ft-eval-pipeline`** — eval-first LoRA fine-tuning on DGX. KFP pipeline: prepare_dataset → baseline_eval + fine_tune → post_finetune_eval → clinical_safety_eval → deployment_gate → GCS.
2. **GKE vLLM serving project** — pull LoRA adapter from GCS, serve via vLLM on GKE with OpenAI-compatible API. Init container pulls adapter; K8s Deployment + Service; GHA deploy/undeploy workflows.
3. **Inference optimization project** — prune → distill → quantize (FP8) the fine-tuned model using Model-Optimizer + Megatron-Bridge (`dli-llm-prune-dist-quant-course` patterns). Output: quantized merged model, served via TensorRT-LLM or NIM instead of LoRA + vLLM.

---

## ARC-Challenge Pipeline (qwen25-7b-arc-ft-eval-pipeline)

Next steps after run-001 (PASS, accuracy 0.9009→0.9189):

- **Nsight profiling** — `fine_tune` is ~594s; profile with `--profile-finetune` in a run-002 deploy, then run `/nsight-interpret` to find bottlenecks.
- **FP8 quantization** — quantize the LoRA adapter with `hf_ptq.py` (FP8 W8A8) and run a post-compression accuracy check to measure the compression delta vs BF16.
- **GKE serving** — scaffold a `serving-vllm` type project to deploy a GKE vLLM serving pipeline for the fine-tuned model.
- **Increase dataset size** — currently only ARC-Challenge train split (~2.5k examples); mixing in ARC-Easy or other reasoning datasets could push accuracy higher.

---

## PHI / Data Boundary Reminder

Any dataset containing real clinical data (TCGA, MIMIC, i2b2) must stay on DGX. LLM judges for PHI-adjacent evals must also run locally (Ollama/NIM on DGX) — not GPT-4o or Claude API.
