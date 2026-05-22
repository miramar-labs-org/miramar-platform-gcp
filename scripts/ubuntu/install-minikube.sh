#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   install-minikube.sh            # install / upgrade the minikube binary
#   install-minikube.sh --start    # install binary then start the cluster with
#                                  # DGX Spark / NeMo settings (GPU, addons, device-plugin pin)

START=false
for arg in "$@"; do
  case "$arg" in
    --start) START=true ;;
    --help|-h)
      sed -n '2,6p' "$0" | sed 's/^# //'
      exit 0
      ;;
  esac
done

# ---- Install / upgrade binary ----

case "$(uname -m)" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
INSTALL_PATH=/usr/local/bin/minikube

# Use GitHub's /releases/latest/download/ redirect — no version API call needed.
DOWNLOAD_URL="https://github.com/kubernetes/minikube/releases/latest/download/minikube-linux-${ARCH}"

if [[ -x "$INSTALL_PATH" ]]; then
  INSTALLED=$(minikube version --short 2>/dev/null | tr -d '[:space:]')
  echo "==> minikube ${INSTALLED} already installed, nothing to do."
else
  echo "==> Installing minikube (${ARCH})..."
  curl -fsSL "${DOWNLOAD_URL}" -o /tmp/minikube
  sudo install -m 0755 /tmp/minikube "$INSTALL_PATH"
  rm /tmp/minikube
  echo "==> Installed $(minikube version --short)"
fi

[[ "$START" == "false" ]] && exit 0

# ---- Start cluster with DGX Spark / NeMo settings ----

log() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }

if minikube status &>/dev/null; then
  log "minikube already running — ensuring addons and GPU label..."
else
  log "Starting minikube (docker driver, all GPUs, no resource limits)..."
  EXTRA_FLAGS=()
  [[ ${EUID:-$(id -u)} -eq 0 ]] && EXTRA_FLAGS+=(--force)

  # Pre-pull kicbase (~500 MB) without the 360s host-creation timeout so slow
  # first-pull doesn't abort the actual start.
  log "Pre-pulling kicbase image (no timeout)..."
  minikube start --download-only \
    --driver=docker \
    --container-runtime=docker \
    "${EXTRA_FLAGS[@]}"

  minikube start \
    --driver=docker \
    --container-runtime=docker \
    --cpus=no-limit \
    --memory=no-limit \
    --gpus=all \
    "${EXTRA_FLAGS[@]}"

  # Pin nvidia-device-plugin to v0.18.0 — fixes GPU advertisement bug on GB10
  log "Pinning nvidia-device-plugin to v0.18.0 (GB10 / Spark DGX fix)..."
  minikube addons disable nvidia-device-plugin || true
  minikube addons enable nvidia-device-plugin \
    --images="NvidiaDevicePlugin=nvidia/k8s-device-plugin:v0.18.0" \
    --registries="NvidiaDevicePlugin=nvcr.io"
fi

addon_enabled() {
  minikube addons list 2>/dev/null | awk -v a="$1" '$1==a {print $2}' | grep -qi '^enabled$'
}
for addon in ingress dashboard metrics-server; do
  if addon_enabled "$addon"; then
    log "$addon already enabled."
  else
    log "Enabling $addon..."
    minikube addons enable "$addon"
  fi
done

log "Labeling node for NVIDIA GPU scheduling..."
kubectl label node minikube feature.node.kubernetes.io/pci-10de.present=true --overwrite

log "Cluster ready."
kubectl get nodes -o wide
