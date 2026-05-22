#!/usr/bin/env bash
set -euo pipefail

DEST="$HOME/.config/systemd/user"
SERVICES=(dashboard jupyterlab mlflow-portfwd)

for svc in "${SERVICES[@]}"; do
    echo "Removing ${svc}..."
    systemctl --user stop    "${svc}" 2>/dev/null || true
    systemctl --user disable "${svc}" 2>/dev/null || true
    rm -f "${DEST}/${svc}.service"
done

systemctl --user daemon-reload
echo "Done"
