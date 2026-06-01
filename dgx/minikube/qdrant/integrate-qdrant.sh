#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log()  { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
die()  { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

need kubectl

log "Starting Qdrant deployment"

# ---- Config ----
QDRANT_NS="${QDRANT_NS:-qdrant-system}"
QDRANT_IMAGE="${QDRANT_IMAGE:-qdrant/qdrant:latest}"
QDRANT_PVC_SIZE="${QDRANT_PVC_SIZE:-20Gi}"
QDRANT_STORAGE_CLASS="${QDRANT_STORAGE_CLASS:-standard}"

# ---- Ensure namespace ----
log "Ensuring namespace ${QDRANT_NS} exists"
kubectl get ns "${QDRANT_NS}" >/dev/null 2>&1 || kubectl create ns "${QDRANT_NS}"

# ---- Deploy ----
log "Applying Qdrant manifests (image: ${QDRANT_IMAGE})"
kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: qdrant-pvc
  namespace: ${QDRANT_NS}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: ${QDRANT_PVC_SIZE}
  storageClassName: ${QDRANT_STORAGE_CLASS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qdrant
  namespace: ${QDRANT_NS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: qdrant }
  template:
    metadata:
      labels: { app: qdrant }
    spec:
      containers:
        - name: qdrant
          image: ${QDRANT_IMAGE}
          ports:
            - containerPort: 6333
            - containerPort: 6334
          volumeMounts:
            - name: data
              mountPath: /qdrant/storage
          readinessProbe:
            httpGet:
              path: /health
              port: 6333
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: qdrant-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: qdrant
  namespace: ${QDRANT_NS}
spec:
  selector: { app: qdrant }
  ports:
    - name: rest
      port: 6333
      targetPort: 6333
    - name: grpc
      port: 6334
      targetPort: 6334
YAML

log "Waiting for Qdrant to be ready"
kubectl -n "${QDRANT_NS}" rollout status deploy/qdrant --timeout=5m

log "✅ Complete"
echo "Qdrant REST (in-cluster): http://qdrant.${QDRANT_NS}.svc.cluster.local:6333"
echo "Qdrant gRPC (in-cluster): qdrant.${QDRANT_NS}.svc.cluster.local:6334"
echo ""
echo "Local access (after port-forward or SSH tunnel):"
echo "  REST API + dashboard: http://localhost:6333"
echo "  Web UI:               http://localhost:6333/dashboard"
