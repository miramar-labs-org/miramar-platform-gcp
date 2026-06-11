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
  # '|| echo ""' inside $() prevents set -e from triggering if minikube version
  # exits non-zero (e.g. DRV_CREATE_TIMEOUT=37 from stale profile state).
  INSTALLED=$(minikube version --short 2>/dev/null | tr -d '[:space:]' || echo "")
  echo "==> minikube ${INSTALLED:-unknown} already installed, nothing to do."
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

  # Detect stale profile (machine state file exists but Docker container is gone).
  # This happens when minikube was force-deleted or the container was removed manually.
  # Purge before starting to avoid "cannot change memory/CPU" and host-creation errors.
  if minikube profile list 2>/dev/null | grep -q minikube && \
     ! docker inspect minikube &>/dev/null; then
    log "Stale minikube profile detected (container gone) — purging..."
    minikube delete --all --purge 2>/dev/null || true
  fi

  # kicbase (~500 MB) must be in Docker's cache before minikube start or the
  # 360s createHost timeout fires (exit 37 = DRV_CREATE_TIMEOUT). Try to detect
  # and pre-pull the image; if detection fails, the first start attempt will pull
  # it as a side-effect and we retry once the image is cached.
  KICBASE_IMAGE=$(grep -ao \
      -e 'gcr\.io/k8s-minikube/kicbase:v[0-9.]*' \
      -e 'registry\.k8s\.io/kicbase/kicbase:v[0-9.]*' \
      /usr/local/bin/minikube 2>/dev/null | head -1 || true)
  if [[ -n "${KICBASE_IMAGE}" ]]; then
    log "Pre-pulling ${KICBASE_IMAGE} via docker..."
    docker pull "${KICBASE_IMAGE}"
  else
    log "Could not detect kicbase image — will retry on timeout if needed."
  fi

  minikube_start() {
    minikube start \
      --driver=docker \
      --container-runtime=docker \
      --cpus=no-limit \
      --memory=no-limit \
      --gpus=all \
      "${EXTRA_FLAGS[@]}"
  }

  if ! minikube_start; then
    EXIT=$?
    if [[ $EXIT -eq 37 ]]; then
      # Exit 37 = DRV_CREATE_TIMEOUT: kicbase pull raced with the 360s limit.
      # The pull ran as a side-effect — clean up and retry from cache.
      log "Start timed out (exit 37) — kicbase should now be cached. Retrying..."
      minikube delete --all --purge 2>/dev/null || true
      minikube_start
    else
      exit $EXIT
    fi
  fi

  # Pin nvidia-device-plugin to v0.18.0 — fixes GPU advertisement bug on GB10
  log "Pinning nvidia-device-plugin to v0.18.0 (GB10 / Spark DGX fix)..."
  minikube addons disable nvidia-device-plugin || true
  minikube addons enable nvidia-device-plugin \
    --images="NvidiaDevicePlugin=nvidia/k8s-device-plugin:v0.18.0" \
    --registries="NvidiaDevicePlugin=nvcr.io"
fi

for addon in ingress dashboard metrics-server; do
  log "Enabling addon: $addon"
  minikube addons enable "$addon"
done

log "Waiting for ingress-nginx controller to be ready..."
kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=120s

log "Labeling node for NVIDIA GPU scheduling..."
kubectl label node minikube feature.node.kubernetes.io/pci-10de.present=true --overwrite

# Rewrite kubeconfig cert paths to use the current HOME. Must run after all
# minikube operations (addons enable regenerates ~/.kube/config with the profile's
# stored paths, which reference the original user's home on a host-originated cluster).
sed -i "s|/home/[^/]*/\.minikube/|${HOME}/.minikube/|g" \
    "${HOME}/.kube/config" 2>/dev/null || true

log "Cluster ready."
kubectl get nodes -o wide
