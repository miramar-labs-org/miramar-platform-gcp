#!/usr/bin/env bash
# Install and register a GitHub Actions self-hosted runner directly on the host.
# Useful for machines where Docker is unavailable or unwanted (e.g. Jetson AGX Orin).
#
# Requirements:
#   GITHUB_ORG_ADMIN_PAT  — admin:org PAT (used to fetch registration token)
#   GITHUB_ORG_GHCR_PAT   — optional, not needed for host install
#
# Usage:
#   ./install-runner.sh [options]
#
set -euo pipefail

GITHUB_OWNER="miramar-labs-org"
RUNNER_VERSION=""  # auto-detected from GitHub releases if not set
INSTALL_DIR="${HOME}/actions-runner"
RUNNER_NAME="${HOSTNAME}"
RUNNER_LABELS=""
RUNNER_GROUP="Default"
GITHUB_REPO=""
EPHEMERAL="false"
AS_SERVICE="false"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --name      Runner name (default: hostname)"
    echo "  --labels    Comma-separated labels (default: self-hosted,linux,<arch>,<machine>)"
    echo "  --repo      Repo-level runner: owner/repo (default: org-level)"
    echo "  --group     Runner group (default: Default)"
    echo "  --dir       Install directory (default: ~/actions-runner)"
    echo "  --version   Runner version (default: ${RUNNER_VERSION})"
    echo "  --ephemeral Deregister after one job"
    echo "  --service   Install and start as a systemd service"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)      RUNNER_NAME="$2";    shift 2 ;;
        --labels)    RUNNER_LABELS="$2";  shift 2 ;;
        --repo)      GITHUB_REPO="$2";    shift 2 ;;
        --group)     RUNNER_GROUP="$2";   shift 2 ;;
        --dir)       INSTALL_DIR="$2";    shift 2 ;;
        --version)   RUNNER_VERSION="$2"; shift 2 ;;
        --ephemeral) EPHEMERAL="true";    shift ;;
        --service)   AS_SERVICE="true";   shift ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "${GITHUB_ORG_ADMIN_PAT:-}" ]]; then
    echo "ERROR: GITHUB_ORG_ADMIN_PAT is not set" >&2
    exit 1
fi

# Detect arch
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64)        RUNNER_ARCH="x64";   ARCH_LABEL="amd64";  MACHINE_LABEL="wsl2" ;;
    aarch64|arm64)
        RUNNER_ARCH="arm64"; ARCH_LABEL="arm64"
        if [[ -f /proc/device-tree/model ]] && \
           tr -d '\0' < /proc/device-tree/model | grep -qi "orin\|jetson"; then
            MACHINE_LABEL="agx"
        else
            MACHINE_LABEL="dgx"
        fi
        ;;
    *) echo "ERROR: Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
esac

if [[ -z "${RUNNER_LABELS}" ]]; then
    RUNNER_LABELS="self-hosted,linux,${ARCH_LABEL},${MACHINE_LABEL}"
fi

echo "Runner name  : ${RUNNER_NAME}"
echo "Labels       : ${RUNNER_LABELS}"
echo "Install dir  : ${INSTALL_DIR}"
echo "Runner ver   : ${RUNNER_VERSION}"
echo ""

# Fetch registration token
if [[ -n "${GITHUB_REPO}" ]]; then
    REG_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
    GITHUB_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
else
    REG_URL="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token"
    GITHUB_URL="https://github.com/${GITHUB_OWNER}"
fi

echo "Fetching runner registration token..."
RUNNER_TOKEN=$(curl -fsSL \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_ORG_ADMIN_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${REG_URL}" | jq -r '.token')

# Resolve runner version and download URL via GitHub API
RELEASE_JSON="$(curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_ORG_ADMIN_PAT}" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/actions/runner/releases/latest)"

if [[ -z "${RUNNER_VERSION}" ]]; then
    RUNNER_VERSION="$(echo "${RELEASE_JSON}" | jq -r '.tag_name' | tr -d 'v')"
fi
echo "Runner version : ${RUNNER_VERSION}"

TARBALL="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
TARBALL_URL="$(echo "${RELEASE_JSON}" | jq -r \
    --arg name "${TARBALL}" \
    '.assets[] | select(.name == $name) | .browser_download_url')"

if [[ -z "${TARBALL_URL}" ]]; then
    echo "ERROR: no release asset found for ${TARBALL}" >&2
    exit 1
fi

# Download runner tarball (GitHub releases do not ship individual .sha256 files;
# HTTPS provides transport integrity for the download)
mkdir -p "${INSTALL_DIR}"
echo "Downloading ${TARBALL}..."
_tmp="$(mktemp)"
curl -fsSL -o "$_tmp" "${TARBALL_URL}"
tar xzf "$_tmp" -C "${INSTALL_DIR}"
rm -f "$_tmp"

cd "${INSTALL_DIR}"

# Unregister any existing runner with the same name
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

# Configure runner
EXTRA_FLAGS=""
[[ "${EPHEMERAL}" == "true" ]] && EXTRA_FLAGS="--ephemeral"

./config.sh \
    --unattended \
    --url "${GITHUB_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --runnergroup "${RUNNER_GROUP}" \
    --work "_work" \
    --replace \
    ${EXTRA_FLAGS}

echo ""
echo "Runner configured in ${INSTALL_DIR}"

if [[ "${AS_SERVICE}" == "true" ]]; then
    echo "Installing systemd service..."
    sudo ./svc.sh install
    sudo ./svc.sh start
    echo "Service status:"
    sudo ./svc.sh status
    echo ""
    echo "To stop:      sudo ${INSTALL_DIR}/svc.sh stop"
    echo "To uninstall: sudo ${INSTALL_DIR}/svc.sh uninstall"
else
    echo ""
    echo "To start:   cd ${INSTALL_DIR} && ./run.sh"
    echo "To install as a service: re-run with --service"
fi
