#!/bin/bash
# firstboot.sh — one-shot provisioning run inside a WSL2 distro.
# Called by provision-wsl2.yaml via Windows SSH → wsl exec (not port-2222 SSH).
# Reads /etc/wsl2-provision.conf; safe to re-run after partial failure.
#
# /etc/wsl2-provision.conf (bash key=value):
#   distro_name=dev
#   ssh_port=2222
#   mount_user=aaron
#   dgx_host_ip=192.0.2.10
#   wsl_host=msi.local

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
DGX_HOST_IP="${dgx_host_ip:-}"
WIN_HOSTNAME="${wsl_host:-}"

log "Provisioning $DISTRO_NAME (port: $SSH_PORT, user: $MOUNT_USER)"
if [[ -z "$DGX_HOST_IP" ]]; then
  echo "ERROR: dgx_host_ip is required in $CONF" >&2
  exit 1
fi

# 0. Wait for systemd/D-Bus to be ready before any systemctl-dependent work.
# Do not continue after exhaustion: a green firstboot while systemd is still
# starting hides the WSL lifecycle failure we are trying to debug.
log "Waiting for systemd..."
SYSTEMD_STATE=""
for i in $(seq 1 90); do
  SYSTEMD_STATE="$(systemctl is-system-running 2>&1 || true)"
  echo "  systemd: $SYSTEMD_STATE ($i/90)"
  if [[ "$SYSTEMD_STATE" =~ ^(running|degraded)$ ]]; then
    break
  fi
  sleep 2
done
if [[ ! "$SYSTEMD_STATE" =~ ^(running|degraded)$ ]]; then
  echo "ERROR: systemd did not become ready (last state: $SYSTEMD_STATE)" >&2
  systemctl --failed --no-pager || true
  journalctl -b -n 120 --no-pager || true
  exit 1
fi

# 1. Remove legacy wsl2-ssh-setup.service if present (older bootstrap.sh
#    installed a boot-time service that ran setup-shared-ssh.sh on every boot;
#    that role is now handled by firstboot.sh once at provision time).
if systemctl list-unit-files wsl2-ssh-setup.service &>/dev/null; then
  log "Removing legacy wsl2-ssh-setup.service"
  systemctl disable wsl2-ssh-setup.service 2>/dev/null || true
  rm -f /etc/systemd/system/wsl2-ssh-setup.service
fi

# 2. Hostname
log "Setting hostname → $DISTRO_NAME"
printf '%s\n' "$DISTRO_NAME" > /etc/hostname
hostname "$DISTRO_NAME"
if ! grep -q '^\[network\]' /etc/wsl.conf 2>/dev/null; then
  printf '\n[network]\nhostname = %s\n' "$DISTRO_NAME" >> /etc/wsl.conf
fi

# 3. sshd port
log "Setting sshd port → $SSH_PORT"
mkdir -p /etc/ssh/sshd_config.d
printf 'Port %s\n' "$SSH_PORT" > /etc/ssh/sshd_config.d/wsl2-port.conf
# Skip the restart when sshd is already listening on the target port.
# Avoiding unnecessary restarts reduces the risk of disrupting WSL2's internal
# P9 connection in mirrored-networking mode (same mechanism as daemon-reload).
if ss -tlnp "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then
  log "sshd already on port $SSH_PORT — skipping restart"
else
  log "sshd not yet on port $SSH_PORT — restarting"
  systemctl restart ssh
fi

# 4. Post-boot CIFS mount service + SSH symlinks into /home/aaron/shared/ssh/
log "Running setup-shared-ssh.sh"
/usr/local/bin/setup-shared-ssh.sh "$DGX_HOST_IP" "$MOUNT_USER" "$DISTRO_NAME" "$SSH_PORT" "$WIN_HOSTNAME"

log "First-boot complete"
