# DGX JupyterLab Environment (pyJLab)

Dedicated pyenv environment for JupyterLab on the DGX Spark. Separate from `pyNeMo` so JupyterLab dependencies don't interfere with NeMo Microservices SDK pinning.

The `jupyterlab.service` systemd unit launches from this environment. See [`../systemd/`](../systemd/) to install or update the service.

## Setup

### 1. Create the pyenv

```bash
pyenv install 3.13     # if not already installed
pyenv virtualenv 3.13 pyJLab
pyenv activate pyJLab
```

### 2. Install PyTorch (CUDA 12.6, arm64)

Must be done before `requirements.txt` to get the right CUDA-enabled wheels:

```bash
pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu126
```

Verify GPU is visible:

```bash
python -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

### 3. Install everything else

```bash
pip install -r dgx/jupyterlab/requirements.txt
```

### 4. Apply the service

The `jupyterlab.service` unit already points to this environment. If you're doing this for the first time (or updating an existing install):

```bash
cd dgx/systemd
./install.sh
```

`install.sh` is idempotent — re-running it applies service file changes and restarts only the affected services.

## What's included

| Group | Packages |
|---|---|
| **JupyterLab** | `jupyterlab`, `jupyterlab-myst` (Markdown preview), `jupyterlab-git`, `jupyterlab-lsp` + `python-lsp-server` (completions), `jupyterlab-code-formatter` + `black` + `isort`, `ipywidgets`, `nbconvert` |
| **ML core** | `numpy`, `scipy`, `scikit-learn`, `pandas`, `matplotlib`, `seaborn`, `plotly` |
| **PyTorch** | `torch`, `torchvision`, `torchaudio` — installed separately (see above) |
| **HuggingFace / LLM** | `transformers`, `datasets`, `huggingface_hub`, `tokenizers`, `accelerate`, `peft`, `trl` |
| **NeMo** | `nemo-microservices` (client SDK) |
| **KFP** | `kfp` (Kubeflow Pipelines SDK) |
| **MLflow** | `mlflow` |
| **Eval** | `lm-eval[api]` |
| **NLP utilities** | `ftfy`, `beautifulsoup4`, `tiktoken` |
| **Utilities** | `requests`, `httpx`, `pyyaml`, `python-dotenv`, `tqdm`, `rich` |
| **Dev** | `pytest`, `pytest-asyncio` |

## Notes

- **`nemo-microservices` version** — the `NeMo Deploy` workflow pins this to the deployed NeMo chart version (e.g. `nemo-microservices==25.12.1`). After a NeMo upgrade, re-run `pip install nemo-microservices==<new-version>` in pyJLab to stay in sync.
- **Blackwell (sm_100) support** — PyTorch 2.5+ with `cu126` wheels supports sm_100. If you hit CUDA capability errors, confirm `torch.__version__` and that it was installed from the `cu126` index.
- **LSP completions** — `jupyterlab-lsp` requires a page reload after first install before completions appear.
