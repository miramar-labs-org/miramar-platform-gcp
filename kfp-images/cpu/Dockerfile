FROM python:3.11-slim

# Common deps for CPU KFP pipeline stages across all platform project types.
# Install in one layer to minimize image size.

RUN pip install --no-cache-dir \
    # MLflow + S3/MinIO artifact support (boto3 required for log_dict/log_artifact)
    mlflow>=2.10.0 \
    boto3 \
    # NeMo Curator (CPU): text extraction, quality filtering, PII redaction
    "nemo-curator>=0.5.0" \
    trafilatura>=1.10.0 \
    ftfy>=6.1.0 \
    # PII redaction (presidio + spaCy)
    "presidio-analyzer>=2.2.0" \
    "presidio-anonymizer>=2.2.0" \
    "spacy>=3.7.0" \
    # LLM API clients (kfp-rag judges, safety eval)
    "openai>=1.30.0" \
    requests \
    # HuggingFace ecosystem (ft-eval data prep, model download)
    "huggingface_hub>=0.21" \
    "datasets>=2.0,<3.0" \
    # Experiment tracking
    "wandb>=0.16" \
    pyyaml

# Download spaCy en_core_web_sm (pii_redaction; avoids subprocess download at runtime)
RUN python -m spacy download en_core_web_sm
