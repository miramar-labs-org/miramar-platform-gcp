#!/usr/bin/env bash
# Run list-model-profiles against your local model to validate NIM compatibility before deploying.
# Usage: bash scripts/list-profiles.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NIM_IMAGE_TAG=$(python3 -c "import yaml; c=yaml.safe_load(open('serving-config.yaml')); print(c['nim']['image_tag'])")
MODEL_HOST_PATH=$(python3 -c "import yaml; c=yaml.safe_load(open('serving-config.yaml')); print(c['model']['host_path'])")
MODEL_NAME=$(python3 -c "import yaml; c=yaml.safe_load(open('serving-config.yaml')); print(c['model']['container_name'])")

if [[ -z "${NGC_API_KEY:-}" ]]; then
  echo "ERROR: NGC_API_KEY is not set. Export it before running:" >&2
  echo "  export NGC_API_KEY=<your NGC API key>" >&2
  exit 1
fi

if [[ ! -d "$MODEL_HOST_PATH" ]]; then
  echo "ERROR: Model path not found: $MODEL_HOST_PATH" >&2
  exit 1
fi

echo "==> list-model-profiles"
echo "    Image:  nvcr.io/nim/nvidia/llm-nim:${NIM_IMAGE_TAG}"
echo "    Model:  ${MODEL_HOST_PATH}"
echo "    Mounted as: /models/${MODEL_NAME}"
echo ""

docker run --rm \
  --runtime=nvidia \
  --gpus all \
  -e NGC_API_KEY="${NGC_API_KEY}" \
  -e NIM_MODEL_NAME="/models/${MODEL_NAME}" \
  -v "${HOME}/shared/nim-cache:/opt/nim/.cache" \
  -v "${MODEL_HOST_PATH}:/models/${MODEL_NAME}:ro" \
  "nvcr.io/nim/nvidia/llm-nim:${NIM_IMAGE_TAG}" \
  list-model-profiles
