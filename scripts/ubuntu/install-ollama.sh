#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   install-ollama.sh   # install Ollama, or upgrade if a newer version exists
#
# Idempotent — exits without doing anything if the installed version is already
# the latest. Uses the official installer, which also sets up the ollama system
# user and systemd service.

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

if command -v apt-get >/dev/null 2>&1; then
  echo "==> Ensuring required packages are installed..."
  as_root apt-get update
  as_root apt-get install -y curl ca-certificates zstd
else
  echo "ERROR: This installer currently expects Debian/Ubuntu with apt-get." >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

LATEST=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  https://github.com/ollama/ollama/releases/latest | sed 's|.*/tag/||')

if command -v ollama &>/dev/null; then
  INSTALLED="v$(ollama --version 2>/dev/null | awk '{print $NF}')"
  if [[ "${INSTALLED}" == "${LATEST}" ]]; then
    echo "==> ollama ${INSTALLED} is already the latest version, nothing to do."
    exit 0
  fi
  echo "==> Upgrading ollama ${INSTALLED} → ${LATEST}..."
else
  echo "==> Installing ollama ${LATEST} (${ARCH})..."
fi

curl -fsSL https://ollama.com/install.sh | sh

echo "==> $(ollama --version)"
systemctl status ollama --no-pager --lines=3 2>/dev/null || true