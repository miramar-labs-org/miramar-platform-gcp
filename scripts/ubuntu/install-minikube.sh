#!/usr/bin/env bash
set -euo pipefail

ARCH=$(dpkg --print-architecture)
INSTALL_PATH=/usr/local/bin/minikube

LATEST=$(curl -fsSL https://storage.googleapis.com/minikube/releases/latest/version.txt | tr -d '[:space:]')

if [[ -x "$INSTALL_PATH" ]]; then
  INSTALLED=$(minikube version --short 2>/dev/null | tr -d '[:space:]')
  if [[ "$INSTALLED" == "$LATEST" ]]; then
    echo "==> minikube ${INSTALLED} already installed, nothing to do."
    exit 0
  fi
  echo "==> Upgrading minikube ${INSTALLED} -> ${LATEST}..."
else
  echo "==> Installing minikube ${LATEST} (${ARCH})..."
fi

curl -fsSL "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}" \
  -o /tmp/minikube

sudo install -m 0755 /tmp/minikube "$INSTALL_PATH"
rm /tmp/minikube

echo "==> Version installed:"
minikube version

echo
echo "==> Done. Start a cluster with:"
echo "  minikube start"
