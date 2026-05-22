#!/usr/bin/env bash
set -euo pipefail

PROXY_PORT=8001
PROXY_LOG="$HOME/kubectl-proxy.log"
DGX_HOST="spark-79b7.local"

# Start minikube if not already running
STATUS=$(minikube status --format='{{.Host}}' 2>/dev/null || echo "Stopped")
if [ "$STATUS" = "Running" ]; then
    echo "minikube already running"
else
    echo "Starting minikube..."
    minikube start
fi

# Enable dashboard and metrics-server addons (idempotent)
minikube addons enable dashboard     > /dev/null 2>&1 || true
minikube addons enable metrics-server > /dev/null 2>&1 || true

# Start kubectl proxy if not already running
if pgrep -f "kubectl.*proxy.*${PROXY_PORT}" > /dev/null 2>&1; then
    echo "kubectl proxy already running on :${PROXY_PORT}"
else
    echo "Starting kubectl proxy on :${PROXY_PORT}..."
    nohup kubectl --context minikube proxy --port="${PROXY_PORT}" --address=127.0.0.1 \
        > "${PROXY_LOG}" 2>&1 &
    PROXY_PID=$!
    sleep 1
    echo "Proxy started (PID: ${PROXY_PID}, log: ${PROXY_LOG})"
fi

printf '\nSSH tunnel from your laptop:\n'
printf '  ssh -L %s:localhost:%s <user>@%s\n\n' "${PROXY_PORT}" "${PROXY_PORT}" "${DGX_HOST}"
printf 'Dashboard:\n'
printf '  http://localhost:%s/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/\n\n' "${PROXY_PORT}"
