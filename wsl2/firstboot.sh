#!/bin/bash
# firstboot.sh — one-shot provisioning run inside a WSL2 distro.
# Called by provision-wsl2.yaml via Windows SSH → wsl exec (not port-2222 SSH).
# Reads /etc/wsl2-provision.conf; safe to re-run after partial failure.
#
# /etc/wsl2-provision.conf (bash key=value):
#   distro_name=dev
#   ssh_port=2222
#   mount_user=aaron
#   dgx_host=192.0.2.10

set -euo pipefail

CONF=/etc/wsl2-provision.conf
if [[ ! -f "$CONF" ]]; then
  echo "ERROR: $CONF not found" >&2
  exit 1
fi

log() { echo "==> $*"; }

# shellcheck source=/dev/null
source "$CONF"

DISTRO_NAME="${distro_name:?distro_name required}"
SSH_PORT="${ssh_port:-2222}"
MOUNT_USER="${mount_user:-aaron}"
DGX_HOST="${dgx_host:-spark-79b7.local}"

log "Provisioning $DISTRO_NAME (port: $SSH_PORT, user: $MOUNT_USER)"

# 0. Remove legacy wsl2-ssh-setup.service if present (older bootstrap.sh
#    installed a boot-time service that ran setup-shared-ssh.sh on every boot;
#    that role is now handled by firstboot.sh once at provision time).
if systemctl list-unit-files wsl2-ssh-setup.service &>/dev/null; then
  log "Removing legacy wsl2-ssh-setup.service"
  systemctl disable wsl2-ssh-setup.service 2>/dev/null || true
  rm -f /etc/systemd/system/wsl2-ssh-setup.service
fi

# Wait for systemd/D-Bus to be ready (needed for systemctl)
log "Waiting for systemd..."
for i in $(seq 1 20); do
  systemctl is-system-running 2>/dev/null | grep -qE '^(running|degraded)$' && break
  echo "  ($i/20)"
  sleep 3
done

# 1. Hostname
log "Setting hostname → $DISTRO_NAME"
printf '%s\n' "$DISTRO_NAME" > /etc/hostname
hostname "$DISTRO_NAME"
if ! grep -q '^\[network\]' /etc/wsl.conf 2>/dev/null; then
  printf '\n[network]\nhostname = %s\n' "$DISTRO_NAME" >> /etc/wsl.conf
fi

# 2. sshd port
log "Setting sshd port → $SSH_PORT"
mkdir -p /etc/ssh/sshd_config.d
printf 'Port %s\n' "$SSH_PORT" > /etc/ssh/sshd_config.d/wsl2-port.conf
# Skip the restart when sshd is already listening on the target port.
# The template is pre-configured for port 2222 by bootstrap.sh, so this
# restart is a no-op for the common case. Avoiding unnecessary restarts
# reduces the risk of disrupting WSL2's internal P9 connection in
# mirrored-networking mode (same mechanism as daemon-reload).
if ss -tlnp "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then
  log "sshd already on port $SSH_PORT — skipping restart"
else
  log "sshd not yet on port $SSH_PORT — restarting"
  systemctl restart ssh
fi

# 3. Post-boot CIFS mount service + SSH symlinks into /home/aaron/shared/ssh/
log "Running setup-shared-ssh.sh"
/usr/local/bin/setup-shared-ssh.sh "$DGX_HOST" "$MOUNT_USER" "$DISTRO_NAME" "$SSH_PORT"

log "First-boot complete"
