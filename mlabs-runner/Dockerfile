FROM nvidia/cuda:12.6.3-cudnn-runtime-ubuntu22.04

ARG RUNNER_VERSION=2.334.0
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_USER=runner \
    RUNNER_HOME=/home/runner

# Runner runtime deps + general audio/video libs
# Pre-installs runner .NET deps explicitly so installdependencies.sh is not
# needed (running it under QEMU during arm64 cross-builds is unreliable).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        sudo \
        unzip \
        wget \
        zsh \
        lsb-release \
        apt-transport-https \
        gnupg \
        libssl3 \
        libkrb5-3 \
        zlib1g \
        libicu70 \
        ffmpeg \
        libsndfile1 \
        sox \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI (socket is mounted from the host at runtime)
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /usr/share/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu jammy stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl" \
        -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Install gcloud, terraform, and gh via their apt repos
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg && \
    CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")" && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" \
        > /etc/apt/sources.list.d/hashicorp.list && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y --no-install-recommends \
        google-cloud-cli \
        terraform \
        gh \
        make \
        python3 \
        python3-pip \
        python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

# Install helm
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install NGC CLI (arm64: v4.5.2, amd64: v3.41.3)
RUN case "${TARGETARCH}" in \
        amd64) ZIP_NAME="ngccli_linux.zip";  NGC_VER="3.41.3" ;; \
        arm64) ZIP_NAME="ngccli_arm64.zip";  NGC_VER="4.5.2"  ;; \
        *) echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fL --retry 5 --retry-delay 2 \
        -o /tmp/ngccli.zip \
        "https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions/${NGC_VER}/files/${ZIP_NAME}" && \
    unzip -q /tmp/ngccli.zip -d /tmp/ngccli && \
    cp -a /tmp/ngccli/ngc-cli /opt/ngc-cli && \
    ln -sf /opt/ngc-cli/ngc /usr/local/bin/ngc && \
    chmod +x /usr/local/bin/ngc && \
    rm -rf /tmp/ngccli.zip /tmp/ngccli

LABEL org.opencontainers.image.version="${RUNNER_VERSION}"

# PyTorch with CUDA 12.6
# amd64: explicit CUDA wheels from pytorch.org; arm64: standard PyPI (ships CUDA-enabled for aarch64)
RUN case "${TARGETARCH}" in \
        amd64) pip3 install --no-cache-dir \
                   torch torchvision torchaudio \
                   --index-url https://download.pytorch.org/whl/cu126 ;; \
        arm64) pip3 install --no-cache-dir \
                   torch torchvision torchaudio ;; \
    esac

# HuggingFace ecosystem + genAI + ML tooling
RUN pip3 install --no-cache-dir --upgrade \
    transformers \
    accelerate \
    peft \
    huggingface_hub \
    diffusers \
    optimum \
    evaluate \
    sentence-transformers \
    timm \
    einops \
    bitsandbytes \
    datasets \
    numpy \
    scipy \
    pandas \
    scikit-learn \
    tqdm \
    pillow \
    tensorboard \
    mlflow \
    onnx \
    onnxscript \
    boto3 \
    s3fs \
    dill \
    pytest

RUN useradd -m -s /bin/bash runner \
    && echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

WORKDIR /home/runner

RUN case "${TARGETARCH}" in \
        amd64) RUNNER_ARCH="x64" ;; \
        arm64) RUNNER_ARCH="arm64" ;; \
        *) echo "Unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    curl -fsSL \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz" \
        -o runner.tar.gz \
    && tar xzf runner.tar.gz \
    && rm runner.tar.gz

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN chown -R runner:runner /home/runner

USER runner

ENTRYPOINT ["/entrypoint.sh"]
