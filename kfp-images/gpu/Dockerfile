FROM nvcr.io/nvidia/pytorch:26.04-py3

# Common deps for GPU KFP pipeline stages across all platform project types.
# Base image already includes: PyTorch, CUDA 12, cuDNN, NCCL, Python 3.11.

# NGC base images pin pyarrow via PIP_CONSTRAINT; clear it so RAPIDS and
# other packages can resolve their own compatible pyarrow version.
ENV PIP_CONSTRAINT=""

RUN pip install --no-cache-dir \
    --extra-index-url=https://pypi.nvidia.com \
    # RAPIDS GPU DataFrame stack (NeMo Curator GPU backend)
    cudf-cu12 \
    dask-cudf-cu12 \
    # NeMo Curator GPU: quality filtering, deduplication
    "nemo-curator>=0.5.0" \
    # HuggingFace stack (ft-eval training, eval; kfp-rag embedding)
    "transformers>=4.45,<5.0" \
    "peft>=0.13" \
    trl \
    # Embedding + vector search (kfp-rag embed_docs, retrieval_eval, generation_eval)
    "sentence-transformers>=3.0" \
    "qdrant-client>=1.9" \
    "langchain-text-splitters>=0.3" \
    # MLflow + S3/MinIO artifact support
    mlflow>=2.10.0 \
    boto3 \
    # Experiment tracking
    "wandb>=0.16"
