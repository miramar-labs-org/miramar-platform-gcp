#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/systemd/user"
# minikube first — port-forward services depend on it
SERVICES=(minikube minikube-hf-cache-mount dashboard jupyterlab mlflow-portfwd kubeflow-portfwd kfp-api-portfwd nemo-portfwd qdrant-portfwd)

mkdir -p "$DEST"

# Enable linger so user services start on boot without requiring an interactive login
loginctl enable-linger "$(id -un)"

for svc in "${SERVICES[@]}"; do
    echo "Installing ${svc}.service..."
    cp "${SCRIPT_DIR}/${svc}.service" "${DEST}/${svc}.service"
done

systemctl --user daemon-reload

for svc in "${SERVICES[@]}"; do
    systemctl --user enable "${svc}"
    systemctl --user restart "${svc}"
    printf '  %-22s %s\n' "${svc}" "$(systemctl --user is-active ${svc})"
done
