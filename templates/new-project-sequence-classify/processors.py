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

  Dataset: 50K ClinVar pathogenic (label=1) + gnomAD benign (label=0) sequences.
  Each row: {"sequence": ATCG string, "label": int, "chrom": chromosome string}
  Split strategy: chromosome — hold out chr22 (test) and chr21 (val).

  Processor output adds "chromosome" field for the chromosome-based split in prepare_dataset.
"""

from datasets import load_dataset


# ---------------------------------------------------------------------------
# Processor functions — one per dataset
# ---------------------------------------------------------------------------

def process_variant_effect_coding(example):
    """Process wanglab/variant_effect_coding row.

    Raw schema: {"sequence": str, "label": int, "chrom": str, ...}
    - label 0 = benign  (gnomAD common variants)
    - label 1 = pathogenic (ClinVar pathogenic/likely pathogenic)
    - chrom  e.g. "chr3", "chrX" — used for chromosome-based split
    """
    return {
        "sequence":   str(example.get("sequence", "")),
        "label":      int(example.get("label", 0)),
        "source":     "variant_effect_coding",
        "chromosome": str(example.get("chrom", "unknown")),
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
