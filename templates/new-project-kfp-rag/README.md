# {{PROJECT_NAME}}

[![Open in JupyterLab](https://img.shields.io/badge/Open%20in-JupyterLab-F37626?logo=jupyter&logoColor=white)]({{JL_URL}})  [![Deploy to KFP](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/deploy-to-kfp.yaml/badge.svg)](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/deploy-to-kfp.yaml)  [![Undeploy from KFP](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/undeploy-from-kfp.yaml/badge.svg)](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/undeploy-from-kfp.yaml)

| | |
| ----------- | -------------------------------------------------------------------- |
| **Type**    | KFP v2 RAG pipeline with eval-first design                           |
| **Qdrant**  | `{{PROJECT_NAME}}` collection on the platform Qdrant instance        |
| **Host**    | {{PROJECT_HOST}}                                                     |

{{DESCRIPTION}}

---

## 1. What this is

An eval-first RAG pipeline that ingests documents into Qdrant, evaluates retrieval quality,
generates answers via an OpenAI-compatible LLM endpoint, scores faithfulness and safety with
an LLM judge, then gates on the results before marking the collection as deployment-ready.

**DAG:**
```
ingest_documents
  → retrieval_eval
      → generation_eval
          → faithfulness_eval ─┐
          → safety_eval ───────┤
                               └→ deployment_gate
```

All steps run CPU-only. The LLM endpoint (`llm.base_url` in `config.yaml`) must be an active
serving project on the platform.

---

## 2. Quick start

1. Edit `config.yaml` — set `qdrant.collection`, `llm.base_url`, `llm.model`, and eval thresholds
2. Add domain documents to `docs_src/` (`.txt` or `.md` files)
3. Edit `eval_dataset.jsonl` — replace the 3 stub rows with real Q&A pairs
4. Open `notebook.ipynb` and implement the 4 `USER CODE BLOCK` sections (see `WORKBOOK.md`)
5. Run the **Build → `pipeline.py`** cell
6. Trigger **Deploy to KFP** from the Actions tab

---

## 3. config.yaml reference

| Key | Type | Description |
|-----|------|-------------|
| `qdrant.url` | string | Qdrant service URL (platform default is pre-filled) |
| `qdrant.collection` | string | Qdrant collection name (defaults to project name) |
| `embedding.model` | string | Sentence-transformers model ID for chunking + embedding |
| `embedding.chunk_size` | int | Characters per chunk |
| `embedding.chunk_overlap` | int | Overlap between adjacent chunks |
| `llm.base_url` | string | OpenAI-compatible endpoint (must be an active serving project) |
| `llm.model` | string | Served model alias |
| `llm.top_k` | int | Number of retrieved chunks to include in RAG context |
| `eval.sample_size` | int | Number of eval_dataset.jsonl rows to evaluate |
| `eval.min_faithfulness_score` | float | Gate threshold: avg faithfulness score (1–5) |
| `eval.min_relevancy_score` | float | Gate threshold: avg answer correctness score (1–5) |
| `eval.min_citation_coverage` | float | Gate threshold: fraction of answers with cited chunks |
| `eval.max_unsupported_claim_rate` | float | Gate threshold: max fraction of unsupported claims |
| `eval.min_safety_score` | float | Gate threshold: avg safety score (1–5) |
| `judge.model` | string | LLM judge model ID (Ollama-compatible) |
| `judge.base_url` | string | Judge LLM endpoint (usually Ollama at 11434) |
| `judge.system_prompt` | string | System prompt — must elicit JSON output |
| `langsmith.enabled` | bool | Enable LangSmith tracing (requires `LANGCHAIN_API_KEY`) |
| `langsmith.project` | string | LangSmith project name |

---

## 4. eval_dataset.jsonl format

Each row must be valid JSON:
```json
{
  "question": "What is ...?",
  "reference_answer": "...",
  "gold_doc_ids": ["my-doc"],
  "required_facts": ["fact 1", "fact 2"]
}
```

- `gold_doc_ids` — used by `retrieval_eval` to compute recall@k and MRR
- `required_facts` — used by `generation_eval` judge to score fact coverage
- Leave `gold_doc_ids` empty if you haven't labeled which documents contain the answer

---

## 5. MLflow

Each component logs metrics to MLflow. Access the UI:

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
# → http://localhost:5000
```

Use **ML** experiment type (not *GenAI apps & agents*).

Key metrics logged per run:
- `recall_at_1`, `recall_at_5`, `mrr`, `hit_rate` — retrieval quality
- `avg_answer_correctness`, `avg_fact_coverage` — generation quality
- `avg_faithfulness`, `avg_citation_coverage`, `unsupported_claim_rate` — faithfulness
- `avg_safety_score`, `unsafe_response_rate` — safety
- `gate_pass` — 1 if gate passed, 0 if failed

---

## 6. Qdrant

The platform runs Qdrant at `http://qdrant.qdrant-system.svc.cluster.local:6333` (in-cluster).
Access from the DGX host:

```sh
# Port-forward for browser access
kubectl port-forward -n qdrant-system svc/qdrant 6333:6333 &
# → http://localhost:6333/dashboard
```

The `ingest_documents` step recreates the collection on every run (deletes and rebuilds).
Collections persist between pipeline runs — only the most recent ingest's data is in the collection.

---

## 7. LangSmith (optional)

Enable tracing to LangSmith for distributed trace inspection of the RAG chain:

1. Set `langsmith.enabled: true` and `langsmith.project: "{{PROJECT_NAME}}"` in `config.yaml`
2. Add `LANGCHAIN_API_KEY` to the `mlabs-api-keys` K8s secret (already provisioned by the platform)

---

## 8. Kubeflow Pipelines UI

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# → http://localhost:8080
```

Prerequisites: **Kubeflow Deploy** must be running. Trigger it in
[miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp) if the UI
is unreachable.
