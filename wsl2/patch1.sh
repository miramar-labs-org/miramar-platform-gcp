#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

ARCH="$(dpkg --print-architecture)"

log "Install Helm"

# ARCH is already set earlier in your script: ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64) HARCH="amd64" ;;
  arm64) HARCH="arm64" ;;
  *) die "Unsupported arch for Helm: $ARCH" ;;
esac

# Get latest Helm release tag (e.g., v3.14.0)
HELM_VER="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)"

# Idempotent-ish: skip if already on latest tag
if command -v helm >/dev/null 2>&1; then
  CUR_VER="$(helm version --short 2>/dev/null | awk '{print $1}' | cut -d+ -f1 || true)"
  if [[ "$CUR_VER" == "$HELM_VER" ]]; then
    log "Helm already installed ($CUR_VER); skipping"
  else
    TMPDIR="$(mktemp -d)"
    curl -fsSL -o "$TMPDIR/helm.tgz" "https://get.helm.sh/helm-${HELM_VER}-linux-${HARCH}.tar.gz"
    tar -C "$TMPDIR" -xzf "$TMPDIR/helm.tgz"
    sudo install -o root -g root -m 0755 "$TMPDIR/linux-${HARCH}/helm" /usr/local/bin/helm
    rm -rf "$TMPDIR"
  fi
else
  TMPDIR="$(mktemp -d)"
  curl -fsSL -o "$TMPDIR/helm.tgz" "https://get.helm.sh/helm-${HELM_VER}-linux-${HARCH}.tar.gz"
  tar -C "$TMPDIR" -xzf "$TMPDIR/helm.tgz"
  sudo install -o root -g root -m 0755 "$TMPDIR/linux-${HARCH}/helm" /usr/local/bin/helm
  rm -rf "$TMPDIR"
fi

helm version --short