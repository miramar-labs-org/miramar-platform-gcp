# CLAUDE.md

## What this repo is

{{PROJECT_NAME}} — a KFP v2 sequence-encoder classification pipeline on the Miramar platform (DGX Spark).

<!-- Replace the line above with a one-sentence description. -->

## Key files

| File | Purpose |
|------|---------|
| `config.yaml` | Project config — model ID, dataset, num_labels, split strategy, eval thresholds |
| `processors.py` | Dataset processors — one function per dataset, registered in `PROCESSORS` + `LOADERS` dicts |
| `utils.py` | Shared helpers (AUC computation) — injected into eval components via `# <<< UTILS_INJECT >>>` |
| `notebook.ipynb` | Source of truth — component implementations; run the Build cell to regenerate `pipeline.py` |
| `pipeline.py` | Generated from notebook — **do not edit manually** (gitignored) |
| `WORKBOOK.md` | Implementation guide — two-phase concept, processors.py patterns, eval metrics |
| `scripts/deploy_pipeline.py` | Compile, register, and submit a run (called by Deploy to KFP workflow) |
| `scripts/terminate_pipeline.py` | Terminate a run by ID (called by Undeploy from KFP workflow) |
| `runs/RUNS.md` | Run history |
| `runs/run-NNN.md` | Periodic status log for run NNN, written by `/kfp-monitor` |

## Slash commands

| Command | What it does |
|---------|-------------|
| `/kfp-deploy [run-NNN]` | Deploy next run, create `runs/run-NNN.md` |
| `/kfp-monitor [run-NNN]` | Self-paced monitoring loop — checks pods + MLflow, appends to `runs/run-NNN.md` |

Full docs: [miramar-platform-gcp/docs/kfp-skills.md](https://github.com/miramar-labs-org/miramar-platform-gcp/blob/main/docs/kfp-skills.md)

## Two-phase transfer learning — what this pipeline does

This pipeline implements the **second phase** of transfer learning for sequence encoders.

**Phase 1 (pre-training, done by model authors, not this pipeline):**
The base model was pre-trained on raw unlabeled sequences using masked prediction.
For DNABERT-2: ~3B nucleotides, masked language modeling task, no labels.
The model learns to encode sequence structure into a dense embedding.

**Phase 2 (classification fine-tuning, this pipeline):**
We attach a randomly initialized linear classification head on top of the `[CLS]` token embedding
and train the full model (encoder + head) on labeled examples from our dataset.
The head learns to map the pre-trained embeddings to class probabilities.

**Key implication — baseline accuracy:**
The baseline evaluation runs BEFORE fine-tuning. The classification head is random → baseline
accuracy ≈ 50% and AUC ≈ 0.50 for binary classification. This is the correct and expected
baseline. The delta to post-FT accuracy is the meaningful signal.

## Data format

All pipeline steps receive data as JSONL files where every row is:
```json
{"sequence": "ATCGATCG...", "label": 1, "source": "dataset-name"}
```
For chromosome-based splits, rows also contain:
```json
{"sequence": "ATCGATCG...", "label": 1, "source": "dataset-name", "chromosome": "chr3"}
```

## Writing processors.py

Each processor function:
```python
def process_my_dataset(example):
    return {
        "sequence":   str(example["seq"]),
        "label":      int(example["label"]),
        "source":     "my-dataset",
        "chromosome": str(example.get("chrom", "unknown")),  # optional
    }
```

Register in both dicts with the same key as `config.yaml.dataset.loader_key`:
```python
PROCESSORS = {"my-dataset": process_my_dataset}
LOADERS = {"my-dataset": lambda: load_dataset(...).map(process_my_dataset)}
```

The Build cell inlines the entire `processors.py` file into the `prepare_dataset` component
body at the `# <<< PROCESSORS_INJECT >>>` marker.

## Adding a new dataset

1. Add processor function to `processors.py` and register in `PROCESSORS` + `LOADERS`
2. Update `config.yaml`: set `dataset.id`, `dataset.loader_key`, and `dataset.split_strategy`
3. Run Build cell → compile check → deploy

## Pipeline stages (all fully implemented — no user code blocks in notebook)

| Stage | What it does |
|-------|-------------|
| `download_model` | Snapshot-download base encoder weights from HuggingFace Hub |
| `prepare_dataset` | Load + process rows via `processors.py`; split by chromosome or random |
| `baseline_eval` | Load pre-trained encoder + **random head**; compute accuracy + AUC on val set. Expected: ~50% acc, ~0.50 AUC |
| `fine_tune` | Train encoder + classification head with `Trainer`; saves model to `ft_model.path` |
| `post_finetune_eval` | Load fine-tuned model; compute accuracy + AUC on held-out test set |
| `deployment_gate` | Check accuracy delta ≥ threshold AND AUC ≥ threshold; raise on failure |

## Edit → build → deploy cycle

```sh
# 1. Edit processors.py or notebook.ipynb
python3 scripts/build_pipeline.py
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
python3 -m pytest tests/ -q
git add processors.py && git commit -m "feat: add processor for <dataset>"
git push

# 2. Deploy
gh workflow run deploy-to-kfp.yaml --field run_name=run-001
```

## Component rules

- **All imports must be inside the function body** — each component runs in its own container
- `packages_to_install` on `@dsl.component` is the only way to add dependencies
- GPU steps: `.set_gpu_limit(1).set_memory_limit("64G")` in the pipeline cell
- Secret env vars (HF_TOKEN, etc.) are injected from the `mlabs-api-keys` K8s secret

## Model construction pattern (all three eval/train components)

Models are built via `AutoConfig.from_pretrained(...)` + `AutoModelForSequenceClassification
.from_config(...)`, then the state dict is loaded manually — **not** a single
`from_pretrained(..., num_labels=...)` call. This is required for `trust_remote_code=True`
models (DNABERT-2 and similar) whose bundled custom code:
- may reference config attributes (e.g. `pad_token_id`) not present in `config.json` —
  patched onto the loaded `AutoConfig` object before model construction
- may bundle a custom attention path (e.g. a vendored `flash_attn_triton.py`) that imports
  cleanly but crashes on first forward pass against the installed Triton version — after
  `from_config(...)`, the component scans `sys.modules` for the loaded custom module and nulls
  out its flash-attention function so it falls back to standard PyTorch attention

If you swap in a different `trust_remote_code` sequence-encoder model, check whether it has
similar bundled-attention or config-attribute assumptions before assuming `from_pretrained`
alone will work.

## Compile check

```sh
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

## KFP UI

```sh
ssh -L 8890:localhost:8890 aaron@spark-79b7.local
# → http://localhost:8890
```

## MLflow

```sh
ssh -L 5000:localhost:5000 aaron@spark-79b7.local
# → http://localhost:5000  (use ML experiment type, not GenAI apps & agents)
```

## Platform repo

[miramar-labs-org/miramar-platform-gcp](https://github.com/miramar-labs-org/miramar-platform-gcp)
