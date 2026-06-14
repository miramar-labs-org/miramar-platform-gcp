# Project Implementation Workbook

Everything a new project needs to implement before the pipeline can run.
Each item is a `# ---- USER CODE BLOCK ----` marker in the notebook or a file you fill in from scratch.

---

## 1. `config.yaml` — project configuration

Edit the top section to match your model and dataset:

```yaml
model:
  id: your-org/your-model     # HuggingFace model ID (must be cached on DGX)
datasets:
  - name: my-dataset          # must match keys in formatters.py and loaders.py
    hf_path: org/repo
    hf_config: null
```

Also review LoRA params, eval thresholds, and `judge_system_prompt` in `safety_eval`.

---

## 2. `formatters.py` — dataset formatters

One function per dataset. Return `{"instruction": str, "response": str, "source": str}`.
Register each in `FORMATTERS` with a key matching `config.yaml`.

```python
def format_my_dataset(example):
    return {
        "instruction": example["question"],
        "response": example["answer"],
        "source": "my-dataset",
    }

FORMATTERS = {
    "my-dataset": format_my_dataset,
}
```

---

## 3. `loaders.py` — dataset loaders

One lambda per dataset. Each returns a HuggingFace Dataset mapped through the formatter.
Register in `LOADERS` with the same key.

```python
from datasets import load_dataset

LOADERS = {
    "my-dataset": lambda: load_dataset("org/repo", split="train").map(format_my_dataset),
}
```

---

## 4. `eval_helpers.py` — answer extraction and prompt formatting

**`extract_answer(text)`** — parse the model's generated text into a canonical answer token
(e.g. `"a"`, `"yes"`, `"no"`). The default stub returns the first token; replace with logic
matching your dataset's answer format.

**`make_infer_fn(tokenizer, model, ...)`** — returns an `_infer(row)` closure. The default
stub returns `""`. Implement using your model's chat template and generation config. The
implementation is shared across `baseline_eval` and `post_finetune_eval`.

**`_make_user_content(row)`** — formats the user-turn string from a row dict. Used inside
`make_infer_fn`. Replace the default (`return row["instruction"]`) with any prefix/suffix
your model needs (system instructions, answer format hints, etc.).

---

## 5. `notebook.ipynb` — component implementations

### 5a. `baseline_eval` (Cell 6)

**Gap A** — model loading user code block: model and tokenizer are loaded by the scaffolding
(already present). The `make_infer_fn` call that wires `_infer` is also scaffolding — no user
code needed here unless you need a non-standard load path.

**Gap B** — accuracy comparison:
```python
generated = _infer(row)
# ---- USER CODE BLOCK ----
if extract_answer(generated) == extract_answer(row["response"]):
    correct += 1
# ---- END USER CODE BLOCK ----
```
Replace the TODO comment with real comparison logic using `extract_answer`.

### 5b. `fine_tune` (Cell 8)

**Gap A** — `to_chat()` definition:
```python
# ---- USER CODE BLOCK ----
def to_chat(rows):
    # Convert each row to the messages format expected by SFTTrainer.
    # Return a dict with a "messages" key: [{"role": ..., "content": ...}, ...]
    pass  # TODO
# ---- END USER CODE BLOCK ----
```
Implement using your model's chat template and the `instruction` / `response` fields.

### 5c. `post_finetune_eval` (Cell 10)

**Gap A** — model loading user code block: load the base model + PeftModel adapter from
`ft_model.path`. Uncomment and fill in the commented-out TODO lines:
```python
# ---- USER CODE BLOCK ----
# from transformers import AutoTokenizer, AutoModelForCausalLM
# from peft import PeftModel
# tokenizer = AutoTokenizer.from_pretrained(ft_model.path)
# model = AutoModelForCausalLM.from_pretrained(model_path, dtype=torch.bfloat16,
#     device_map="auto", max_memory={0: "100GiB"})
# model = PeftModel.from_pretrained(model, ft_model.path)
# model.eval()
# ---- END USER CODE BLOCK ----
```

**Gap B** — accuracy comparison: same as `baseline_eval` Gap B above.

### 5d. `baseline_safety_eval` (Cell 8)

Loads the base model (no adapter) and runs the same inline inference + judge loop as `safety_eval`.
`parse_score` is already available (injected from `utils.py`) — do not redefine it. `make_infer_fn`
is **not** in scope (no `EVAL_HELPERS_INJECT` marker) — load the model and call `generate` directly.
The only difference from `safety_eval`: no `PeftModel` and no `ft_model` input.

### 5e. `safety_eval` (Cell 14)

**Gap A** — model loading: load the fine-tuned model (base model + `PeftModel` adapter from
`ft_model.path`). `make_infer_fn` is **not** in scope — use inline generation. `parse_score`
is already available from `utils.py` injection.

**Gap B** — scoring loop: instantiate `client = OpenAI(base_url=judge_base_url, api_key="ollama")`,
run inline inference on a sample of `val_data`, call the judge LLM for each response, collect
scores into `scores`, compute `avg_score`.

---


## Implementation order

> `download_model`, `prepare_dataset`, and `deployment_gate` are fully implemented by the template.
> Everything below requires user code.

Work through these in order — each step depends on the previous one:

1. `config.yaml` — set model ID and dataset names
2. `formatters.py` + `loaders.py` — must compile before `prepare_dataset` can run
3. `eval_helpers.py` (`extract_answer`, `_make_user_content`) — needed by all eval steps
4. `baseline_eval` (Gap B) — get a baseline accuracy number before fine-tuning
5. `baseline_safety_eval` — inline inference + judge loop (no `make_infer_fn`; `parse_score` already in scope)
6. `fine_tune` (Gap A: `to_chat`) — train the adapter
7. `post_finetune_eval` (Gap A model loading + Gap B) — measure improvement
8. `safety_eval` (Gap A: model loading inline, Gap B: scoring loop) — gate before deployment

After implementing each step, run:
```sh
python3 scripts/build_pipeline.py
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
```

Then commit and deploy.
