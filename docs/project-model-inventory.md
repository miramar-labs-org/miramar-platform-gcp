# Project model inventory

Which LLM every template and every project under `~/git-miramar-labs-org/projects/`
is configured to use, and **which machine that model actually runs on**.

Rebuilt 2026-09-08 by reading each template's and project's `config.yaml` /
`serving-config.yaml` (and `notebook.ipynb` where there is no config), then
cross-checking every Ollama tag against the live `/api/tags` on both hosts.

Host key: **DGX** = DGX Spark, `192.168.1.200`, ~100 GB model budget ·
**AGX** = AGX Orin, `192.168.1.202`, ~40 GB model budget.
Every project's GHA jobs run on the `dgx` runner; the host column below is where
the *model* executes, which is not always the same machine.

## Templates — what a new project gets

Templates no longer name a model. They carry `"{{DGX_DEFAULT_MODEL}}"` and
`"{{AGX_DEFAULT_MODEL}}"`, which **Create Project** substitutes from the org
variables and freezes into the new repo at scaffold time.

| Org variable | Current value | Host | Role |
|---|---|---|---|
| `DGX_DEFAULT_MODEL` | `qwen3.6:35b-a3b` | **DGX** | the primary LLM a scaffolded project queries |
| `AGX_DEFAULT_MODEL` | `phi4` | **AGX** | the one shared platform judge |

| Template | Primary model | **Runs on** | Judge | **Judge runs on** |
|---|---|---|---|---|
| `ft-eval` | `model.id` — a HuggingFace repo you pick | **DGX** | `{{AGX_DEFAULT_MODEL}}` | **AGX** |
| `nemo-ft-eval` | `model.id` / `hf_id` — NeMo + HF repo you pick | **DGX** | `{{AGX_DEFAULT_MODEL}}` | **AGX** |
| `kfp-rag` | `{{DGX_DEFAULT_MODEL}}`<br>embed `BAAI/bge-small-en-v1.5` | **DGX** | `{{AGX_DEFAULT_MODEL}}` | **AGX** |
| `kfp-eval` | `{{DGX_DEFAULT_MODEL}}` (candidate) | **DGX** | `{{AGX_DEFAULT_MODEL}}` | **AGX** |
| `sequence-classify` | `{{HF_MODEL_ID}}` — a HuggingFace repo | **DGX** | — | — |
| `serving-vllm`, `serving-triton-vllm` | `{{HF_MODEL_ID}}` → `{{SERVED_MODEL_NAME}}` | **DGX** or GKE | — | — |
| `serving-nim`, `serving-llm-nim`, `serving-trt-fp8`, `serving-trt-engine`, `serving-triton-trtllm` | `{{SERVED_MODEL_NAME}}` | **DGX** or GKE | — | — |
| `kfp-nemo-curator` | *none* — rule-based filters + Presidio PII | **DGX** (CPU) | — | — |

The default-model variables are deliberately **not** substituted into any
HuggingFace `model.id`: an Ollama tag is not a LoRA-fine-tunable HF repo, so the
fine-tune templates still require you to name the model you are training.

## Projects

| Project | Model(s) | How it is served | **Model runs on** | Judge | **Judge runs on** |
|---|---|---|---|---|---|
| agent-model-bakeoff | `qwen3.6:35b-a3b`, `gpt-oss:120b`, `nemotron-3-super:latest` | Ollama `192.168.1.200` | **DGX** | `gpt-oss:120b` | **DGX** ⚠ |
| ai-interviewer | `agx/qwen2.5:32b` (interviewer + grader + coach)<br>embed `BAAI/bge-small-en-v1.5` | model router → `agx/` upstream | **AGX** (routed via DGX) | — | — |
| ai-jobsearch | `qwen3.6:35b-a3b` | Ollama AGX `.202` → `localhost` fallback | **AGX**, falls back to **DGX** | — | — |
| alpaca-options-trading-agents | `qwen2.5:32b-instruct-q4_K_M` | Ollama `192.168.1.200` | **DGX** | — | — |
| dnabert2-clinvar-kfp-sequence-classify | `zhihan1996/DNABERT-2-117M` | HF weights, in-pipeline | **DGX** | — | — |
| kfp-nemo-curator-verify | *none* — rule-based filters + Presidio PII | — | **DGX** (CPU) | — | — |
| llama32-3b-serving-trt-engine | `meta-llama/Llama-3.2-3B-Instruct` | TensorRT engine, k3s | **DGX** | — | — |
| medgemma-27b-med-kfp-ft-eval-pipeline | `google/medgemma-27b-it` | HF weights, in-pipeline | **DGX** | `phi4` | **DGX** ⚠ |
| multi-agent-ai-trader | `qwen3.6:35b-a3b` | Ollama `192.168.1.200` | **DGX** | — | — |
| pharma-promo-compliance-vlm-eval | `qwen2.5vl:72b` (VLM) | Ollama `localhost` | **DGX** | `nemotron-3-nano:30b` | **AGX** ⚠ |
| qwen25-7b-arc-ft-eval-pipeline | `Qwen/Qwen2.5-7B-Instruct` | HF weights, in-pipeline | **DGX** | `phi4` | **DGX** ⚠ |
| qwen25-7b-fp8-quant-pipeline | `Qwen/Qwen2.5-7B-Instruct` | HF weights, in-pipeline | **DGX** | — | — |
| qwen25-7b-ftuned-serving-vllm | `Qwen/Qwen2.5-7B-Instruct` + LoRA → `qwen25-arc` | vLLM, k3s (`gpu_type: gb10`) | **DGX** | — | — |
| qwen25-7b-medmcqa-kfp-ft-eval-pipeline | `Qwen/Qwen2.5-7B-Instruct` | HF weights, in-pipeline | **DGX** | `phi4` | **DGX** ⚠ |
| qwen25-arc-kfp-rag | `qwen25-arc`<br>embed `BAAI/bge-small-en-v1.5` | in-cluster vLLM Service | **DGX** | `phi4` | **DGX** ⚠ |
| slac-science-kfp-rag | `gpt-oss:20b`<br>embed `BAAI/bge-small-en-v1.5` | Ollama `192.168.1.200` | **DGX** | `gpt-oss:20b` | **DGX** ⚠ |

⚠ = deviates from the platform-judge rule **on that repo's `main`**. Every one of them
has an open PR fixing it; the marks clear as those merge. See below.

## Cache verification

Every Ollama tag referenced above was checked against the live catalogs on
2026-09-08 (**DGX 17 models, AGX 7 models**). All are present on the host they
are pointed at, including both default-model variables — `qwen3.6:35b-a3b` on
the DGX and `phi4` on the AGX.

Six models are **DGX-only by size** — they exceed the AGX's ~40 GB budget and
could never be moved there:

| Model | Size | Fits AGX? |
|---|---|---|
| `nemotron-3-super:latest` | 86.8 GB | no |
| `qwen2.5-coder:32b-instruct-fp16` | 65.5 GB | no |
| `gpt-oss:120b` | 65.4 GB | no |
| `qwen3-coder-next:latest` | 51.7 GB | no |
| `qwen2.5vl:72b` | 48.7 GB | no |
| `llama3.3:70b-instruct-q4_K_M` | 42.5 GB | no |

Models present on **both** hosts: `gpt-oss:20b`, `nemotron-3-nano:30b`, `phi4`,
`qwen3.6:35b-a3b`. For these the config's `base_url` is the only thing deciding
which machine does the work.

Two naming traps:

- `qwen2.5:32b-instruct-q4_K_M` (DGX) and `qwen2.5:32b` (AGX) are *different
  tags*, not the same model on two hosts.
- Configs say `phi4`; the catalogs list `phi4:latest`. Same model — Ollama
  resolves a bare name to `:latest`.

## Deviations from the platform judge

The platform judge is **one** model at **one** endpoint — `AGX_DEFAULT_MODEL`
(currently `phi4`) at `http://192.168.1.202:11434/v1` (AGX) — so scores stay
comparable across runs, projects and time. It landed in the templates in PR #80
(`b6802c5`) and became a variable in PR #82 (`8e705e8`).

All 8 judge-bearing projects predate that and deviated. Each now has an open PR
bringing it in line (see the table below).

| Deviation | Projects | Detail |
|---|---|---|
| Right model, wrong host | medgemma-27b-med, qwen25-7b-arc, qwen25-7b-medmcqa, qwen25-arc-kfp-rag | `phi4` but pointed at DGX `.200` instead of AGX `.202` |
| Right host, wrong model | pharma-promo-compliance-vlm-eval | `nemotron-3-nano:30b` on the AGX |
| Wrong model and host | agent-model-bakeoff (`gpt-oss:120b`), slac-science-kfp-rag (`gpt-oss:20b`) | both on the DGX |

**Not every fix costs the same.** Moving the judge *host* DGX → AGX is score-neutral:
same model at `temperature: 0` gives identical verdicts on either, ~5.6× slower per
call (`agx.md`). Changing the judge *model* is not — it invalidates comparison with
every score the project has already recorded. Only the bottom two rows do that.

Two further issues:

- **Self-grading bias** — `slac-science-kfp-rag` scores `gpt-oss:20b` output with
  `gpt-oss:20b`. Candidate and judge are the same model. `agent-model-bakeoff` had
  the same shape: its `gpt-oss:120b` judge was also one of the candidates it ranked.
- **`ai-jobsearch` (the recruiter-inbox poller) addresses the AGX as `orin.local`** — a convention
  deviation, not a bug. It runs as a systemd `--user` timer on the DGX *host*, where
  mDNS resolves (`getent hosts orin.local` → `192.168.1.202`), so it has been reaching
  the Orin correctly. The IP is still the right form: mDNS does not resolve from a k3s
  pod (CoreDNS does no mDNS) or from the runner container without the avahi socket, so
  `http://192.168.1.202:11434` keeps the config correct if the poller ever moves.

PRs #80 and #82 changed templates only. The standing rule is that project-repo issues
are fixed at template level and the project re-scaffolded — that rule assumes throwaway
template-test projects. These eight carry 4–47 commits of real results, so they were
patched directly instead, one PR each, on the operator's explicit call.

| Project | PR |
|---|---|
| medgemma-27b-med-kfp-ft-eval-pipeline | [#1](https://github.com/miramar-labs-org/medgemma-27b-med-kfp-ft-eval-pipeline/pull/1) |
| qwen25-7b-arc-ft-eval-pipeline | [#2](https://github.com/miramar-labs-org/qwen25-7b-arc-ft-eval-pipeline/pull/2) |
| qwen25-7b-medmcqa-kfp-ft-eval-pipeline | [#1](https://github.com/miramar-labs-org/qwen25-7b-medmcqa-kfp-ft-eval-pipeline/pull/1) |
| qwen25-arc-kfp-rag | [#3](https://github.com/miramar-labs-org/qwen25-arc-kfp-rag/pull/3) |
| agent-model-bakeoff | [#2](https://github.com/miramar-labs-org/agent-model-bakeoff/pull/2) |
| slac-science-kfp-rag | [#1](https://github.com/miramar-labs-org/slac-science-kfp-rag/pull/1) |
| pharma-promo-compliance-vlm-eval | [#1](https://github.com/miramar-labs-org/pharma-promo-compliance-vlm-eval/pull/1) |
| ai-jobsearch | [#2](https://github.com/miramar-labs-org/ai-jobsearch/pull/2) |

⚠️ `pharma-promo-compliance-vlm-eval` is the one whose *model* changes, so its stored
notebook outputs and `results/scoring/` were produced by the old judge and need a re-run
before they are cited again.
