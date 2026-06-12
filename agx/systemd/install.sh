#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Service unit files live in dgx/systemd/ — AGX runs the identical stack on the same host ports.
# The SSH tunnel from the laptop uses offset local ports to avoid conflicts with the DGX tunnel.
DGX_SYSTEMD="$(cd "${SCRIPT_DIR}/../../dgx/systemd" && pwd)"
DEST="$HOME/.config/systemd/user"
# k3s is managed by its own systemd service (k3s.service, installed by install-k3s.sh).
# Port-forward services declare After=k3s.service so they start in the right order.
SERVICES=(dashboard jupyterlab mlflow-portfwd kubeflow-portfwd kfp-api-portfwd nemo-portfwd qdrant-portfwd nsight-portfwd)

mkdir -p "$DEST"

# Enable linger so user services start on boot without requiring an interactive login
loginctl enable-linger "$(id -un)"

for svc in "${SERVICES[@]}"; do
    echo "Installing ${svc}.service..."
    cp "${DGX_SYSTEMD}/${svc}.service" "${DEST}/${svc}.service"
done

systemctl --user daemon-reload

for svc in "${SERVICES[@]}"; do
    systemctl --user enable "${svc}"
    systemctl --user restart "${svc}"
    printf '  %-22s %s\n' "${svc}" "$(systemctl --user is-active ${svc})"
done
