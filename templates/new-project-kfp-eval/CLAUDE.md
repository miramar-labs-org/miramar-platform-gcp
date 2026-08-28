# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a KFP v2 RAG pipeline with eval-first design on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File | Purpose |
|------|---------|
| `config.yaml` | Project config — Qdrant URL, embedding model, LLM endpoint, eval thresholds, judge prompt |
| `eval_dataset.jsonl` | Eval Q&A pairs — one JSON row per question; used by retrieval_eval, generation_eval, faithfulness_eval, safety_eval |
| `docs_src/` | Domain documents to ingest (`.txt` / `.md`); copied to PVC by `scripts/deploy_pipeline.py` |
| `notebook.ipynb` | Source of truth — develop step logic here, run the Build cell to regenerate `pipeline.py` |
| `pipeline.py` | Generated from notebook — **do not edit manually** (gitignored) |
| `WORKBOOK.md` | Implementation checklist — every `USER CODE BLOCK` to fill in, with order and code examples |
| `scripts/deploy_pipeline.py` | Copy inputs to PVC, compile, register, and submit a run (called by Deploy to KFP workflow) |
| `scripts/terminate_pipeline.py` | Terminate a run by ID (called by Undeploy from KFP workflow) |

## Slash commands

| Command | What it does |
|---------|-------------|
| `/kfp-deploy [run-NNN]` | Purge KFP, deploy next run |
| `/kfp-monitor [run-NNN]` | Self-paced monitoring loop — checks pods + MLflow |
| `/model-card [org/model-id]` | Fetch and display the HuggingFace model card |

Full docs: [miramar-platform-gcp/docs/kfp-skills.md](https://github.com/miramar-labs-org/miramar-platform-gcp/blob/main/docs/kfp-skills.md)

## Editing config.yaml

**`llm.base_url` — HARD RULE:** must point to an active serving project on the platform.
If no serving project is running, `generation_eval`, `faithfulness_eval`, and `safety_eval` will fail.

**`qdrant.collection`** defaults to `{{PROJECT_NAME}}`. Change it only if you want multiple projects
to share a collection (unusual). The `ingest_documents` step deletes and recreates this collection
on every run.

After editing `config.yaml`:
1. Open `notebook.ipynb` and run the **Build → `pipeline.py`** cell
2. Compile check: `python3 -c "from kfp import compiler; from pipeline import pipeline; compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"`
3. Trigger **Deploy to KFP**

## eval_dataset.jsonl format

```json
{"question": "What is ...?", "reference_answer": "...", "gold_doc_ids": ["doc-stem"], "required_facts": ["fact 1"]}
```

- `gold_doc_ids` must match the stem of filenames in `docs_src/` (no extension). Used by `retrieval_eval` to compute recall@k and MRR. Leave empty `[]` if not labeled.
- `required_facts` lists key facts the answer must cover. Used by `generation_eval` judge for fact coverage scoring.

Aim for ≥ 20 rows for meaningful metrics. The `eval.sample_size` config key caps how many rows are used per run.

## Implementing the pipeline steps

After creating a project, `ingest_documents` and `deployment_gate` are fully implemented.
The four eval steps are stubs — fill them in this order:

### 1. `retrieval_eval` — Qdrant recall scoring

Embed each eval question, search Qdrant, check if `gold_doc_ids` appear in top-k results.

```python
q_emb = embed_model.encode(row["question"]).tolist()
results = client.query_points(collection_name=collection, query=q_emb, limit=top_k).points
retrieved_doc_ids = [r.payload.get("doc_id") for r in results]
gold = set(row.get("gold_doc_ids", []))
hit = any(d in gold for d in retrieved_doc_ids)
```

Metrics to compute: `recall_at_1`, `recall_at_5`, `mrr`, `hit_rate`.

### 2. `generation_eval` — RAG chain + correctness scoring

For each eval question: retrieve top-k chunks → build RAG prompt → call `llm_client` → judge correctness.

```python
context = "\n\n".join(f"[{h.payload['doc_id']}] {h.payload['text']}" for h in hits)
RAG_SYSTEM = (
    "You are a question-answering assistant. "
    "Answer ONLY using information in the provided context. "
    "Do NOT use outside knowledge or add information not in the context. "
    "If the answer cannot be found in the context, say so explicitly. "
    "Be concise and answer in 1-3 sentences."
)
resp = llm_client.chat.completions.create(
    model=llm_model,
    messages=[
        {"role": "system", "content": RAG_SYSTEM},
        {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {row['question']}"},
    ],
    max_tokens=max_new_tokens,
)
```

Judge prompt should return JSON: `{"answer_correctness": 1-5, "fact_coverage": 0.0-1.0}`.

**Always pass `timeout=60`** to every judge `chat.completions.create` call (generation_eval, faithfulness_eval, safety_eval). The judge runs on Ollama which shares unified memory with vLLM — without a timeout, a slow response hangs the entire component indefinitely.

### 3. `faithfulness_eval` — Citation faithfulness judge

For each generated answer (from `generation_results.jsonl`), ask the judge whether the answer is
grounded in the retrieved context. No hallucinations means high faithfulness.

Judge prompt should return JSON:
```json
{"faithfulness": 1-5, "citation_coverage": 0.0-1.0, "unsupported_claims": ["..."], "verdict": "PASS"|"FAIL"}
```

### 4. `safety_eval` — Safety judge

Same pattern as ft-eval's `safety_eval`. Score each generated answer on a 1–5 safety scale.

Judge prompt should return JSON: `{"safety": "PASS"|"FAIL", "score": 1-5, "comment": "brief"}`.

## LangSmith tracing (optional)

```yaml
# config.yaml
langsmith:
  enabled: true
  project: "{{PROJECT_NAME}}"
```

The `LANGCHAIN_API_KEY` must be in the `mlabs-api-keys` K8s secret (already provisioned by the platform).
When enabled, `generation_eval` should wrap its LLM calls with LangChain's `ChatOpenAI` + `LangChainTracer`
to emit traces to LangSmith.

## Component rules

- **All imports must be inside the function body** — each component runs in its own container
- `packages_to_install` on `@dsl.component` is the only way to add dependencies to a component
- All components are CPU-only — do NOT call `.set_accelerator_type("nvidia.com/gpu")`
- Secret env vars (`OPENAI_API_KEY`, `HF_TOKEN`, `LANGCHAIN_API_KEY`) are injected from the `mlabs-api-keys` K8s secret via `k8s_ext.use_secret_as_env` in the pipeline cell
- PVC `hf-model-cache` is mounted at `/root/.cache/huggingface`; RAG inputs live at `/root/.cache/huggingface/rag-input/{{PROJECT_NAME}}/`

## Compile check

```sh
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

## KFP UI access

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# → http://localhost:8080
```

## MLflow access

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
# → http://localhost:5000  (use ML experiment type, not GenAI apps & agents)
```

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
