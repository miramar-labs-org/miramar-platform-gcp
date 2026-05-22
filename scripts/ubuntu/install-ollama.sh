#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   install-ollama.sh   # install Ollama, or upgrade if a newer version exists
#
# Idempotent — exits without doing anything if the installed version is already
# the latest. Uses the official installer, which also sets up the ollama system
# user and systemd service.

case "$(uname -m)" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

# Resolve the latest release tag via GitHub's redirect (no API key needed).
LATEST=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
  https://github.com/ollama/ollama/releases/latest | sed 's|.*/tag/||')

if command -v ollama &>/dev/null; then
  # ollama --version prints e.g. "ollama version 0.6.5"
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
