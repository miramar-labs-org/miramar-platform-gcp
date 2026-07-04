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

| Model                   | HF ID                          | Base          | Gated | MedMCQA baseline | Notes                                                                                            |
| ----------------------- | ------------------------------ | ------------- | ----- | ---------------- | ------------------------------------------------------------------------------------------------ |
| **Meditron-7B**         | `epfl-llm/meditron-7b`         | Llama-2 7B    | AUTO  | —                | EPFL; fine-tuned on medical guidelines + PubMed; strong clinical reasoning; **gated — skip**    |
| **BioMistral-7B**       | `BioMistral/BioMistral-7B`     | Mistral 7B    | No    | **48.1%**        | Pre-trained on PubMed Central; low baseline → most headroom; Mistral chat template; ~15 GB BF16 |
| **Med42-8B**            | `m42-health/Llama3-Med42-8B`   | Llama-3 8B    | No    | ~65%?            | Instruction-tuned + DPO on ~1B medical tokens; clinical Elo 924; 8k context; ~16 GB BF16       |
| **OpenBioLLM-8B**       | `aaditya/Llama3-OpenBioLLM-8B` | Llama-3 8B    | No    | —                | DPO + medical instruction tuning; strong 2024 benchmarks; Llama-3 chat template                |
| **Qwen2.5-7B-Instruct** | (in use)                       | Qwen2.5 7B    | No    | **64.0%**        | run-001 PASS (+17.2% → 0.75); run-002 recommended at 12h budget                                |
| **MedGemma-27B-IT**     | `google/medgemma-27b-it`       | Gemma-3 27B   | Auto  | **75.5%**        | run-001 degenerate PASS (zero gain); medical specialist at ceiling on MedMCQA; switch to USMLE |

### Proposed experiments

| # | Experiment | Effort | Key question |
|---|---|---|---|
| **A** | **BioMistral-7B + MedMCQA** (new project) | Low — formatter reuse from qwen25-7b-medmcqa | Does domain pre-training lower the bar for task-specific fine-tuning? |
| **B** | **qwen25-7b-medmcqa run-002** (existing) | Trivial — change `target_hours: 13.0` | How high can Qwen2.5-7B go on MedMCQA? Target 0.85+ |
| **C** | **Med42-8B + MedMCQA** (new project) | Low — same formatter | Three-way comparison: general vs domain-pretrained vs domain-DPO |
| **D** | **MedGemma-27B + MedQA-USMLE + CoT prompt** | Medium — new formatter + prompt from model card, 24h budget | Fix degenerate run-001: harder dataset + correct chain-of-thought prompt |
| **E** | **BioMistral-7B + PubMedQA** (new project) | Medium — new yes/no/maybe formatter | Does PubMed pre-training transfer to PubMed-derived QA? (1K labeled, fast) |

**Execution order:** B → A → C → D → E. A+B+C together form a clean model-comparison story on MedMCQA.

**Notes:**
- Meditron-7B is gated (requires explicit HF approval) — skip until approved
- MedMCQA HF path: `openlifescienceai/medmcqa`; MedQA-USMLE: `bigbio/med_qa`; PubMedQA: `qiaojin/PubMedQA` (config: `pqa_labeled`)
- MedGemma CoT prompt: verbatim from model card with step-by-step instructions; `max_new_tokens: 1024` (not 128)
- All models above fit in ~16 GB BF16 (7–8B); batch=4, grad_accum=4, 12h budget → ~1.5 epochs

---

## Genetics Fine-Tuning

> **Architecture note:** Raw DNA sequence tasks (ATCG variant classification, nucleotide benchmarks)
> require sequence-encoder models (DNABERT-2, Nucleotide Transformer, Caduceus) — incompatible
> with the `kfp-ft-eval` instruction-tuning template. All experiments below are knowledge-based
> text tasks. See the DNA Sequence Modeling section at the bottom for the separate workstream.

### Datasets

| Dataset | HF ID | Format | Size | Notes |
|---|---|---|---|---|
| **MedMCQA — genetics filter** | `openlifescienceai/medmcqa` | 4-option MC | ~3–5K Q | Filter `subject_name == "Genetics"`; inheritance, chromosomal disorders, gene-disease assoc.; 2-line loader change |
| **MedMCQA — pharmacogenomics filter** | `openlifescienceai/medmcqa` | 4-option MC | ~10–15K Q | Filter `subject_name in ["Genetics", "Pharmacology"]`; gene–drug interaction focus |
| **MedQA-USMLE — genetics filter** | `bigbio/med_qa` | 4-option MC | ~500–1K Q | Keyword filter on question text; harder clinical reasoning (pedigrees, risk calc, genotype-phenotype) |
| **MedAlpaca flashcards** | `medalpaca/medical_meadow_medical_flashcards` | free-form Q&A | large | Filter genetics keywords; instruction→output format; no MCQ structure — trains explanation generation |
| **PubMedQA** | `qiaojin/PubMedQA` | yes/no/maybe | 1K labeled | Use as eval-only probe; `pqa_labeled` config; tests cross-format generalization |

### Proposed experiments

| # | Experiment | Effort | Key question |
|---|---|---|---|
| **G1** | **MedMCQA genetics subset + Qwen2.5-7B** (new project) | Low — 2-line loader change | Does subdomain specialization improve genetics accuracy without medical regression? |
| **G2** | **MedMCQA pharmacogenomics filter + Qwen2.5-7B** (new project) | Low — same loader pattern | Can a model learn gene–drug interaction knowledge from exam questions? |
| **G3** | **MedQA-USMLE genetics + BioMistral-7B** (new project) | Medium — new dataset + keyword filter | Domain pre-training vs clinical genetics reasoning on harder questions |
| **G4** | **MedAlpaca genetics flashcards + PubMedQA eval** (new project) | Medium — new yes/no formatter | Does free-form genetics Q&A training generalize to research-paper QA? |

**Execution order:** G1 → G2 → G3 → G4.

**Notes:**
- G1 and G2 reuse the existing medmcqa formatter exactly — only the loader filter changes
- G1 cross-eval: run baseline + post-FT accuracy on **full** MedMCQA val (not just genetics subset) to measure regression
- G3 formatter: same letter-answer MCQ pattern; minor field rename (`options` dict vs `opa/opb/opc/opd`)
- G4 requires a new yes/no/maybe formatter for PubMedQA eval stage
- No genetics-specific instruction-tuned models exist yet; use same model pool as oncology (Qwen, BioMistral, Med42)

---

## DNA Sequence Modeling — Separate Workstream

For variant effect prediction, regulatory element classification, and other true genomics tasks,
a separate KFP template is needed using a DNA foundation model (sequence-encoder, not instruction LLM).

| Model | HF ID | Architecture | Context | Notes |
|---|---|---|---|---|
| **Nucleotide Transformer 2.5B** | `InstaDeepAI/nucleotide-transformer-2.5b-multi-species` | BERT encoder | 2048 tokens | Strong downstream genomics benchmark results |
| **DNABERT-2** | `zhihan1996/DNABERT-2-117M` | BERT encoder | 512 tokens | BPE tokenization (no k-mer); ~117M params; easy to fine-tune |
| **Caduceus-Ph** | `kuleshov-group/caduceus-ph_seqlen-131k_d_model-256_n_layer-16` | Mamba SSM | 131K tokens | Long-range genomic context |
| **HyenaDNA** | `LongSafari/hyenadna-large-1m-seqlen-hf` | Hyena SSM | 1M tokens | Extreme long-range; single-nucleus resolution |

Datasets: `InstaDeepAI/nucleotide_transformer_downstream_tasks_revised` (18 tasks, human genomics),
`wanglab/variant_effect_coding` (50K ClinVar+gnomAD pathogenic/benign), `m42-health/variant-benchmark`
(7 tasks including coding/non-coding pathogenicity).

### Experiment S1 — DNABERT-2 + ClinVar variant classification ✅ Done

Fine-tuned DNABERT-2 (~117M params, BERT encoder, BPE tokenization) on `wanglab/variant_effect_coding`.
Binary classification: pathogenic vs benign. Input: 200bp `variant_sequence` window. Output: pathogenic probability.

- Model: `zhihan1996/DNABERT-2-117M` (ungated, ~117M params, fits in <4 GB)
- Dataset: `wanglab/variant_effect_coding` — actual HF schema is `{ID, question, answer, reference_sequence, variant_sequence}`, 48,850 train / 1,233 test rows, ~78% benign / ~22% pathogenic; label derived from the `answer` text
- Task: binary classification (pathogenic=1 / benign=0) via classification head on [CLS] token
- Eval metric: accuracy + AUC-ROC (standard for imbalanced variant datasets)
- Template: `kfp-sequence-classify` (`templates/new-project-sequence-classify/`) — sequence tokenizer, no chat template, classification head, no generation. Bundled DNABERT-2 code imports a vendored `flash_attn_triton` module that calls a removed Triton `trans_b` API; the template builds the model via `AutoConfig`/`from_config` and nulls out `flash_attn_qkvpacked_func` so it falls back to standard attention.
- Result: project `dnabert2-clinvar-kfp-sequence-classify`, run-017 PASS — baseline AUC 0.50 → post-FT AUC 0.91 (accuracy 0.60 → 0.84), deployment gate passed
- Key question answered: yes — a small pre-trained DNA encoder learns pathogenicity signal from sequence context alone

**Stretch (still open):** swap in Nucleotide Transformer 2.5B for the same task — measure the
accuracy delta from 117M → 2.5B parameters. Classic scaling experiment.

---

## Personal Genomics Analysis (23andMe → ClinVar/PharmGKB)

Separate from ML fine-tuning — a data pipeline to analyze personal 23andMe data against
public variant databases. No model training; this is a lookup + report script.

**What it does:**
1. Parse `23andMe_raw_data.txt` → extract rsids where genotype differs from reference
2. Cross-reference against ClinVar → flag pathogenic / likely pathogenic hits
3. Cross-reference against PharmGKB → flag pharmacogenomic variants (drug metabolism, dosing)
4. Generate a structured report: variant, gene, condition, clinical significance, allele frequency

**Implementation:** standalone Python script or small KFP pipeline (no GPU needed).
Input: 23andMe txt file (on DGX at `~/shared/` or passed as KFP artifact).
Output: HTML/CSV report — pathogenic variants, PGx variants, VUS (variants of uncertain significance).

**Important:** pathogenic hits should be confirmed by a clinical lab and discussed with a
genetic counselor before acting on them. This is for informational/research purposes only.

Datasets needed (all public, no credentialing):
- ClinVar VCF: `ftp://ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh37/clinvar.vcf.gz`
- PharmGKB annotations: `https://www.pharmgkb.org/downloads` (free download, registration required)
- gnomAD allele frequencies: for filtering out common benign variants

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
