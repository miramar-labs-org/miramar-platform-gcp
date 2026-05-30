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
    x86_64)
        ARCH_LABEL="amd64"
        DEFAULT_LABELS="self-hosted,linux,amd64,wsl2"
        ;;
    aarch64|arm64)
        ARCH_LABEL="arm64"
        # Detect Jetson (Tegra) vs DGX (server) via device-tree model string.
        # /proc/device-tree/model is present on all ARM device-tree platforms;
        # Jetson boards always include "Orin" or "Jetson" in that string.
        if [[ -f /proc/device-tree/model ]] && \
           tr -d '\0' < /proc/device-tree/model | grep -qi "orin\|jetson"; then
            DEFAULT_LABELS="self-hosted,linux,arm64,agx"
        else
            DEFAULT_LABELS="self-hosted,linux,arm64,dgx"
        fi
        ;;
    *)
        echo "ERROR: Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

CONTAINER_NAME="mlabs-runner-${ARCH_LABEL}"

if docker inspect "${CONTAINER_NAME}" &>/dev/null; then
    CONTAINER_STATUS=$(docker inspect --format '{{.State.Status}}' "${CONTAINER_NAME}")
    if [[ "${CONTAINER_STATUS}" == "running" ]]; then
        echo "Runner container '${CONTAINER_NAME}' is already running."
        docker ps --filter "name=^${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}"
        exit 0
    else
        echo "Removing stopped container '${CONTAINER_NAME}' (status: ${CONTAINER_STATUS})..."
        docker rm "${CONTAINER_NAME}"
    fi
fi

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
    DOCKER_ENV+=(-e "GITHUB_ORG_GHCR_PAT=${GITHUB_ORG_GHCR_PAT}")
fi

if [[ -n "${GITHUB_ORG_ADMIN_PAT:-}" ]]; then
    DOCKER_ENV+=(-e "GITHUB_ORG_ADMIN_PAT=${GITHUB_ORG_ADMIN_PAT}")
fi

if [[ -n "${HF_TOKEN:-}" ]]; then
    DOCKER_ENV+=(-e "HF_TOKEN=${HF_TOKEN}")
fi


# Unregister any existing runner with the same name to avoid session conflicts
if [[ -n "${GITHUB_ORG_ADMIN_PAT:-}" ]]; then
    if [[ -n "${GITHUB_REPO}" ]]; then
        RUNNERS_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners"
    else
        RUNNERS_URL="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners"
    fi
    EXISTING_ID=$(curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_ORG_ADMIN_PAT}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${RUNNERS_URL}" | jq -r ".runners[] | select(.name == \"${RUNNER_NAME}\") | .id")
    if [[ -n "${EXISTING_ID}" ]]; then
        echo "Unregistering existing runner '${RUNNER_NAME}' (ID ${EXISTING_ID})..."
        curl -fsSL -X DELETE \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_ORG_ADMIN_PAT}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${RUNNERS_URL}/${EXISTING_ID}"
    fi
fi

echo "Pulling latest image..."
docker pull "${IMAGE}"

RUNNER_VERSION=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "${IMAGE}" 2>/dev/null || echo "unknown")
IMAGE_REVISION=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${IMAGE}" 2>/dev/null || echo "unknown")
echo "Runner version : ${RUNNER_VERSION}"
echo "Image revision : ${IMAGE_REVISION:0:7}"

WORK_DIR="${HOME}/runner/_work"
mkdir -p "${WORK_DIR}"

DOCKER_VOLS=(
    -v /var/run/docker.sock:/var/run/docker.sock
    -v "${WORK_DIR}:/home/runner/_work"
)

# DGX and AGX: minikube state must persist across ephemeral runner containers.
# WSL2 has no minikube; its ~/.kube/config holds GKE contexts we don't want exposed.
# /host-bin exposes the host's /usr/local/bin so workflows can install binaries there
# (e.g. setup-minikube copies the runner image's baked-in minikube to the host).
if [[ "${DEFAULT_LABELS}" == *"dgx"* || "${DEFAULT_LABELS}" == *"agx"* ]]; then
    mkdir -p "${HOME}/.minikube" "${HOME}/.kube"
    # The runner container runs as uid 1000; host files are owned by the host
    # user (different uid). Make .minikube and .kube world-readable so kubectl
    # inside the container can read cert files referenced in the kubeconfig.
    chmod -R a+rX "${HOME}/.minikube" "${HOME}/.kube" 2>/dev/null || true
    DOCKER_VOLS+=(
        -v "${HOME}/.minikube:/home/runner/.minikube"
        -v "${HOME}/.kube:/home/runner/.kube"
        -v /usr/local/bin:/host-bin
    )
fi

# Mount the host avahi socket so the container's libnss-mdns (nss-mdns ≥0.15)
# can delegate .local resolution to the host avahi daemon. This gives all three
# runners (DGX, AGX, WSL2-Ubuntu) identical .local name resolution — the host
# avahi has full LAN visibility regardless of which machine the container is on.
# Skipped silently if avahi is not running (falls back to in-container multicast).
[[ -S /run/avahi-daemon/socket ]] && \
    DOCKER_VOLS+=(-v /run/avahi-daemon/socket:/run/avahi-daemon/socket)

# Mount the shared SSH store as the runner's ~/.ssh so any workflow can SSH
# to lab machines using config aliases and the host's identity directly.
# ~/shared/ssh holds config, known_hosts, authorized_keys (canonical shared store).
# id_ed25519 is the host private key and lives outside the shared dir; bind-mount
# it as a child so it overlays the shared dir mount at that path.
# Skipped if setup-shared-ssh has not been run yet on this host.
if [[ -d "${HOME}/shared/ssh" && -f "${HOME}/.ssh/id_ed25519" ]]; then
    DOCKER_VOLS+=(
        -v "${HOME}/shared/ssh:/home/runner/.ssh"
        -v "${HOME}/.ssh/id_ed25519:/home/runner/.ssh/id_ed25519:ro"
        -v "${HOME}/.ssh/id_ed25519.pub:/home/runner/.ssh/id_ed25519.pub:ro"
    )
fi

docker run --rm ${DETACH_FLAG} \
    "${DOCKER_ENV[@]}" \
    "${DOCKER_VOLS[@]}" \
    --group-add "$(stat -c '%g' /var/run/docker.sock)" \
    --gpus all \
    --network host \
    --name "${CONTAINER_NAME}" \
    "${IMAGE}"
