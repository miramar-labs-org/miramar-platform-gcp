#!/usr/bin/env bash
set -euo pipefail
# Restart all DGX user services in dependency order.

SERVICES=(minikube dashboard jupyterlab mlflow-portfwd)

for svc in "${SERVICES[@]}"; do
    echo "Restarting ${svc}..."
    systemctl --user restart "${svc}"
    printf '  %-22s %s\n' "${svc}" "$(systemctl --user is-active ${svc})"
done
