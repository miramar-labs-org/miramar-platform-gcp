# Troubleshooting

Platform-level issues common to all `kfp-ft-eval` projects. For project-specific
debugging history, keep a `TROUBLESHOOTING.md` in the project repo itself.

---

## PermissionError on HuggingFace `.locks/` directory

### Symptom

```
PermissionError: [Errno 13] Permission denied:
  '/root/.cache/huggingface/hub/.locks/models--<org>--<model>/...'
```

### Cause

Passing a Hub model ID string to `AutoModelForCausalLM.from_pretrained()` triggers
`hf_hub_download`, which tries to create `.locks/` inside the HF cache PVC. The PVC
is mounted via minikube's 9p userspace file server. The pod (uid=0) maps to "other"
on the host filesystem — no write permission on the cache root.

### Fix

Use `_local_model_path()` to resolve the snapshot directory first and pass a local
path instead. This bypasses `hf_hub_download` entirely:

```python
def _local_model_path(model_id):
    cache = pathlib.Path("/root/.cache/huggingface/hub")
    key = model_id.replace("/", "--")
    commit = (cache / f"models--{key}" / "refs" / "main").read_text().strip()
    return str(cache / f"models--{key}" / "snapshots" / commit)

model_path = _local_model_path(base_model_id)
tokenizer = AutoTokenizer.from_pretrained(model_path)
model = AutoModelForCausalLM.from_pretrained(model_path, ...)
```

This helper is pre-wired into all model cells in the scaffold.

---

## `InvalidHeaderLength` loading model shards (9p symlink bug)

### Symptom

```
safetensors_rust.SafetensorError: Error while deserializing header: InvalidHeaderLength
```

Shard files appear as 76 bytes inside the pod instead of their actual multi-GB size.

### Cause

The HuggingFace cache populates snapshot directories with **symlinks** pointing to
content-addressed blobs. minikube's 9p userspace server does **not** follow symlinks
— it serves the symlink target path text as file content (~76 bytes). Safetensors
reads that string as a binary header, which is invalid.

### Fix

Replace all symlinks in the snapshot directory with **hard links** on the host:

```bash
SNAP="/home/aaron/shared/huggingface-kfp/hub/models--<org>--<model>/snapshots/<hash>"
BLOBS="/home/aaron/shared/huggingface-kfp/hub/models--<org>--<model>/blobs"

for f in "$SNAP"/*; do
    if [ -L "$f" ]; then
        target=$(readlink -f "$f")
        rm "$f" && ln "$target" "$f"
    fi
done
```

Hard links are directory entries pointing to the same inode — no symlink for 9p to
misread. This fix is permanent; hard links survive minikube restarts.

**Verify** inside any running pod:
```bash
ls -lh /root/.cache/huggingface/hub/models--<org>--<model>/snapshots/<hash>/
# Shard files should show their real size (GBs), not 76 bytes
```

Run this after every `huggingface-cli download` — new downloads always create symlinks.

---

## `bitsandbytes` 4-bit broken on Blackwell (DGX Spark GB10, sm_100)

### Symptom

Model loads without error but generates only empty strings. Accuracy is 0.0000
across the entire eval set. No CUDA errors in logs.

### Cause

`bitsandbytes` ≤ 0.49.x does not ship compiled CUDA kernels for sm_100 (Blackwell).
At inference time it silently falls back to a broken path, producing garbage logits.
With greedy decoding (`do_sample=False`), the model immediately emits the
`<end_of_turn>` EOS token as its first output → empty generation → 0.0000 accuracy.

The same issue affects training: QLoRA fine-tuning with `load_in_4bit=True` will
produce corrupt forward/backward passes and a useless adapter.

### Fix

**Do not use `BitsAndBytesConfig` or `load_in_4bit` on DGX Spark.** Load models
in BF16 instead:

```python
# ✗ broken on Blackwell
from transformers import BitsAndBytesConfig
bnb = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_compute_dtype=torch.bfloat16)
model = AutoModelForCausalLM.from_pretrained(path, quantization_config=bnb, device_map="auto")

# ✓ correct
model = AutoModelForCausalLM.from_pretrained(path, dtype=torch.bfloat16, device_map="auto")
```

For fine-tuning, use **standard LoRA** (not QLoRA). Remove `prepare_model_for_kbit_training`.
A 27B BF16 model uses ~54 GB; 128 GB unified memory on the DGX Spark handles this
comfortably with gradient checkpointing.

---

## `SFTTrainer` unexpected keyword argument `tokenizer` (trl 0.29.x API break)

### Symptom

```
TypeError: SFTTrainer.__init__() got an unexpected keyword argument 'tokenizer'
```

### Cause

`trl>=0.14.0,<1.0` resolves to trl 0.29.x, which renamed several parameters:

| Old API (< 0.29) | New API (≥ 0.29) |
|---|---|
| `SFTTrainer(tokenizer=tok)` | `SFTTrainer(processing_class=tok)` |
| `SFTTrainer(max_seq_length=N)` | `SFTConfig(max_seq_length=N)` |
| `TrainingArguments(...)` | `SFTConfig(...)` |

### Fix

```python
from trl import SFTTrainer, SFTConfig

training_args = SFTConfig(output_dir=..., max_seq_length=2048, ...)
trainer = SFTTrainer(model=model, processing_class=tokenizer, args=training_args, ...)
```

---

## `PIP_CONSTRAINT` blocks `pyarrow` upgrade in NGC containers

### Symptom

`trl` / `datasets` installation fails or produces version conflicts involving `pyarrow`.

### Cause

NGC PyTorch containers ship `/etc/pip/constraint.txt` pinning `pyarrow==19.0.1`.
pip respects this file via the `PIP_CONSTRAINT` environment variable.

### Fix

Clear the constraint before running pip inside the component:

```python
import subprocess, sys, os

env = {**os.environ, "PIP_CONSTRAINT": ""}
subprocess.run(
    [sys.executable, "-m", "pip", "install", "pyarrow>=21.0.0", "trl>=0.14.0,<1.0", ...],
    check=True, env=env,
)
```

You will see harmless warnings about `cudf` and `pylibcudf` expecting an older pyarrow.
These libraries are unused in pipeline components — ignore the warnings.

---

## Operational notes

### Purge KFP state between runs

```bash
python3 scripts/purge_kfp.py
```

Always run this before re-deploying. Failed runs leave dangling pipeline records that
cause name collisions on the next upload.

### Watch a component's logs

```bash
kubectl get pods -n kubeflow | grep <pipeline-name>
kubectl logs -n kubeflow <pod-name> -c main -f
```

Components that do `subprocess pip install` first will be silent for 2–5 minutes
before producing useful output. Watch for `Successfully installed ...` as the signal
that real work is starting.
