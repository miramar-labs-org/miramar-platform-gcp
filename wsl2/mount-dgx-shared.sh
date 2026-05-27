#!/usr/bin/env bash
# Mount the DGX shared Samba folder after WSL2 has finished booting.
#
# Do not put this CIFS mount in /etc/fstab on WSL2. WSL's pre-systemd fstab
# handling can block on mDNS/CIFS during early boot, disrupt the Plan 9/p9io
# channel, and produce:
#   Operation canceled @p9io.cpp:258 (AcceptAsync)
#   System is powering down.

set -euo pipefail

CONFIG=/etc/mount-dgx-shared.conf
MOUNT_USER="${DGX_MOUNT_USER:-aaron}"
DGX_CIFS_HOST="${DGX_CIFS_HOST:-}"

log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

if [[ -f "$CONFIG" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG"
fi
MOUNT_USER="${DGX_MOUNT_USER:-$MOUNT_USER}"
DGX_CIFS_HOST="${DGX_CIFS_HOST:-}"

if [[ $# -gt 0 && -n "${1:-}" ]]; then
  DGX_CIFS_HOST="$1"
fi

USER_HOME=$(getent passwd "$MOUNT_USER" | cut -d: -f6 || true)
if [[ -z "$USER_HOME" ]]; then
  warn "User $MOUNT_USER not found"
  exit 0
fi

SHARED_DIR="$USER_HOME/shared"
CREDS="$USER_HOME/.smbcredentials"
UID_NUM=$(id -u "$MOUNT_USER")
GID_NUM=$(id -g "$MOUNT_USER")

if [[ -z "$DGX_CIFS_HOST" ]]; then
  warn "DGX_CIFS_HOST is not configured in $CONFIG"
  exit 0
fi

if [[ ! -f "$CREDS" ]]; then
  warn "$CREDS not found"
  exit 0
fi

mkdir -p "$SHARED_DIR"
chown "$MOUNT_USER:$MOUNT_USER" "$SHARED_DIR"

if mountpoint -q "$SHARED_DIR" 2>/dev/null; then
  log "$SHARED_DIR already mounted"
  exit 0
fi

resolve_host() {
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
    warn "$host is not in /etc/hosts; refusing mDNS .local for CIFS"
    return 1
  fi

  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}'
}

DGX_IP=$(resolve_host "$DGX_CIFS_HOST" || true)
if [[ -z "$DGX_IP" ]]; then
  warn "Could not resolve $DGX_CIFS_HOST to a non-mDNS IPv4 address"
  exit 0
fi

if ! timeout 3 ping -c 1 -W 1 "$DGX_IP" >/dev/null 2>&1; then
  warn "$DGX_IP unreachable; will retry on the next timer tick"
  exit 0
fi

OPTS="credentials=$CREDS,uid=$UID_NUM,gid=$GID_NUM,vers=3.0,file_mode=0600,dir_mode=0700,noperm"
if timeout 8 mount -t cifs "//$DGX_IP/shared" "$SHARED_DIR" -o "$OPTS"; then
  log "Mounted //$DGX_IP/shared at $SHARED_DIR"
else
  warn "Mount failed for //$DGX_IP/shared"
fi
