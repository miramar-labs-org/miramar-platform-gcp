# Implementation Notes

This document describes each gap filled in when scaffolding this project from the
`kfp-ft-eval` template and the reasoning behind each choice. Fill it in as you
implement each section.

---

## config.yaml

**Template default:** placeholder model ID, single example dataset, minimal LoRA/training params.

**What was filled in:**

<!-- Describe: model choice and why, dataset selection and why, any non-default LoRA/training
     params and the reasoning (memory constraints, convergence, etc.), eval thresholds. -->

TODO

---

## formatters.py

**Template default:** a single stub `format_example` returning `question`/`answer` keys.

**What was filled in:** <!-- N --> formatter functions, one per dataset.

<!-- For each formatter: describe the dataset's raw schema, any format variations that had
     to be handled, and the instruction/response structure chosen and why. -->

TODO

---

## prepare_dataset (notebook cell)

**Template default:** a `for name in dataset_names: pass` loop with a TODO comment.

**What was filled in:**

<!-- Describe: how datasets are loaded (HuggingFace paths, configs, splits), any
     preprocessing beyond the formatter, and the train/val/test split strategy. -->

TODO

---

## tests/test_formatters.py

**Template default:** empty `tests/` directory.

**What was filled in:**

<!-- Describe: what cases are covered per formatter, why those specific edge cases,
     and any data fixtures used. -->

TODO

---

## Step implementations (baseline_eval, fine_tune, post_finetune_eval, safety_eval)

**Template default:** placeholder `accuracy = 0.0` / `avg_score = 0.0` bodies with TODO comments.

**What was filled in:**

<!-- For each step implemented beyond the placeholder: describe the model loading strategy
     (full precision vs. quantized, device_map, etc.), inference approach, metric computation,
     and any performance or memory tradeoffs made. -->

TODO
