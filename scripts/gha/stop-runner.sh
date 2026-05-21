#!/bin/bash
set -euo pipefail

# Gracefully stop the mlabs-runner container.
# Sends SIGTERM, which triggers the entrypoint cleanup trap:
#   - fetches a fresh removal token via the GitHub API
#   - runs config.sh remove to deregister from GitHub Actions
# The container was launched with --rm so it removes itself on exit.

ARCH=$(uname -m)
case "${ARCH}" in
    x86_64)         ARCH_LABEL="amd64" ;;
    aarch64|arm64)  ARCH_LABEL="arm64" ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

CONTAINER_NAME="mlabs-runner-${ARCH_LABEL}"

# Give the deregistration API call and config.sh remove time to complete.
STOP_TIMEOUT="${STOP_TIMEOUT:-30}"

if ! docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then
    echo "No running container named '${CONTAINER_NAME}'"
    exit 0
fi

echo "Stopping ${CONTAINER_NAME} (timeout ${STOP_TIMEOUT}s)..."
docker stop --timeout "${STOP_TIMEOUT}" "${CONTAINER_NAME}"
echo "Runner stopped and deregistered."
