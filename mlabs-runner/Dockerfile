FROM debian:bookworm-slim

ARG RUNNER_VERSION=2.335.1
ARG TARGETARCH

ARG SHFMT_VERSION=3.10.0
ARG HADOLINT_VERSION=2.12.0
ARG ACTIONLINT_VERSION=1.7.7

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_USER=runner \
    RUNNER_HOME=/home/runner

# Core deps + .NET runtime deps (libicu72 = Bookworm's ICU) + mDNS
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        sudo \
        unzip \
        wget \
        lsb-release \
        apt-transport-https \
        gnupg \
        libssl3 \
        libkrb5-3 \
        zlib1g \
        libicu72 \
        openssh-client \
        zstd \
        python3 \
        python3-pip \
        python-is-python3 \
        shellcheck \
        yamllint \
        libnss-mdns \
    && sed -i 's/^\(hosts:.*\)dns\s*$/\1mdns4_minimal [NOTFOUND=return] dns/' /etc/nsswitch.conf \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI (Debian Bookworm repo)
RUN curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /usr/share/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
        https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl" \
        -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# gcloud, terraform, gh
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
    && rm -rf /var/lib/apt/lists/*

# helm
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Node 20 LTS + prettier (repo-quality workflow)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g prettier && \
    node --version && prettier --version

# shfmt
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) SHFMT_ARCH="amd64" ;; \
        arm64) SHFMT_ARCH="arm64" ;; \
        *) echo "Unsupported arch for shfmt: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/shfmt \
        "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_${SHFMT_ARCH}"; \
    chmod +x /usr/local/bin/shfmt; \
    shfmt --version

# hadolint
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) HADOLINT_ARCH="x86_64" ;; \
        arm64) HADOLINT_ARCH="arm64" ;; \
        *) echo "Unsupported arch for hadolint: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/hadolint \
        "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-${HADOLINT_ARCH}"; \
    chmod +x /usr/local/bin/hadolint; \
    hadolint --version

# actionlint
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) ACTIONLINT_ARCH="amd64" ;; \
        arm64) ACTIONLINT_ARCH="arm64" ;; \
        *) echo "Unsupported arch for actionlint: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/actionlint.tar.gz \
        "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${ACTIONLINT_ARCH}.tar.gz"; \
    tar -xzf /tmp/actionlint.tar.gz -C /tmp actionlint; \
    mv /tmp/actionlint /usr/local/bin/actionlint; \
    chmod +x /usr/local/bin/actionlint; \
    rm -f /tmp/actionlint.tar.gz; \
    actionlint --version

# NGC CLI
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

# KFP SDK + minimal Python deps (pipeline compilation and submission only)
RUN pip3 install --no-cache-dir --break-system-packages \
    "kfp>=2.0.0" \
    kfp-kubernetes \
    pyyaml \
    boto3 \
    pytest

LABEL org.opencontainers.image.version="${RUNNER_VERSION}"

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
