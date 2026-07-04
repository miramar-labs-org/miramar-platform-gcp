# Project Implementation Workbook

Everything needed to implement a new sequence-classify project.
Unlike `kfp-ft-eval`, this template requires only **one file** of user code: `processors.py`.
All pipeline components (`download_model`, `prepare_dataset`, `baseline_eval`, `fine_tune`,
`post_finetune_eval`, `deployment_gate`) are fully implemented by the template.

---

## Understanding the two-phase concept

Before writing any code, understand what you are and aren't doing.

**What pre-training did (Phase 1 — not your job):**

The base model authors trained on raw unlabeled sequences. For DNABERT-2, this was the
entire human reference genome (~3 billion base pairs) plus genomes from 135 other species,
using masked language modeling: randomly hide 15% of nucleotides, ask the model to fill them
in. No labels. No task. Just "learn the distribution of DNA." After pre-training, the model's
`[CLS]` token embedding captures rich sequence patterns — codon structure, splice sites,
conserved regulatory motifs — without any concept of "pathogenic" or "benign."

**What fine-tuning does (Phase 2 — your job):**

You attach a small linear classification head on top of the `[CLS]` embedding and train
on labeled examples. The head maps a 768-dimensional embedding to `num_labels` output logits.
The loss is standard cross-entropy. The fine-tuning phase teaches the head what the
"pathogenic cluster" looks like in the pre-trained embedding space.

Why does this work? The pre-trained encoder already encodes functional genomic information
that correlates with pathogenicity — variant position within coding regions, proximity to
splice sites, conservation patterns. The head learns to separate these signals from benign
background variation. Without Phase 1 pre-training, the head would need to learn these
patterns from scratch, which requires much more data.

**Why the baseline is ~50% (not the model's "knowledge"):**

The baseline evaluation loads the pre-trained encoder with a **randomly initialized** head.
The encoder outputs a rich embedding, but the head has never seen a label — it produces random
logits. Expected baseline: accuracy ≈ 50% for binary classification, AUC ≈ 0.50. This is
intentional. The large delta after fine-tuning (from ~50% to ~80%+) demonstrates that the
pre-trained encoder provides useful features the head can learn from quickly.

Compare this to `kfp-ft-eval`: there, the baseline is the model's *pre-trained zero-shot
knowledge* (e.g. MedGemma knows medical content before fine-tuning → 75% baseline).
Here, the baseline is purely random because the classification head is new.

---

## 1. `config.yaml` — project configuration

```yaml
model:
  id: zhihan1996/DNABERT-2-117M   # HuggingFace model ID
  type: sequence_classification
  num_labels: 2                    # 2 for pathogenic/benign binary classification

dataset:
  id: wanglab/variant_effect_coding
  loader_key: variant_effect_coding  # must match a key in processors.py LOADERS
  split_strategy: chromosome         # chromosome = held-out chr for test
  test_chromosome: chr22
  val_chromosome: chr21

training:
  batch_size: 32
  num_epochs: 3
  max_length: 512
  use_lora: false   # full fine-tune for 117M model

eval:
  sample_size: 500
  gate_accuracy_delta: -0.02
  gate_auc_threshold: 0.70
```

---

## 2. `processors.py` — the only file you need to edit

### Processor function

Maps one raw HuggingFace dataset row → `{"sequence", "label", "source"}`:

```python
def process_my_dataset(example):
    return {
        "sequence":   str(example["seq"]),        # raw nucleotide/amino acid string
        "label":      int(example["is_positive"]), # 0 = negative, 1 = positive
        "source":     "my-dataset",
        "chromosome": str(example.get("chrom", "unknown")),  # optional, for chromosome split
    }
```

Register in `PROCESSORS` with the same key you'll use in `config.yaml`:
```python
PROCESSORS = {"my-dataset": process_my_dataset}
```

### Loader lambda

Zero-arg callable returning an iterable of processed rows:
```python
from datasets import load_dataset
LOADERS = {
    "my-dataset": lambda: (
        load_dataset("org/my-dataset", split="train")
        .map(process_my_dataset)
        .filter(lambda x: len(x["sequence"]) > 0)
    )
}
```

### For chromosome-based splits

The processor must output `"chromosome"` field. The `prepare_dataset` component reads
`config.yaml.dataset.test_chromosome` and `val_chromosome` and filters rows accordingly.
Use a chromosome that's biologically representative but not in the training distribution:
- `chr22`: shortest autosome, gene-dense, well-annotated → good test chromosome
- `chr21`: second shortest → good val chromosome

Never use `chr1` or `chr2` as test/val — too much data lost from training.

---

## 3. Implementation order

1. `config.yaml` — set model ID, dataset ID, num_labels, split strategy
2. `processors.py` — write processor + loader, run `python3 -m pytest tests/ -q`
3. Run **Build → `pipeline.py`** cell in the notebook
4. Compile check: `python3 -c "from kfp import compiler; from pipeline import pipeline; compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"`
5. Commit and deploy

There are **no user code blocks** in the notebook — all 6 pipeline stages are fully implemented.
The only implementation work is in `processors.py`.

---

## 4. Eval metrics

**Accuracy** — fraction of correctly classified sequences. Simple but misleading on imbalanced
datasets (if 90% of sequences are benign, a model that always predicts benign has 90% accuracy).

**AUC-ROC** — area under the receiver operating characteristic curve. Measures the model's
ability to rank positive (pathogenic) sequences above negative (benign) ones, at all possible
classification thresholds. Ranges from 0.5 (random) to 1.0 (perfect). AUC-ROC is the primary
metric for imbalanced classification tasks.

The deployment gate checks **both**:
- `accuracy_delta >= gate_accuracy_delta` (post-FT accuracy ≥ baseline − 0.02; i.e., don't regress)
- `postft_auc >= gate_auc_threshold` (absolute AUC floor, e.g. 0.70)

---

## 5. Implementation Notes — run history

<!-- Filled in after each run by the developer -->
