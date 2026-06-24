FROM nvcr.io/nvidia/pytorch:26.04-py3

ARG TRTLLM_VERSION=0.18.2

RUN pip install --no-cache-dir \
    tensorrt-llm==${TRTLLM_VERSION} \
    --extra-index-url https://pypi.nvidia.com

# Smoke-check: import succeeds (no GPU needed at build time)
RUN python3 -c "import tensorrt_llm; print('tensorrt_llm', tensorrt_llm.__version__)"
