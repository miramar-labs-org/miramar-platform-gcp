#!/bin/bash
# setup-shared-ssh.sh — join the lab SSH mesh from inside the WSL2 distro.
#
# Usage (run as root):
#   setup-shared-ssh.sh <DGX_HOST> <USER> [DISTRO_NAME] [SSH_PORT]
#
# Uses smbclient to sync SSH files with the DGX shared store.
# No CIFS mount, no fstab, no kernel modules.
#
# Called by post-provision.ps1 via Invoke-WslBash on first provision,
# and by wsl2-ssh-setup.service on every subsequent cold start.
# Idempotent: safe to run multiple times.

set -euo pipefail

DGX_HOST="${1:-spark-79b7.local}"
MOUNT_USER="${2:-${SUDO_USER:-$USER}}"
DISTRO_NAME="${3:-$(cat /etc/wsl2-distro-name 2>/dev/null || true)}"
SSH_PORT="${4:-2222}"

USER_HOME=$(getent passwd "$MOUNT_USER" | cut -d: -f6)
CREDS="$USER_HOME/.smbcredentials"
SSH_DIR="$USER_HOME/.ssh"

log()  { echo "==> $*"; }
warn() { echo "WARN: $*"; }

# ─── 1. Prerequisites ────────────────────────────────────────────────────────

if [[ ! -f "$CREDS" ]]; then
  echo "ERROR: $CREDS not found — post-provision must write it first" >&2
  exit 1
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$MOUNT_USER:$MOUNT_USER" "$SSH_DIR"

# ─── 2. Wait for DGX to be reachable (mDNS needs avahi) ─────────────────────

log "Waiting for $DGX_HOST..."
for i in $(seq 1 18); do
  if ping -c 1 -W 2 "$DGX_HOST" >/dev/null 2>&1; then
    log "$DGX_HOST reachable"
    break
  fi
  echo "  waiting... ($i/18)"
  sleep 5
  if [[ $i -eq 18 ]]; then
    echo "ERROR: $DGX_HOST not reachable after 90s" >&2
    exit 1
  fi
done

# ─── 3. smbclient helper ─────────────────────────────────────────────────────

smb() {
  # -N = no interactive password prompt (creds come from -A file)
  smbclient "//$DGX_HOST/shared" -A "$CREDS" -N "$@"
}

# ─── 4. Download SSH files from shared store ─────────────────────────────────

log "Downloading SSH files from DGX shared store..."
for f in config known_hosts authorized_keys; do
  TMP=$(mktemp)
  if smb -c "get ssh/$f $TMP" >/dev/null 2>&1; then
    install -m 600 -o "$MOUNT_USER" -g "$MOUNT_USER" "$TMP" "$SSH_DIR/$f"
    echo "  $f: downloaded"
  else
    warn "$f not found in DGX shared store — run Setup Shared SSH Store workflow first"
  fi
  rm -f "$TMP"
done

# ─── 5. Add own pubkey to authorized_keys (upload if changed) ────────────────

WSL2_PUB="$SSH_DIR/id_ed25519.pub"
if [[ -f "$WSL2_PUB" ]]; then
  KEY=$(cat "$WSL2_PUB")
  AK="$SSH_DIR/authorized_keys"
  if grep -qF "$KEY" "$AK" 2>/dev/null; then
    log "Own pubkey already in authorized_keys"
  else
    printf '\n%s\n' "$KEY" >> "$AK"
    smb -c "put $AK ssh/authorized_keys" >/dev/null
    log "Own pubkey added and authorized_keys uploaded"
  fi
else
  warn "No ~/.ssh/id_ed25519.pub found for $MOUNT_USER"
fi

# ─── 6. Add wsl2-<DISTRO_NAME> host block to config (upload if changed) ──────

if [[ -n "$DISTRO_NAME" ]]; then
  ALIAS="wsl2-${DISTRO_NAME}"
  CONFIG="$SSH_DIR/config"
  WIN_HOST=$(cmd.exe /c hostname 2>/dev/null | tr -d '\r\n' | tr '[:upper:]' '[:lower:]')
  WIN_HOSTNAME="${WIN_HOST:-localhost}.local"

  if [[ -f "$CONFIG" ]] && grep -q "^Host $ALIAS" "$CONFIG" 2>/dev/null; then
    log "$ALIAS already in config"
  elif [[ -f "$CONFIG" ]]; then
    printf '\nHost %s\n    HostName %s\n    User %s\n    Port %s\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n' \
      "$ALIAS" "$WIN_HOSTNAME" "$MOUNT_USER" "$SSH_PORT" >> "$CONFIG"
    smb -c "put $CONFIG ssh/config" >/dev/null
    log "$ALIAS added to config (HostName $WIN_HOSTNAME) and uploaded"
  fi
fi

log "setup-shared-ssh.sh complete"
