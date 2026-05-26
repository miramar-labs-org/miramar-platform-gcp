#!/bin/bash
# setup-shared-ssh.sh — join the lab SSH mesh from inside the WSL2 distro.
#
# Usage (run as root):
#   setup-shared-ssh.sh <DGX_HOST> <USER> [DISTRO_NAME] [SSH_PORT]
#
# Called by post-provision.ps1 via Invoke-WslBash (base64 tunnel).
# Also installed as /usr/local/bin/setup-shared-ssh.sh by bootstrap.sh
# and run on every boot by wsl2-mount-shared.service.
#
# Idempotent: skips steps that are already done.
# Hard-fails (exit 1) if the CIFS mount cannot succeed.

set -euo pipefail

DGX_HOST="${1:-spark-79b7.local}"
MOUNT_USER="${2:-${SUDO_USER:-$USER}}"
DISTRO_NAME="${3:-}"   # optional — skip wsl2-<NAME> host block if empty
SSH_PORT="${4:-2222}"

USER_HOME=$(getent passwd "$MOUNT_USER" | cut -d: -f6)
SHARED="$USER_HOME/shared"
CREDS="$USER_HOME/.smbcredentials"
SSH_DIR="$USER_HOME/.ssh"
UID_V=$(id -u "$MOUNT_USER")
GID_V=$(id -g "$MOUNT_USER")

log()  { echo "==> $*"; }
warn() { echo "WARN: $*"; }

# ─── 1. Prerequisites ────────────────────────────────────────────────────────

if [[ ! -f "$CREDS" ]]; then
  echo "ERROR: $CREDS not found — run post-provision.ps1 with -SmbPassword first" >&2
  exit 1
fi

mkdir -p "$SHARED"
chown "$MOUNT_USER:$MOUNT_USER" "$SHARED"

# ─── 2. Wait for avahi-daemon (mDNS — needed to resolve spark-79b7.local) ───

log "Waiting for avahi-daemon..."
for i in $(seq 1 18); do
  if systemctl is-active avahi-daemon >/dev/null 2>&1; then
    log "avahi-daemon active"
    break
  fi
  echo "  waiting for avahi-daemon... ($i/18)"
  sleep 5
  if [[ $i -eq 18 ]]; then
    warn "avahi-daemon did not start within 90s — mount may fail"
  fi
done

# ─── 3. CIFS fstab entry ─────────────────────────────────────────────────────

FSTAB_ENTRY="//$DGX_HOST/shared $SHARED cifs credentials=$CREDS,uid=$UID_V,gid=$GID_V,file_mode=0600,dir_mode=0700,_netdev,nofail 0 0"

# Replace any existing entry for this DGX_HOST/shared path, then append fresh.
sed -i "\|$DGX_HOST/shared|d" /etc/fstab
printf '%s\n' "$FSTAB_ENTRY" >> /etc/fstab
log "fstab entry written (nofail)"

# ─── 4. Mount ~/shared (retry 6×5s) ─────────────────────────────────────────

if mountpoint -q "$SHARED" 2>/dev/null; then
  log "$SHARED already mounted"
else
  log "Mounting $SHARED..."
  MOUNTED=0
  for i in $(seq 1 6); do
    OUT=$(mount "$SHARED" 2>&1); EC=$?
    echo "  attempt $i/6: exit=$EC -- $OUT"
    if [[ $EC -eq 0 ]]; then
      MOUNTED=1
      break
    fi
    sleep 5
  done
  if [[ $MOUNTED -eq 0 ]]; then
    echo "ERROR: $SHARED mount failed after 6 attempts" >&2
    exit 1
  fi
  log "$SHARED mounted"
fi

# ─── 5. ~/.ssh symlinks → ~/shared/ssh/ ──────────────────────────────────────

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$MOUNT_USER:$MOUNT_USER" "$SSH_DIR"

for f in config known_hosts authorized_keys; do
  target="$SHARED/ssh/$f"
  link="$SSH_DIR/$f"
  if [[ ! -e "$target" ]]; then
    warn "$target not found — run setup-shared-ssh workflow first; skipping $f"
    continue
  fi
  if [[ -L "$link" ]]; then
    echo "  $f: already a symlink — skipping"
  elif [[ -f "$link" ]]; then
    mv "$link" "${link}.bak"
    echo "  $f: backed up → ${link}.bak"
    ln -sf "$target" "$link"
    echo "  $f: symlinked"
  else
    ln -sf "$target" "$link"
    echo "  $f: symlinked"
  fi
done
log "~/.ssh symlinks configured"

# ─── 6. Inject runner pubkeys → shared authorized_keys ───────────────────────

AK="$SHARED/ssh/authorized_keys"
for keyfile in /tmp/dgx-key.pub /tmp/agx-key.pub; do
  if [[ -f "$keyfile" ]]; then
    KEY=$(cat "$keyfile")
    if grep -qF "$KEY" "$AK" 2>/dev/null; then
      echo "  $(basename $keyfile): already in shared authorized_keys"
    else
      printf '\n%s\n' "$KEY" >> "$AK"
      echo "  $(basename $keyfile): injected"
    fi
    rm -f "$keyfile"
  fi
done

# ─── 7. Add this WSL2 distro's own pubkey → shared authorized_keys ───────────

WSL2_PUB="$SSH_DIR/id_ed25519.pub"
if [[ -f "$WSL2_PUB" ]]; then
  KEY=$(cat "$WSL2_PUB")
  if grep -qF "$KEY" "$AK" 2>/dev/null; then
    log "WSL2 pubkey already in shared authorized_keys"
  else
    printf '\n%s\n' "$KEY" >> "$AK"
    log "WSL2 pubkey added to shared authorized_keys"
  fi
else
  warn "No ~/.ssh/id_ed25519.pub found for $MOUNT_USER — skipping own pubkey"
fi

# ─── 8. Add wsl2-<DISTRO_NAME> host block → shared config ────────────────────

if [[ -n "$DISTRO_NAME" ]]; then
  ALIAS="wsl2-${DISTRO_NAME}"
  CONFIG="$SHARED/ssh/config"

  # Get Windows hostname from cmd.exe, convert to lowercase .local name.
  WIN_HOST=$(cmd.exe /c hostname 2>/dev/null | tr -d '\r\n' | tr '[:upper:]' '[:lower:]')
  if [[ -z "$WIN_HOST" ]]; then
    warn "Could not get Windows hostname via cmd.exe — using 'localhost'"
    WIN_HOST="localhost"
    WIN_HOSTNAME="localhost"
  else
    WIN_HOSTNAME="${WIN_HOST}.local"
  fi

  if [[ -f "$CONFIG" ]]; then
    if grep -q "^Host $ALIAS" "$CONFIG" 2>/dev/null; then
      log "$ALIAS already present in shared SSH config"
    else
      printf '\nHost %s\n    HostName %s\n    User %s\n    Port %s\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n' \
        "$ALIAS" "$WIN_HOSTNAME" "$MOUNT_USER" "$SSH_PORT" >> "$CONFIG"
      log "$ALIAS added to shared SSH config (HostName $WIN_HOSTNAME)"
    fi
  else
    warn "$CONFIG not found — run Setup Shared SSH Store first; skipping host block"
  fi
fi

log "setup-shared-ssh.sh complete"
