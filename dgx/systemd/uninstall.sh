#!/usr/bin/env bash
set -euo pipefail

DEST="$HOME/.config/systemd/user"
# Stop in reverse dependency order (dependents first)
# k3s.service is not managed here — use the K3s Uninstall workflow to remove k3s itself.
SERVICES=(nsight-portfwd qdrant-portfwd nemo-portfwd kfp-api-portfwd kubeflow-portfwd mlflow-portfwd jupyterlab dashboard)

for svc in "${SERVICES[@]}"; do
    echo "Removing ${svc}..."
    systemctl --user stop    "${svc}" 2>/dev/null || true
    systemctl --user disable "${svc}" 2>/dev/null || true
    rm -f "${DEST}/${svc}.service"
done

systemctl --user daemon-reload
echo "Done"
