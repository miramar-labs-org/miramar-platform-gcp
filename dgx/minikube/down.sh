#!/usr/bin/env bash
set -euo pipefail

PROXY_PORT=8001

# Stop kubectl proxy
if pgrep -f "kubectl.*proxy.*${PROXY_PORT}" > /dev/null 2>&1; then
    echo "Stopping kubectl proxy..."
    pkill -f "kubectl.*proxy.*${PROXY_PORT}" || true
else
    echo "kubectl proxy is not running"
fi

# Stop minikube
echo "Stopping minikube..."
minikube stop
echo "Done"
