# {{PROJECT_NAME}}

[![Open in JupyterLab](https://img.shields.io/badge/Open%20in-JupyterLab-F37626?logo=jupyter&logoColor=white)]({{JL_URL}})  [![Deploy to KFP](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/deploy-to-kfp.yaml/badge.svg)](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/deploy-to-kfp.yaml)  [![Undeploy from KFP](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/undeploy-from-kfp.yaml/badge.svg)](https://github.com/miramar-labs-org/{{PROJECT_NAME}}/actions/workflows/undeploy-from-kfp.yaml)

| | |
| ----------- | -------------------------------------------------------------------- |
| **Type**    | KFP v2 NeMo Curator data-curation pipeline                           |
| **Host**    | {{PROJECT_HOST}}                                                     |

{{DESCRIPTION}}

---

## 1. What this is

A data-curation pipeline using NVIDIA NeMo Curator that takes raw documents (`data_src/`) and produces a cleaned, quality-filtered, deduplicated, and PII-redacted dataset. Each curation stage is a KFP v2 component; metrics are logged to MLflow at each step.

**DAG:**
```
preflight_check
  → extract_text        (CPU — text extraction, Unicode normalization)
      → quality_filter  (GPU — heuristic quality scoring + filtering)
          → deduplication   (GPU — exact hash dedup + fuzzy MinHash LSH)
              → pii_redaction  (CPU — presidio + spaCy PII detection/redaction)
                  → curator_report  (CPU — summary metrics, MLflow logging)
```

Two components run on GPU (`quality_filter`, `deduplication`) and use the RAPIDS cuDF backend for accelerated dataframe operations.

---

## 2. Quick start

1. Add source documents to `data_src/` (`.txt`, `.md`, `.html`, or `.jsonl`)
2. Edit `config.yaml` — set `input.format`, quality thresholds, dedup threshold, PII entity list
3. Open `notebook.ipynb` and implement the 4 `USER CODE BLOCK` sections (see `WORKBOOK.md`)
4. Run the **Build → `pipeline.py`** cell
5. Trigger **Deploy to KFP** from the Actions tab
6. Monitor progress in the KFP UI and MLflow

---

## 3. config.yaml reference

| Key | Type | Description |
|-----|------|-------------|
| `input.format` | string | Source file format: `jsonl`, `txt`, `md`, or `html` |
| `input.text_field` | string | For JSONL input: field name containing document text |
| `input.id_field` | string | For JSONL input: field name for document ID |
| `quality_filter.min_doc_length` | int | Minimum document length in characters |
| `quality_filter.max_doc_length` | int | Maximum document length in characters |
| `quality_filter.min_mean_word_length` | float | Minimum mean word length (chars) |
| `quality_filter.max_mean_word_length` | float | Maximum mean word length (chars) |
| `quality_filter.max_symbol_to_word_ratio` | float | Max ratio of symbols to words (0–1) |
| `quality_filter.min_stop_word_fraction` | float | Min fraction of stop words (0–1) |
| `deduplication.fuzzy_jaccard_threshold` | float | Jaccard similarity threshold (0–1); lower = more aggressive |
| `deduplication.fuzzy_ngram_size` | int | Character n-gram size for MinHash |
| `deduplication.fuzzy_num_hashes` | int | Number of MinHash hash functions |
| `pii.entities` | list | PII entity types to detect (presidio entity names) |
| `pii.action` | string | `redact`, `anonymize`, or `hash` |

---

## 4. Output

The final curated dataset is written to:
```
~/shared/huggingface-kfp/curator-input/{{PROJECT_NAME}}/curated/docs.jsonl
```

Each record: `{"id": "...", "text": "...", "source": "...", "char_count": N}`

A summary report is written to:
```
~/shared/huggingface-kfp/curator-output/{{PROJECT_NAME}}/{run_id}/curation_report.json
```

---

## 5. MLflow metrics

Each component logs stage metrics. Access the UI:

```sh
ssh -L 5000:localhost:5000 <user>@spark-79b7.local
# → http://localhost:5000
```

Key metrics logged per run:
- `stage/input_file_count`, `stage/input_total_bytes` — preflight
- `stage/extract_text/docs_in`, `stage/extract_text/docs_out` — extraction
- `stage/quality_filter/docs_in`, `stage/quality_filter/docs_out`, `stage/quality_filter/rejection_rate` — quality
- `stage/deduplication/docs_in`, `stage/deduplication/exact_removed`, `stage/deduplication/fuzzy_removed` — dedup
- `stage/pii_redaction/docs_processed`, `stage/pii_redaction/pii_instances_found` — PII
- `final/curated_doc_count`, `final/total_words` — final summary

---

## 6. GPU requirements

`quality_filter` and `deduplication` require GPU and RAPIDS (cuDF). Both components install
`nemo-curator[cuda12x]` from `https://pypi.nvidia.com` at startup. If arm64 pip wheels are
unavailable, see the Fallback section in `WORKBOOK.md`.

---

## 7. KFP UI

```sh
ssh -L 8080:localhost:8080 <user>@spark-79b7.local
# → http://localhost:8080
```

Prerequisites: **Kubeflow Deploy** must be running on `{{PROJECT_HOST}}`.
