#!/usr/bin/env bash
set -euo pipefail

log() { printf "\n==> %s\n" "$*"; }
die() { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1; }

# ---- deps ----
missing=()
for c in curl unzip; do
  need "$c" || missing+=("$c")
done

if ((${#missing[@]})); then
  if need apt-get; then
    log "Installing deps: ${missing[*]}"
    if need sudo; then
      sudo apt-get update -y
      sudo apt-get install -y ca-certificates "${missing[@]}"
    else
      apt-get update -y
      apt-get install -y ca-certificates "${missing[@]}"
    fi
  else
    die "Missing commands: ${missing[*]} (and apt-get not found). Install them and rerun."
  fi
fi

ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64) ZIP_NAME="ngccli_arm64.zip"; DEFAULT_VER="4.5.2" ;;
  x86_64|amd64)  ZIP_NAME="ngccli_linux.zip"; DEFAULT_VER="3.41.3" ;;
  *) die "Unsupported architecture: $ARCH (expected arm64/aarch64 or x86_64/amd64)" ;;
esac

NGC_CLI_VERSION="${NGC_CLI_VERSION:-$DEFAULT_VER}"

# Install locations
if [[ "$(id -u)" -eq 0 ]]; then
  BIN_DIR="${BIN_DIR:-/usr/local/bin}"
  INSTALL_ROOT="${INSTALL_ROOT:-/opt/ngc-cli}"
else
  BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
  INSTALL_ROOT="${INSTALL_ROOT:-$HOME/.local/share/ngc-cli}"
fi
mkdir -p "$BIN_DIR" "$INSTALL_ROOT"

# If already installed, show version
if command -v ngc >/dev/null 2>&1; then
  log "ngc already on PATH: $(command -v ngc)"
  ngc --version || true
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DL_URL="https://api.ngc.nvidia.com/v2/resources/nvidia/ngc-apps/ngc_cli/versions/${NGC_CLI_VERSION}/files/${ZIP_NAME}"

log "Downloading NGC CLI ${NGC_CLI_VERSION} (${ZIP_NAME})"
log "URL: ${DL_URL}"

curl -fL --retry 5 --retry-delay 2 -o "${TMP}/${ZIP_NAME}" "${DL_URL}"

log "Unzipping..."
unzip -q "${TMP}/${ZIP_NAME}" -d "${TMP}"

# Archive contains ngc-cli/ directory with ngc binary inside
[[ -x "${TMP}/ngc-cli/ngc" ]] || die "Unexpected archive layout: ${TMP}/ngc-cli/ngc not found"

DEST="${INSTALL_ROOT}/${NGC_CLI_VERSION}"
log "Installing to ${DEST}/ngc-cli"
rm -rf "${DEST}"
mkdir -p "${DEST}"
cp -a "${TMP}/ngc-cli" "${DEST}/"

log "Linking ngc -> ${BIN_DIR}/ngc"
ln -sf "${DEST}/ngc-cli/ngc" "${BIN_DIR}/ngc"
chmod +x "${BIN_DIR}/ngc"

log "Installed ngc:"
"${BIN_DIR}/ngc" --version || true

# PATH hint
if ! echo ":$PATH:" | grep -q ":${BIN_DIR}:"; then
  cat <<PATHMSG

NOTE: ${BIN_DIR} is not currently on your PATH.
Add this to your shell rc (~/.bashrc or ~/.zshrc):

  export PATH="${BIN_DIR}:\$PATH"

Then reload your shell or run:
  export PATH="${BIN_DIR}:\$PATH"

PATHMSG
fi

cat <<'NEXT'

Next step (interactive):
  ngc config set

Quick test (lists NIM images):
  ngc registry image list --format_type ascii nvcr.io/nim/*

NEXT
