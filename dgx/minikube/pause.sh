#!/usr/bin/env bash
set -euo pipefail

echo "Pausing minikube (freezes workloads, preserves cluster state)..."
minikube pause
echo "Done — run resume.sh to unfreeze"
