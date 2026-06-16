# WORKBOOK — {{PROJECT_NAME}}

Ordered checklist of every `USER CODE BLOCK` and helper file to fill in.
Check each item off as you complete it, then run the compile check before deploying.

---

## 0. Config and formatters (do first)

- [ ] **`config.yaml`** — set `model.id` (NeMo catalog), `model.hf_id` (HuggingFace), `nemo.base_url`, `datasets`, `training.*`, `eval.system_message`, `judge.*`
- [ ] **`formatters.py`** — add one formatter per dataset listed in `config.yaml`; register in `FORMATTERS`
- [ ] **`loaders.py`** — add one loader lambda per dataset; register in `LOADERS`
- [ ] Verify NeMo is running: `curl http://nemo.test:8082/v1/models`
- [ ] Verify your `model.id` is listed in the response above
- [ ] Run formatter tests: `python3 -m pytest tests/ -q`

---

## 1. `baseline_eval`

Identical to `ft-eval`. Load base model (`model.hf_id`), run inference on `val_data`,
compute your accuracy metric, log to MLflow.

- [ ] Implement `extract_answer(text)` in `eval_helpers.py`
- [ ] Implement `make_infer_fn(tokenizer, model, ...)` in `eval_helpers.py`
- [ ] Fill `baseline_eval` USER CODE BLOCK — compare generated answer to ground truth

```python
# Inside baseline_eval:
tokenizer = AutoTokenizer.from_pretrained(base_model_id)
model = AutoModelForCausalLM.from_pretrained(
    base_model_id, dtype=torch.bfloat16, device_map="auto", max_memory={0: "100GiB"})
model.eval()
# run inference on val_data using make_infer_fn, compute accuracy
mlflow.log_metric("baseline_accuracy", accuracy)
```

---

## 2. `baseline_safety_eval`

Identical to `ft-eval`. Load base model only (no adapter), run inference + judge loop.

- [ ] Fill `baseline_safety_eval` USER CODE BLOCK — model load + inference + judge scoring
- [ ] `parse_score` is already in scope (injected from `utils.py`) — do not redefine it

---

## 3. `fine_tune` (NeMo Customizer)

- [ ] Convert train data to NeMo JSONL format: `{"input": row["instruction"], "output": row["response"]}`
- [ ] Upload dataset to NeMo Data Store (use SDK or `requests` to POST to `/v1/datastore/files`)
- [ ] Create customization job: `client.customization.jobs.create(...)`
- [ ] Poll until `status == "completed"` — raise `RuntimeError` on `"failed"` or `"cancelled"`
- [ ] Download checkpoint artifact to `ft_model.path/`

```python
from nemo_microservices import NeMoMicroservices
client = NeMoMicroservices(base_url=nemo_base_url)

# 1. Format data
nemo_rows = [{"input": r["instruction"], "output": r["response"]} for r in train_data]
train_jsonl = "\n".join(json.dumps(r) for r in nemo_rows).encode()

# 2. Upload (consult NeMo SDK docs for the exact data store upload call)
# upload_resp = client.datastore.upload(path=f"{nemo_data_store_path}/{run_id}-train.jsonl", data=train_jsonl)
# dataset_ref = upload_resp.id

# 3. Create job
job = client.customization.jobs.create(
    name=f"{run_id}-finetune",
    model=base_model_id,         # NeMo catalog model name
    training_config={
        "num_epochs": num_epochs,
        "batch_size": batch_size,
        "learning_rate": learning_rate,
    },
    dataset={"train": {"file_id": dataset_ref}},
)

# 4. Poll
for _ in range(720):            # 1h timeout at 5s intervals
    j = client.customization.jobs.retrieve(job.id)
    print(f"  {j.status}")
    if j.status in ("completed", "failed", "cancelled"):
        break
    time.sleep(5)
if j.status != "completed":
    raise RuntimeError(f"NeMo job failed: {j.status}")

# 5. Download checkpoint to ft_model.path
# client.customization.jobs.download(job.id, output_dir=ft_model.path)
```

---

## 4. `export_adapter` (NeMo → HF PEFT)

- [ ] Locate `.nemo` checkpoint in `ft_model.path` (glob for `*.nemo`)
- [ ] Run `nemo2hf` conversion to produce HF PEFT format in `hf_adapter.path`
- [ ] Verify output contains `adapter_model.safetensors` and `adapter_config.json`

```python
import subprocess, pathlib
nemo_ckpt = next(pathlib.Path(ft_model.path).glob("*.nemo"), None)
if nemo_ckpt is None:
    raise RuntimeError(f"No .nemo checkpoint found in {ft_model.path}")

pathlib.Path(hf_adapter.path).mkdir(parents=True, exist_ok=True)
subprocess.run([
    "python3", "/opt/nemo/scripts/nemo2hf.py",
    "--input", str(nemo_ckpt),
    "--output", hf_adapter.path,
], check=True)

# Verify output
assert (pathlib.Path(hf_adapter.path) / "adapter_model.safetensors").exists(), \
    "export_adapter: adapter_model.safetensors not found — nemo2hf conversion failed"
```

Note: `nemo2hf.py` path may differ by NeMo version. Confirm the path in the NeMo NGC container:
```sh
find /opt/nemo -name "nemo2hf.py" 2>/dev/null
```

---

## 5. `post_finetune_eval`

Same as `ft-eval` but loads adapter from `hf_adapter` (the export_adapter output) instead of `ft_model`.

- [ ] Fill `post_finetune_eval` USER CODE BLOCK — load base model + PeftModel from `hf_adapter.path`

```python
from peft import PeftModel
tokenizer = AutoTokenizer.from_pretrained(base_model_id)
model = AutoModelForCausalLM.from_pretrained(
    base_model_id, dtype=torch.bfloat16, device_map="auto", max_memory={0: "100GiB"})
model = PeftModel.from_pretrained(model, hf_adapter.path)
model.eval()
```

---

## 6. `safety_eval`

Same as `ft-eval` but loads from `hf_adapter.path`.

- [ ] Fill `safety_eval` USER CODE BLOCK — load model + adapter + run judge loop
- [ ] `parse_score` is already in scope — do not redefine it

---

## 7. `deployment_gate`

Already implemented. Verify metric keys match what your eval steps log:
- `baseline_accuracy` (from `baseline_eval`)
- `postft_accuracy` (from `post_finetune_eval`)
- `safety_avg_score` (from `safety_eval`)
- `baseline_safety_avg_score` (from `baseline_safety_eval`)

---

## 8. Build and deploy

```sh
# Build
python3 scripts/build_pipeline.py

# Compile check
python3 -c "from kfp import compiler; from pipeline import pipeline; \
    compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"

# Formatter tests
python3 -m pytest tests/ -q

# Commit (pipeline.py is gitignored — only notebook.ipynb is committed)
git add notebook.ipynb config.yaml formatters.py loaders.py eval_helpers.py
git commit -m "feat: implement pipeline steps"
git push

# Deploy
gh workflow run deploy-to-kfp.yaml --field run_name=run-001
```
