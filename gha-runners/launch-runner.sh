#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 --token <RUNNER_TOKEN> [options]"
    echo ""
    echo "Options:"
    echo "  --token       Runner registration token (required)"
    echo "  --pat         GitHub PAT with read:packages scope (for GHCR login)"
    echo "  --name        Runner name (default: hostname)"
    echo "  --labels      Comma-separated labels (default: self-hosted,linux,<arch>)"
    echo "  --repo        Repo-level runner: owner/repo (default: org-level)"
    echo "  --group       Runner group (default: Default)"
    echo "  --ephemeral   Register as ephemeral (single-job) runner"
    echo "  --detach      Run container in background"
    exit 1
}

RUNNER_TOKEN=""
RUNNER_NAME="${HOSTNAME}"
RUNNER_LABELS=""
GITHUB_OWNER="miramar-labs-org"
GITHUB_REPO=""
RUNNER_GROUP="Default"
EPHEMERAL="false"
DETACH_FLAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)   RUNNER_TOKEN="$2"; shift 2 ;;
        --pat)     GITHUB_PAT="$2"; shift 2 ;;
        --name)    RUNNER_NAME="$2"; shift 2 ;;
        --labels)  RUNNER_LABELS="$2"; shift 2 ;;
        --repo)    GITHUB_REPO="$2"; shift 2 ;;
        --group)   RUNNER_GROUP="$2"; shift 2 ;;
        --ephemeral) EPHEMERAL="true"; shift ;;
        --detach)  DETACH_FLAG="-d"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "${RUNNER_TOKEN}" ]]; then
    echo "ERROR: --token is required" >&2
    usage
fi

ARCH=$(uname -m)
case "${ARCH}" in
    x86_64)          IMAGE_SUFFIX="amd64"; DEFAULT_LABELS="self-hosted,linux,amd64,wsl2" ;;
    aarch64|arm64)   IMAGE_SUFFIX="arm64"; DEFAULT_LABELS="self-hosted,linux,arm64,dgx" ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

IMAGE="ghcr.io/${GITHUB_OWNER}/gha-runner-${IMAGE_SUFFIX}:latest"

if [[ -z "${RUNNER_LABELS}" ]]; then
    RUNNER_LABELS="${DEFAULT_LABELS}"
fi

# Log in to GHCR if not already authenticated
GHCR_HOST="ghcr.io"
if ! docker system info 2>/dev/null | grep -q "${GHCR_HOST}" && \
   ! grep -qs "${GHCR_HOST}" "${HOME}/.docker/config.json" 2>/dev/null; then
    if command -v gh &>/dev/null && gh auth status &>/dev/null; then
        echo "Logging in to GHCR via gh CLI..."
        gh auth token | docker login "${GHCR_HOST}" -u "$(gh api user -q .login)" --password-stdin
    elif [[ -n "${GITHUB_PAT:-}" ]]; then
        echo "Logging in to GHCR via GITHUB_PAT..."
        echo "${GITHUB_PAT}" | docker login "${GHCR_HOST}" -u "${GITHUB_OWNER}" --password-stdin
    else
        echo "ERROR: not logged in to GHCR — set GITHUB_PAT or pass --pat <token>" >&2
        exit 1
    fi
fi

echo "Architecture : ${ARCH} → ${IMAGE_SUFFIX}"
echo "Image        : ${IMAGE}"
echo "Runner name  : ${RUNNER_NAME}"
echo "Labels       : ${RUNNER_LABELS}"
if [[ -n "${GITHUB_REPO}" ]]; then
    echo "Scope        : repo (${GITHUB_OWNER}/${GITHUB_REPO})"
else
    echo "Scope        : org (${GITHUB_OWNER})"
fi
echo ""

DOCKER_ENV=(
    -e "RUNNER_TOKEN=${RUNNER_TOKEN}"
    -e "RUNNER_NAME=${RUNNER_NAME}"
    -e "RUNNER_LABELS=${RUNNER_LABELS}"
    -e "GITHUB_OWNER=${GITHUB_OWNER}"
    -e "RUNNER_GROUP=${RUNNER_GROUP}"
    -e "EPHEMERAL=${EPHEMERAL}"
)

if [[ -n "${GITHUB_REPO}" ]]; then
    DOCKER_ENV+=(-e "GITHUB_REPO=${GITHUB_REPO}")
fi

docker run --rm ${DETACH_FLAG} \
    "${DOCKER_ENV[@]}" \
    --name "gha-runner-${IMAGE_SUFFIX}" \
    "${IMAGE}"
