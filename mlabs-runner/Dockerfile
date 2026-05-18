FROM ubuntu:22.04

ARG RUNNER_VERSION=2.334.0
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_USER=runner \
    RUNNER_HOME=/home/runner

# Install runner runtime deps explicitly so installdependencies.sh is not
# needed (running it under QEMU during arm64 cross-builds is unreliable).
# Package list matches what installdependencies.sh installs on Ubuntu 22.04.
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
        libicu70 \
    && rm -rf /var/lib/apt/lists/*

# Install Docker CLI (socket is mounted from the host at runtime)
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /usr/share/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu jammy stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

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
