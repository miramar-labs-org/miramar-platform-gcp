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

## prepare_dataset

**Template default:** fully implemented — calls each loader from `loaders.py`, pools rows,
shuffles, and splits into train/val/test using `val_size` and `test_size` from config.

**What was filled in:** dataset-specific work lives in `formatters.py` and `loaders.py` above.
No changes to the `prepare_dataset` component body should be needed unless you require custom
split logic or preprocessing beyond the formatter.

<!-- If you did change prepare_dataset beyond the template default, describe it here. -->

---

## tests/test_formatters.py

**Template default:** empty `tests/` directory.

**What was filled in:**

<!-- Describe: what cases are covered per formatter, why those specific edge cases,
     and any data fixtures used. -->

TODO

---

## baseline_eval

**Template default:** `accuracy = 0.0` placeholder, logs to MLflow.

**What was filled in:**

<!-- Model loading strategy: full precision vs. quantized? device_map? torch_dtype?
     Inference approach: greedy decode, beam search, batch size?
     Metric: what does "accuracy" mean for this domain — exact match, F1, ROUGE, custom?
     MLflow metric key logged (must match what deployment_gate reads: "baseline_accuracy"). -->

TODO

---

## fine_tune

**Template default:** logs hyperparams to MLflow, no training.

**What was filled in:**

<!-- LoRA config: r, lora_alpha, target_modules, task_type.
     Training: batch size, gradient accumulation, scheduler, any memory optimizations (gradient checkpointing, fp16/bf16).
     How adapter is saved to ft_model.path.
     MLflow: what params and metrics are logged. -->

TODO

---

## post_finetune_eval

**Template default:** `accuracy = 0.0` placeholder, logs to MLflow.

**What was filled in:**

<!-- How the PEFT adapter is loaded on top of the base model.
     Same inference approach as baseline_eval? Any differences?
     MLflow metric key logged (must match deployment_gate: "postft_accuracy"). -->

TODO

---

## safety_eval

**Template default:** `avg_score = 0.0` placeholder, logs to MLflow.

**What was filled in:**

<!-- Judge model used (judge_model_id from config.yaml).
     Judge prompt design: what criteria, what scoring scale.
     How responses are generated from the fine-tuned model.
     How judge output is parsed into a numeric score.
     MLflow metric key logged (must match deployment_gate: "safety_avg_score"). -->

TODO

---

## deployment_gate

**Template default:** fully implemented — compares accuracy delta and safety score against
thresholds from config.yaml, raises RuntimeError on failure.

**What was updated:**

<!-- Were the metric keys changed from the defaults (baseline_accuracy, postft_accuracy,
     safety_avg_score)? Were the thresholds tuned from config.yaml defaults? -->

TODO
