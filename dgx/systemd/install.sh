#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/systemd/user"
SERVICES=(dashboard jupyterlab mlflow-portfwd)

mkdir -p "$DEST"

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
