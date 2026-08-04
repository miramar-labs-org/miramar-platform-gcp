#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }

POSTGRES_NS="${POSTGRES_NS:-postgres-system}"
DELETE_NS="${DELETE_NS:-false}"

log "Destroying Postgres in namespace '${POSTGRES_NS}'"

log "Deleting Postgres resources"
kubectl -n "${POSTGRES_NS}" delete deploy/postgres svc/postgres pvc/postgres-pvc --ignore-not-found

log "Deleting any leftover pods in '${POSTGRES_NS}' (best-effort)"
kubectl -n "${POSTGRES_NS}" delete pod --all --ignore-not-found >/dev/null 2>&1 || true

if [[ "${DELETE_NS}" == "true" ]]; then
  log "Deleting namespace '${POSTGRES_NS}' (this also deletes the postgres-superuser Secret)"
  kubectl delete ns "${POSTGRES_NS}" --ignore-not-found
else
  log "Keeping namespace '${POSTGRES_NS}' (set DELETE_NS=true to remove it)"
fi

log "Done. Remaining objects:"
kubectl -n "${POSTGRES_NS}" get all 2>/dev/null || true

log "Note: the underlying PersistentVolume (Retain policy) and its hostPath data are untouched."
