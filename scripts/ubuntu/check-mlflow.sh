#!/usr/bin/env bash
set -euo pipefail

DGX_HOST_IP="${DGX_HOST_IP:?Set DGX_HOST_IP to the DGX static IP}"
DGX_USER="${USER}"
MLFLOW_PORT=5000

echo "==> Checking MLflow service on DGX (${DGX_HOST_IP})..."
SERVICE_STATUS=$(ssh "${DGX_USER}@${DGX_HOST_IP}" "systemctl is-active mlflow 2>/dev/null || echo inactive")
if [[ "${SERVICE_STATUS}" == "active" ]]; then
    echo "    Service : active ✓"
else
    echo "    Service : ${SERVICE_STATUS} ✗"
fi

echo ""
echo "==> Checking SSH tunnel (localhost:${MLFLOW_PORT})..."
if curl -fsSL --max-time 3 "http://localhost:${MLFLOW_PORT}/" -o /dev/null 2>/dev/null; then
    echo "    Tunnel  : up ✓"
    echo "    UI      : http://localhost:${MLFLOW_PORT}"
else
    echo "    Tunnel  : not reachable ✗"
    echo ""
    echo "    To open tunnel:"
    echo "    ssh -L ${MLFLOW_PORT}:localhost:${MLFLOW_PORT} ${DGX_USER}@${DGX_HOST_IP}"
fi
