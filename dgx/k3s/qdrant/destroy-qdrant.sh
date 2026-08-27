#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }

QDRANT_NS="${QDRANT_NS:-qdrant-system}"
DELETE_NS="${DELETE_NS:-false}"

log "Destroying Qdrant in namespace '${QDRANT_NS}'"

log "Deleting Qdrant resources"
kubectl -n "${QDRANT_NS}" delete deploy/qdrant svc/qdrant pvc/qdrant-pvc \
  --ignore-not-found

log "Deleting any leftover pods in '${QDRANT_NS}' (best-effort)"
kubectl -n "${QDRANT_NS}" delete pod --all --ignore-not-found >/dev/null 2>&1 || true

if [[ "${DELETE_NS}" == "true" ]]; then
  log "Deleting namespace '${QDRANT_NS}'"
  kubectl delete ns "${QDRANT_NS}" --ignore-not-found
else
  log "Keeping namespace '${QDRANT_NS}' (set DELETE_NS=true to remove it)"
fi

log "Done. Remaining objects:"
kubectl -n "${QDRANT_NS}" get all 2>/dev/null || true
