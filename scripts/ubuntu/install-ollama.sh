#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   install-ollama.sh   # install or upgrade Ollama on the host
#
# Installs the latest Ollama release using the official installer.
# Idempotent — safe to re-run; upgrades an existing install in-place.
# Sets up the ollama systemd service and ollama user automatically.

case "$(uname -m)" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

if command -v ollama &>/dev/null; then
  INSTALLED=$(ollama --version 2>/dev/null | tr -d '[:space:]')
  echo "==> ollama ${INSTALLED} already installed — upgrading..."
else
  echo "==> Installing ollama (${ARCH})..."
fi

curl -fsSL https://ollama.com/install.sh | sh

echo "==> $(ollama --version)"
echo "==> ollama installed. Service status:"
systemctl status ollama --no-pager --lines=3 2>/dev/null || true
