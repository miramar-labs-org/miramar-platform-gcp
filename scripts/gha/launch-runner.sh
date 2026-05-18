#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 [--token <RUNNER_TOKEN>] [options]"
    echo ""
    echo "Options:"
    echo "  --token       Runner registration token (auto-fetched via GITHUB_ORG_ADMIN_PAT if not set)"
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
        --pat)     GITHUB_ORG_GHCR_PAT="$2"; shift 2 ;;
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
    if [[ -z "${GITHUB_ORG_ADMIN_PAT:-}" ]]; then
        echo "ERROR: --token not provided and GITHUB_ORG_ADMIN_PAT is not set" >&2
        usage
    fi
    echo "Fetching runner registration token..."
    if [[ -n "${GITHUB_REPO}" ]]; then
        REG_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
    else
        REG_URL="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token"
    fi
    RUNNER_TOKEN=$(curl -fsSL \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_ORG_ADMIN_PAT}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${REG_URL}" | jq -r '.token')
fi

ARCH=$(uname -m)
case "${ARCH}" in
    x86_64)          ARCH_LABEL="amd64"; DEFAULT_LABELS="self-hosted,linux,amd64,wsl2" ;;
    aarch64|arm64)   ARCH_LABEL="arm64"; DEFAULT_LABELS="self-hosted,linux,arm64,dgx" ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

IMAGE="ghcr.io/${GITHUB_OWNER}/mlabs-runner:latest"

if [[ -z "${RUNNER_LABELS}" ]]; then
    RUNNER_LABELS="${DEFAULT_LABELS}"
fi

# Log in to GHCR using GITHUB_ORG_GHCR_PAT (must have read:packages scope).
GHCR_HOST="ghcr.io"
if ! grep -qs "${GHCR_HOST}" "${HOME}/.docker/config.json" 2>/dev/null; then
    if [[ -z "${GITHUB_ORG_GHCR_PAT:-}" ]]; then
        echo "ERROR: GITHUB_ORG_GHCR_PAT is not set — export it or pass --pat <token>" >&2
        exit 1
    fi
    echo "${GITHUB_ORG_GHCR_PAT}" | docker login "${GHCR_HOST}" -u "${GITHUB_OWNER}" --password-stdin
fi

echo "Architecture : ${ARCH} → ${ARCH_LABEL}"
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

if [[ -n "${GITHUB_ORG_GHCR_PAT:-}" ]]; then
    DOCKER_ENV+=(-e "GITHUB_PAT=${GITHUB_ORG_GHCR_PAT}")
fi

if [[ -n "${GITHUB_ORG_ADMIN_PAT:-}" ]]; then
    DOCKER_ENV+=(-e "GITHUB_ORG_ADMIN_PAT=${GITHUB_ORG_ADMIN_PAT}")
fi

echo "Pulling latest image..."
docker pull "${IMAGE}"

docker run --rm ${DETACH_FLAG} \
    "${DOCKER_ENV[@]}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --group-add "$(stat -c '%g' /var/run/docker.sock)" \
    --name "mlabs-runner-${ARCH_LABEL}" \
    "${IMAGE}"
