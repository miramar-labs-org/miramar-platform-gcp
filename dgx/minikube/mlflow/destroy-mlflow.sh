#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }

# Defaults (override via env if you used different names)
MLFLOW_NS="${MLFLOW_NS:-mlflow-system}"
MLFLOW_RELEASE="${MLFLOW_RELEASE:-mlflow-tracking}"   # community-charts/mlflow
MINIO_RELEASE="${MINIO_RELEASE:-minio}"               # if you ever installed via Helm
DELETE_NS="${DELETE_NS:-false}"                       # set true to delete namespace too

log "Destroying MLflow + MinIO in namespace '${MLFLOW_NS}'"

log "Uninstalling MLflow Helm release (if present): ${MLFLOW_RELEASE}"
helm -n "${MLFLOW_NS}" uninstall "${MLFLOW_RELEASE}" >/dev/null 2>&1 || true

log "Uninstalling MinIO Helm release (if present): ${MINIO_RELEASE}"
helm -n "${MLFLOW_NS}" uninstall "${MINIO_RELEASE}" >/dev/null 2>&1 || true

log "Deleting MinIO resources deployed via YAML (if present)"
kubectl -n "${MLFLOW_NS}" delete deploy/minio svc/minio pvc/minio-pvc secret/minio-creds \
  job/minio-make-mlflow-bucket --ignore-not-found

log "Deleting any leftover pods/jobs in '${MLFLOW_NS}' (best-effort)"
kubectl -n "${MLFLOW_NS}" delete pod,job --all --ignore-not-found >/dev/null 2>&1 || true

if [[ "${DELETE_NS}" == "true" ]]; then
  log "Deleting namespace '${MLFLOW_NS}' (this removes EVERYTHING in it)"
  kubectl delete ns "${MLFLOW_NS}" --ignore-not-found
else
  log "Keeping namespace '${MLFLOW_NS}' (set DELETE_NS=true to remove it)"
fi

log "Done. Remaining objects:"
kubectl -n "${MLFLOW_NS}" get all 2>/dev/null || true
