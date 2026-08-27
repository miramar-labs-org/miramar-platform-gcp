#!/usr/bin/env bash
# Lightweight MLflow config update — helm upgrade --reuse-values.
# Use this for config-only changes (env vars, flags) that don't require
# re-running the full NeMo integration in integrate-mlflow.sh.
set -euo pipefail

MLFLOW_NS="mlflow-system"
MLFLOW_RELEASE="mlflow-tracking"
# Pin the chart — community-charts/mlflow >= 1.9 ships a stricter values.schema.json
# that rejects a --reuse-values upgrade of a release created on an older chart
# (missing 'deploymentAnnotations', 'priorityClassName', 'extraDeploy',
# 'backendStore.mssql.*', 'image.digest'). Keep this in lock-step with
# integrate-mlflow.sh.
MLFLOW_CHART_VERSION="${MLFLOW_CHART_VERSION:-1.8.5}"

helm repo add community-charts https://community-charts.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade "${MLFLOW_RELEASE}" community-charts/mlflow \
  --version "${MLFLOW_CHART_VERSION}" \
  -n "${MLFLOW_NS}" \
  --reuse-values \
  --set "extraEnvVars.MLFLOW_SERVER_ALLOWED_HOSTS=*" \
  --wait --timeout 5m

echo "MLflow redeployed"
