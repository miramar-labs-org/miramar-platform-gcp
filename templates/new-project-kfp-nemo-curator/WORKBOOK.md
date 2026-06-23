# WORKBOOK — {{PROJECT_NAME}}

Implementation guide for the 4 `USER CODE BLOCK` sections in `notebook.ipynb`.
Fill them in this order: `extract_text` → `quality_filter` → `deduplication` → `pii_redaction`.

After each block: run the **Build → `pipeline.py`** cell, then compile-check.

```sh
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

---

## 1. `extract_text` (CPU — `python:3.11-slim`)

Reads raw files from `curator-input/{project}/raw/`, normalizes text, writes
`curator-input/{project}/extracted/docs.jsonl`.

### Output record format

Every output record must have at least:
```json
{"id": "unique-string", "text": "cleaned document text", "source": "filename.txt"}
```

### txt / md files

```python
import ftfy
import pathlib

for file in in_dir.rglob("*"):
    if file.is_file() and file.suffix.lower() in (".txt", ".md"):
        raw = file.read_text(errors="replace")
        text = ftfy.fix_text(raw).strip()
        if not text:
            continue
        doc_id = file.stem
        records.append({"id": doc_id, "text": text, "source": file.name})
```

### html files

```python
import trafilatura

for file in in_dir.rglob("*.html"):
    raw = file.read_text(errors="replace")
    text = trafilatura.extract(raw) or ""
    text = text.strip()
    if not text:
        continue
    records.append({"id": file.stem, "text": text, "source": file.name})
```

### jsonl files

```python
import json

for file in in_dir.rglob("*.jsonl"):
    for i, line in enumerate(file.read_text().splitlines()):
        if not line.strip():
            continue
        record = json.loads(line)
        text = str(record.get(input_text_field, "")).strip()
        doc_id = str(record.get(input_id_field, f"{file.stem}-{i}"))
        if text:
            records.append({"id": doc_id, "text": text, "source": file.name})
```

### Write output

```python
out_path = out_dir / "docs.jsonl"
out_path.write_text("\n".join(json.dumps(r) for r in records))
```

### MLflow logging

```python
mlflow.log_metric("stage/extract_text/docs_in", n_in)
mlflow.log_metric("stage/extract_text/docs_out", len(records))
mlflow.log_metric("stage/extract_text/empty_skipped", n_empty)
```

---

## 2. `quality_filter` (GPU — `nvcr.io/nvidia/pytorch:26.04-py3`)

Reads `extracted/docs.jsonl`, applies NeMo Curator heuristic filters using the cuDF GPU backend,
writes `quality_filtered/docs.jsonl`.

### Load with cuDF backend

```python
from nemo_curator.datasets import DocumentDataset

dataset = DocumentDataset.read_json(str(in_dir / "docs.jsonl"), backend="cudf")
docs_in = len(dataset.df)
```

### Apply heuristic filters

```python
from nemo_curator.filters import (
    WordCountFilter,
    MeanWordLengthFilter,
    SymbolsToWordsFilter,
)
from nemo_curator import ScoreFilter, Sequential

# Word count derived from char counts (rough conversion)
min_words = max(1, min_doc_length // 6)
max_words = max_doc_length // 4

pipeline = Sequential([
    ScoreFilter(WordCountFilter(min_words=min_words, max_words=max_words),
                text_field="text", score_field="_wc"),
    ScoreFilter(MeanWordLengthFilter(min_mean_word_length, max_mean_word_length),
                text_field="text", score_field="_mwl"),
    ScoreFilter(SymbolsToWordsFilter(max_symbol_to_word_ratio),
                text_field="text", score_field="_swr"),
])

filtered = pipeline(dataset)
docs_out = len(filtered.df)
```

### Write output

```python
filtered.to_json(str(out_dir), write_to_filename=True)
# or:
import json
records = filtered.df.to_pandas().to_dict(orient="records")
(out_dir / "docs.jsonl").write_text("\n".join(json.dumps(r) for r in records))
```

### MLflow logging

```python
rejection_rate = 1.0 - (docs_out / docs_in) if docs_in > 0 else 0.0
mlflow.log_metric("stage/quality_filter/docs_in", docs_in)
mlflow.log_metric("stage/quality_filter/docs_out", docs_out)
mlflow.log_metric("stage/quality_filter/rejection_rate", rejection_rate)
```

---

## 3. `deduplication` (GPU — `nvcr.io/nvidia/pytorch:26.04-py3`)

Reads `quality_filtered/docs.jsonl`, runs exact dedup then fuzzy MinHash LSH dedup via cuDF,
writes `deduped/docs.jsonl`.

### Step 1 — Exact dedup (hash-based)

```python
from nemo_curator.datasets import DocumentDataset
from nemo_curator.modules import ExactDuplicates

dataset = DocumentDataset.read_json(str(in_dir / "docs.jsonl"), backend="cudf")
docs_in = len(dataset.df)

exact_dup = ExactDuplicates(id_field="id", text_field="text", hash_method="md5")
dup_ids = exact_dup(dataset)
# dup_ids is a DocumentDataset of duplicate IDs to remove
exact_removed = len(dup_ids.df)

import cudf
keep_mask = ~dataset.df["id"].isin(dup_ids.df["id"])
after_exact = DocumentDataset(dataset.df[keep_mask])
```

### Step 2 — Fuzzy dedup (MinHash LSH)

```python
from nemo_curator.modules import FuzzyDuplicates, FuzzyDuplicatesConfig

cache_dir = str(pvc_root / "curator-tmp" / project_name)

config = FuzzyDuplicatesConfig(
    id_field="id",
    text_field="text",
    seed=42,
    char_ngrams=fuzzy_ngram_size,
    num_buckets=fuzzy_num_hashes // 4,
    hashes_per_bucket=4,
    jaccard_threshold=fuzzy_jaccard_threshold,
    cache_dir=cache_dir,
)
fuzzy_dup = FuzzyDuplicates(config=config)
fuzzy_dup_ids = fuzzy_dup(after_exact)
fuzzy_removed = len(fuzzy_dup_ids.df) if fuzzy_dup_ids is not None else 0

keep_mask2 = ~after_exact.df["id"].isin(fuzzy_dup_ids.df["id"]) if fuzzy_removed else after_exact.df["id"].notna()
final = DocumentDataset(after_exact.df[keep_mask2])
docs_out = len(final.df)
```

### Write output

```python
import json
records = final.df.to_pandas().to_dict(orient="records")
(out_dir / "docs.jsonl").write_text("\n".join(json.dumps(r) for r in records))
```

### MLflow logging

```python
mlflow.log_metric("stage/deduplication/docs_in", docs_in)
mlflow.log_metric("stage/deduplication/exact_removed", exact_removed)
mlflow.log_metric("stage/deduplication/fuzzy_removed", fuzzy_removed)
mlflow.log_metric("stage/deduplication/docs_out", docs_out)
```

---

## 4. `pii_redaction` (CPU — `python:3.11-slim`)

Reads `deduped/docs.jsonl`, detects and redacts PII using presidio + spaCy,
writes `curated/docs.jsonl` (the final output).

### Option A — Via NeMo Curator PiiModifier

```python
from nemo_curator.datasets import DocumentDataset
from nemo_curator.modules.modify import PiiModifier

dataset = DocumentDataset.read_json(str(in_dir / "docs.jsonl"), backend="pandas")
modifier = PiiModifier(
    supported_entities=entities,
    anonymize_action=pii_action,  # "replace" maps to <ENTITY_TYPE> tags
    language="en",
    device="cpu",
)
redacted = modifier(dataset)
import json
records = redacted.df.to_dict(orient="records")
```

### Option B — Direct presidio (more control over output format)

```python
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine
import json

analyzer = AnalyzerEngine()
anonymizer = AnonymizerEngine()

records = []
n_pii = 0
for line in (in_dir / "docs.jsonl").read_text().splitlines():
    if not line.strip():
        continue
    rec = json.loads(line)
    results = analyzer.analyze(text=rec["text"], entities=entities, language="en")
    n_pii += len(results)
    if results:
        rec["text"] = anonymizer.anonymize(text=rec["text"], analyzer_results=results).text
    records.append(rec)
```

### Write output

```python
(out_dir / "docs.jsonl").write_text("\n".join(json.dumps(r) for r in records))
```

### MLflow logging

```python
mlflow.log_metric("stage/pii_redaction/docs_processed", len(records))
mlflow.log_metric("stage/pii_redaction/pii_instances_found", n_pii)
```

---

## Adding packages to the base images

All pipeline dependencies are pre-baked into `kfp-base-cpu:latest` and `kfp-base-gpu:latest`.
To add a new package:

1. Edit `kfp-images/cpu/Dockerfile` or `kfp-images/gpu/Dockerfile` in the platform repo
2. Trigger **Build KFP Base Images** (`image: cpu | gpu | both`)
3. No changes needed in project notebooks — they pull `:latest`

If a RAPIDS wheel is unavailable for arm64, check [pypi.nvidia.com](https://pypi.nvidia.com)
release notes for aarch64 availability before editing the GPU Dockerfile.
