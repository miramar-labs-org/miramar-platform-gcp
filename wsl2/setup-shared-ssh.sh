#!/bin/bash
# setup-shared-ssh.sh — join the lab SSH mesh from inside a WSL2 distro.
#
# Usage (run as root):
#   setup-shared-ssh.sh <DGX_HOST> <USER> [DISTRO_NAME] [SSH_PORT]
#
# Mounts //DGX_HOST/shared at ~/shared/ via CIFS, then symlinks all
# ~/.ssh/ files (config, known_hosts, authorized_keys, id_ed25519,
# id_ed25519.pub) to ~/shared/ssh/. All machines share Spark's SSH identity.
# Idempotent: safe to run multiple times.

set -euo pipefail

DGX_HOST="${1:-spark-79b7.local}"
MOUNT_USER="${2:-${SUDO_USER:-$USER}}"
DISTRO_NAME="${3:-$(cat /etc/wsl2-distro-name 2>/dev/null || true)}"
SSH_PORT="${4:-2222}"
WIN_HOSTNAME="${5:-}"  # Windows host for SSH config HostName (e.g. msi.local or IP)

USER_HOME=$(getent passwd "$MOUNT_USER" | cut -d: -f6)
CREDS="$USER_HOME/.smbcredentials"
SSH_DIR="$USER_HOME/.ssh"
SHARED_DIR="$USER_HOME/shared"
UID_NUM=$(id -u "$MOUNT_USER")
GID_NUM=$(id -g "$MOUNT_USER")

log()  { echo "==> $*"; }
warn() { echo "WARN: $*"; }

# ─── 1. Prerequisites ────────────────────────────────────────────────────────

if [[ ! -f "$CREDS" ]]; then
  echo "ERROR: $CREDS not found — post-provision must write it first" >&2
  exit 1
fi

if ! command -v mount.cifs >/dev/null 2>&1; then
  log "Installing cifs-utils..."
  apt-get install -y --no-install-recommends cifs-utils
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$MOUNT_USER:$MOUNT_USER" "$SSH_DIR"

# ─── 2. Wait for DGX to be reachable ─────────────────────────────────────────

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

# ─── 3. CIFS mount ───────────────────────────────────────────────────────────

mkdir -p "$SHARED_DIR"
chown "$MOUNT_USER:$MOUNT_USER" "$SHARED_DIR"

if ! grep -qF "//$DGX_HOST/shared" /etc/fstab 2>/dev/null; then
  echo "//$DGX_HOST/shared $SHARED_DIR cifs credentials=$CREDS,uid=$UID_NUM,gid=$GID_NUM,vers=3.0,noauto,_netdev,nofail,file_mode=0600,dir_mode=0700 0 0" \
    >> /etc/fstab
  log "Added CIFS fstab entry"
fi

if mountpoint -q "$SHARED_DIR" 2>/dev/null; then
  log "$SHARED_DIR already mounted"
else
  mount -t cifs "//$DGX_HOST/shared" "$SHARED_DIR" \
    -o "credentials=$CREDS,uid=$UID_NUM,gid=$GID_NUM,file_mode=0600,dir_mode=0700"
  log "Mounted $SHARED_DIR"
fi

# ─── 4. Symlink ~/.ssh/ → ~/shared/ssh/ ──────────────────────────────────────

log "Symlinking ~/.ssh/ → $SHARED_DIR/ssh/..."
for f in config known_hosts authorized_keys id_ed25519 id_ed25519.pub; do
  target="$SHARED_DIR/ssh/$f"
  link="$SSH_DIR/$f"
  if [[ ! -e "$target" ]]; then
    warn "$target not found in shared store — skipping $f"
    continue
  fi
  if [[ -L "$link" ]]; then
    log "$f: already a symlink — skipping"
  elif [[ -f "$link" ]]; then
    mv "$link" "${link}.bak"
    log "$f: backed up → ${link}.bak"
    ln -sf "$target" "$link"
    log "$f: symlinked"
  else
    ln -sf "$target" "$link"
    log "$f: symlinked"
  fi
done
chown -h "$MOUNT_USER:$MOUNT_USER" \
  "$SSH_DIR/config" "$SSH_DIR/known_hosts" "$SSH_DIR/authorized_keys" \
  "$SSH_DIR/id_ed25519" "$SSH_DIR/id_ed25519.pub" 2>/dev/null || true

# ─── 5. Add wsl2-<DISTRO_NAME> host block to shared config ───────────────────

if [[ -n "$DISTRO_NAME" ]]; then
  ALIAS="wsl2-${DISTRO_NAME}"
  CONFIG="$SSH_DIR/config"
  if [[ -z "$WIN_HOSTNAME" ]]; then
    WIN_HOST=$(/mnt/c/Windows/System32/cmd.exe /c hostname 2>/dev/null | tr -d '\r\n' | tr '[:upper:]' '[:lower:]' || true)
    WIN_HOSTNAME="${WIN_HOST:-localhost}.local"
  fi

  if grep -q "^Host $ALIAS" "$CONFIG" 2>/dev/null; then
    log "$ALIAS already in config"
  elif [[ -f "$CONFIG" ]]; then
    printf '\nHost %s\n    HostName %s\n    User %s\n    Port %s\n    IdentityFile ~/.ssh/id_ed25519\n    IdentitiesOnly yes\n' \
      "$ALIAS" "$WIN_HOSTNAME" "$MOUNT_USER" "$SSH_PORT" >> "$CONFIG"
    log "$ALIAS added to config (HostName $WIN_HOSTNAME) — written directly to shared store via CIFS"
  fi
fi

log "setup-shared-ssh.sh complete"
