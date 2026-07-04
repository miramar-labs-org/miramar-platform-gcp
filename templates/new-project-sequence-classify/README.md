# {{PROJECT_NAME}}

[![Open in JupyterLab](https://img.shields.io/badge/Open%20in-JupyterLab-F37626?logo=jupyter&logoColor=white)]({{JL_URL}})  [![last run](https://img.shields.io/badge/last%20run-pending-lightgrey)](runs/RUNS.md)

| | |
|---|---|
| **Type** | KFP v2 sequence-encoder classification pipeline |
| **Model** | [{{HF_MODEL_ID}}](https://huggingface.co/{{HF_MODEL_ID}}) |
| **Dataset** | [{{HF_DATASET_ID}}](https://huggingface.co/datasets/{{HF_DATASET_ID}}) |

{{DESCRIPTION}}

---

## 1. What this is

A config-driven classification fine-tuning pipeline for sequence-encoder models (BERT-style
encoders pre-trained on DNA, protein, or other biological sequences).

Unlike `kfp-ft-eval` (which generates text), this pipeline:
- Inputs a **raw sequence** (ATCG letters, amino acids, etc.)
- Outputs a **class probability** (e.g. pathogenic=0.87)
- Uses `AutoModelForSequenceClassification` — **no chat template, no text generation**
- Trains with HuggingFace `Trainer` — **no LoRA by default** (full fine-tune for small encoders)

**Pipeline DAG:**
```
download_model ──► prepare_dataset ──► baseline_eval ──► fine_tune ──► post_finetune_eval ──► deployment_gate
```

---

## 2. Two-phase transfer learning

**Phase 1 — Pre-training (already done by the model authors, not by this pipeline)**

The base model (e.g. DNABERT-2) was pre-trained on billions of raw sequence letters
using masked prediction: hide 15% of the input and ask the model to fill them in. No labels.
This teaches the encoder what the sequence space looks like — which patterns are common,
which regions are conserved, what structure exists.

After Phase 1, the model's `[CLS]` token embedding compresses everything it knows about a
sequence into a dense vector. This vector has no concept of "pathogenic" or "benign."
It only knows "DNA" (or protein, or RNA, depending on the model).

**Phase 2 — Classification fine-tuning (what this pipeline does)**

We attach a small linear classification head on top of the `[CLS]` embedding and train
the full system on labeled examples. After fine-tuning, the head has learned what
"pathogenic embedding" looks like in the encoder's representation space.

```
DNA sequence → [DNABERT-2 encoder] → [CLS] vector → [linear head] → pathogenic probability
```

The baseline evaluation (before fine-tuning) shows ~50% accuracy and AUC ~0.50 — the head
is randomly initialized and has never seen a label. This is the correct baseline. After
fine-tuning, the head learns the classification signal.

---

## 3. Quick start

1. Edit `config.yaml` — set `model.id`, `dataset.id`, `model.num_labels`, `eval` thresholds
2. Edit `processors.py` — add one processor function + loader lambda for your dataset
3. Open `notebook.ipynb` in JupyterLab and run the **Build → `pipeline.py`** cell
4. Compile check:
   ```sh
   python3 -c "from kfp import compiler; from pipeline import pipeline; \
       compiler.Compiler().compile(pipeline, '/tmp/p.yaml'); print('OK')"
   ```
5. Trigger **Deploy to KFP** from the Actions tab (or `python3 scripts/deploy_pipeline.py`)

---

## 4. config.yaml reference

| Key | Type | Description |
|-----|------|-------------|
| `model.id` | string | HuggingFace model ID |
| `model.type` | string | `sequence_classification` (always for this template) |
| `model.num_labels` | int | Number of classes (2 for binary, N for multi-class) |
| `dataset.id` | string | HuggingFace dataset path |
| `dataset.loader_key` | string | Key into `LOADERS` dict in `processors.py` (defaults to last segment of `dataset.id`) |
| `dataset.split_strategy` | string | `random` or `chromosome` |
| `dataset.test_chromosome` | string | Chromosome held out for test (chromosome split only) |
| `dataset.val_chromosome` | string | Chromosome held out for val (chromosome split only) |
| `training.max_length` | int | Max token length — sequences longer than this are truncated |
| `training.use_lora` | bool | `false` = full fine-tune; `true` = LoRA (for larger models) |
| `eval.sample_size` | int | Val rows sampled for baseline_eval |
| `eval.gate_accuracy_delta` | float | Min accuracy improvement (post-FT − baseline) |
| `eval.gate_auc_threshold` | float | Min post-FT AUC-ROC to pass gate |

---

## 5. Writing processors.py

One function per dataset. Return:
```python
{"sequence": str, "label": int, "source": str}
# Optionally for chromosome splits:
{"sequence": str, "label": int, "source": str, "chromosome": str}
```

Register in `PROCESSORS` and `LOADERS` with the same key.

---

## 6. MLflow

```sh
ssh -L 5000:localhost:5000 aaron@spark-79b7.local
# → http://localhost:5000  (use ML experiment type, not GenAI apps & agents)
```

---

## 7. Kubeflow Pipelines UI

```sh
ssh -L 8890:localhost:8890 aaron@spark-79b7.local
# → http://localhost:8890
```

Requires Kubeflow Deploy running (`kubeflow` namespace on DGX k3s).
