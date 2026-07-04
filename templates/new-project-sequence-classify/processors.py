"""
processors.py — sequence classification dataset processors.

This is the only file you need to edit for a new dataset.

## Your task

1. Write one processor function per dataset — maps a raw HuggingFace row to:
   {"sequence": str, "label": int, "source": str}
   Optionally add "chromosome": str if using split_strategy: chromosome in config.yaml.

2. Register it in PROCESSORS (maps name → function).

3. Write one loader lambda per dataset — returns an iterable of processed rows.
   Register it in LOADERS (maps loader_key → zero-arg callable).

The loader_key in config.yaml.dataset.loader_key must match a key in LOADERS.
If loader_key is null in config.yaml, it defaults to the last segment of dataset.id.

## Data format

Every row written to train/val/test must have at minimum:
  {"sequence": "ATCGATCG...", "label": 0_or_1, "source": "dataset-name"}

For chromosome-based splits (split_strategy: chromosome), also include:
  {"sequence": "ATCGATCG...", "label": 0_or_1, "source": "dataset-name", "chromosome": "chr3"}

Labels must be integers. For binary classification: 0 = negative/benign, 1 = positive/pathogenic.

## Example: wanglab/variant_effect_coding (DNABERT-2 + ClinVar experiment)

  Dataset: 48,850 train / 1,233 test rows. ~78% Benign (label=0), ~22% Pathogenic (label=1).
  Actual HF schema: {"ID", "question", "answer", "reference_sequence", "variant_sequence"}
  Label derived from answer: starts with "Benign" → 0, "Pathogenic; ..." → 1.
  Input sequence: variant_sequence (200bp DNA window around the variant).
  Split strategy: random — the dataset has no chromosome field.

  Verify a HuggingFace dataset's actual schema (`load_dataset(...).features`) before writing
  a processor — card descriptions often don't match the real column names.
"""

from datasets import load_dataset


# ---------------------------------------------------------------------------
# Processor functions — one per dataset
# ---------------------------------------------------------------------------

def process_variant_effect_coding(example):
    """Process wanglab/variant_effect_coding row.

    Actual schema: {"ID": str, "question": str, "answer": str,
                    "reference_sequence": str, "variant_sequence": str}
    - answer "Benign" → label 0
    - answer "Pathogenic; <disease>" → label 1
    - variant_sequence: 200bp DNA window containing the variant
    """
    answer = str(example.get("answer", "")).strip()
    label = 0 if answer.startswith("Benign") else 1
    return {
        "sequence":   str(example.get("variant_sequence", "")),
        "label":      label,
        "source":     "variant_effect_coding",
        "chromosome": "unknown",
    }


# ---------------------------------------------------------------------------
# PROCESSORS dict — maps dataset name → processor function
# ---------------------------------------------------------------------------

PROCESSORS = {
    "variant_effect_coding": process_variant_effect_coding,
}


# ---------------------------------------------------------------------------
# LOADERS dict — maps loader_key → zero-arg callable returning processed rows
# ---------------------------------------------------------------------------

LOADERS = {
    "variant_effect_coding": lambda: (
        load_dataset("wanglab/variant_effect_coding", split="train")
        .map(process_variant_effect_coding)
        .filter(lambda x: len(x["sequence"]) > 0)
    ),
}
