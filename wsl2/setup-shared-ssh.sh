#!/bin/bash
# setup-shared-ssh.sh — join the lab SSH mesh from inside a WSL2 distro.
#
# Usage (run as root):
#   setup-shared-ssh.sh <DGX_HOST_IP> <USER> [DISTRO_NAME] [SSH_PORT] [WINDOWS_HOST]
#
# Configures the post-boot DGX CIFS mount service, mounts once immediately,
# then symlinks SSH files (config, known_hosts, authorized_keys, id_ed25519,
# id_ed25519.pub) to the shared store. All machines share Spark's SSH identity.
# Idempotent: safe to run multiple times.

set -euo pipefail

DGX_HOST_IP="${1:-}"
MOUNT_USER="${2:-${SUDO_USER:-$USER}}"
DISTRO_NAME="${3:-$(cat /etc/wsl2-distro-name 2>/dev/null || true)}"
SSH_PORT="${4:-2222}"
WIN_HOSTNAME="${5:-}"  # Windows host for SSH config HostName (e.g. msi.local or IP)

USER_HOME=$(getent passwd "$MOUNT_USER" | cut -d: -f6)
CREDS="$USER_HOME/.smbcredentials"
SSH_DIR="$USER_HOME/.ssh"
SHARED_DIR="$USER_HOME/shared"
MOUNT_CONF=/etc/mount-dgx-shared.conf
MOUNT_HELPER=/usr/local/sbin/mount-dgx-shared.sh

log()  { echo "==> $*"; }
warn() { echo "WARN: $*"; }

resolve_cifs_host() {
  local host="$1"
  local ip=""

  if [[ "$host" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    printf '%s\n' "$host"
    return 0
  fi

  ip=$(awk -v host="$host" '
    $1 !~ /^#/ {
      for (i = 2; i <= NF; i++) {
        if ($i == host) {
          print $1
          exit
        }
      }
    }
  ' /etc/hosts 2>/dev/null || true)
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  if [[ "$host" == *.local ]]; then
    return 1
  fi

  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'
}

# ─── 1. Prerequisites ────────────────────────────────────────────────────────

if [[ ! -f "$CREDS" ]]; then
  echo "ERROR: $CREDS not found — run rebuild-template.ps1 to bake credentials into the template" >&2
  exit 1
fi

if ! command -v mount.cifs >/dev/null 2>&1; then
  log "Installing cifs-utils..."
  apt-get install -y --no-install-recommends cifs-utils
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$MOUNT_USER:$MOUNT_USER" "$SSH_DIR"

# ─── 2. Resolve DGX source without boot-time mDNS ────────────────────────────

DGX_CIFS_HOST=$(resolve_cifs_host "$DGX_HOST_IP" || true)
if [[ -z "$DGX_CIFS_HOST" ]]; then
  warn "$DGX_HOST_IP is not a static IP or /etc/hosts-resolved name; mount timer will wait for a safe source"
else
  log "CIFS service will use: $DGX_CIFS_HOST"
fi

# ─── 3. CIFS mount ───────────────────────────────────────────────────────────

mkdir -p "$SHARED_DIR"
chown "$MOUNT_USER:$MOUNT_USER" "$SHARED_DIR"

# Filter by mount point (handles stale entries with either hostname or IP).
# Do not write CIFS mounts to /etc/fstab on WSL2. WSL pre-systemd fstab
# handling and mDNS/CIFS can delay boot or disrupt p9io/Plan9, causing
# AcceptAsync canceled followed by distro powerdown.
grep -v " $SHARED_DIR " /etc/fstab > /tmp/fstab.new 2>/dev/null || true
cp /tmp/fstab.new /etc/fstab && rm -f /tmp/fstab.new
log "Removed legacy CIFS fstab entry for $SHARED_DIR"

cat > "$MOUNT_CONF" <<EOF
DGX_MOUNT_USER=$MOUNT_USER
DGX_CIFS_HOST=$DGX_CIFS_HOST
EOF
chmod 644 "$MOUNT_CONF"
log "Wrote $MOUNT_CONF"

if [[ -f /etc/systemd/system/mount-dgx-shared.timer ]]; then
  systemctl enable /etc/systemd/system/mount-dgx-shared.timer >/dev/null 2>&1 || true
  systemctl start mount-dgx-shared.timer >/dev/null 2>&1 || true
  log "Enabled mount-dgx-shared.timer"
else
  warn "mount-dgx-shared.timer is not installed"
fi

if [[ -x "$MOUNT_HELPER" ]]; then
  "$MOUNT_HELPER"
else
  warn "$MOUNT_HELPER is not installed"
fi

# ─── 4. Symlink SSH files to the shared store ────────────────────────────────

log "Symlinking $SSH_DIR files to $SHARED_DIR/ssh/..."
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
    if [[ -n "$WIN_HOST" ]]; then
      WIN_HOSTNAME="$WIN_HOST.local"
    else
      warn "Windows host not provided and could not be detected; skipping $ALIAS SSH config block"
    fi
  fi

  if [[ -n "$WIN_HOSTNAME" ]]; then
    if [[ -f "$CONFIG" ]]; then
      if grep -q "^Host $ALIAS" "$CONFIG" 2>/dev/null; then
        awk -v alias="$ALIAS" '
          $1 == "Host" && $2 == alias { skip = 1; next }
          $1 == "Host" { skip = 0 }
          !skip { print }
        ' "$CONFIG" > /tmp/ssh-config.new
        cat /tmp/ssh-config.new > "$CONFIG"
        rm -f /tmp/ssh-config.new
        log "$ALIAS existing config block removed"
      fi
      printf '\nHost %s\n    HostName %s\n    User %s\n    IdentityFile %s/.ssh/id_ed25519\n    IdentitiesOnly yes\n    ProxyCommand ssh -q -i %s/.ssh/id_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new %s@%s "wsl -d %s --user root --exec /bin/bash -lc '\''/usr/local/sbin/mount-dgx-shared.sh >/dev/null 2>&1 || true; exec /usr/sbin/sshd -i -e'\''"\n' \
        "$ALIAS" "$ALIAS" "$MOUNT_USER" "$USER_HOME" "$USER_HOME" "$MOUNT_USER" "$WIN_HOSTNAME" "$DISTRO_NAME" >> "$CONFIG"
      log "$ALIAS added to config (on-demand via $WIN_HOSTNAME wsl.exe) — written directly to shared store via CIFS"
    fi
  fi
fi

log "setup-shared-ssh.sh complete"
