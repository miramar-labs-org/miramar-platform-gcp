#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log()  { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
die()  { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

need kubectl
need openssl

log "Starting Postgres deployment"

POSTGRES_NS="${POSTGRES_NS:-postgres-system}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16-alpine}"
POSTGRES_PVC_SIZE="${POSTGRES_PVC_SIZE:-20Gi}"
POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-${HOME}/shared/postgres-data}"
POSTGRES_PV_NAME="${POSTGRES_PV_NAME:-postgres-pv}"

# Optional per-consumer database/role provisioning -- set both to provision an app database.
POSTGRES_CONSUMER_DB="${POSTGRES_CONSUMER_DB:-}"
POSTGRES_CONSUMER_USER="${POSTGRES_CONSUMER_USER:-}"
POSTGRES_CONSUMER_PASSWORD="${POSTGRES_CONSUMER_PASSWORD:-}"

log "Ensuring namespace ${POSTGRES_NS} exists"
kubectl get ns "${POSTGRES_NS}" >/dev/null 2>&1 || kubectl create ns "${POSTGRES_NS}"

mkdir -p "${POSTGRES_DATA_DIR}" 2>/dev/null || true

log "Ensuring superuser credentials Secret exists"
if ! kubectl -n "${POSTGRES_NS}" get secret postgres-superuser >/dev/null 2>&1; then
  SUPERUSER_PASSWORD="$(openssl rand -base64 24)"
  kubectl -n "${POSTGRES_NS}" create secret generic postgres-superuser \
    --from-literal=POSTGRES_PASSWORD="${SUPERUSER_PASSWORD}"
  log "Generated new superuser password (stored in Secret postgres-superuser/POSTGRES_PASSWORD)"
else
  log "Secret postgres-superuser already exists -- reusing it"
fi

# Clear stale claimRef on a Released PV (left by a prior undeploy with Retain policy)
if kubectl get pv "${POSTGRES_PV_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Released"; then
  log "Clearing stale claimRef on Released PV ${POSTGRES_PV_NAME}"
  kubectl patch pv "${POSTGRES_PV_NAME}" -p '{"spec":{"claimRef":null}}' --type=merge
fi

log "Applying Postgres manifests (image: ${POSTGRES_IMAGE})"
kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${POSTGRES_PV_NAME}
spec:
  capacity: { storage: ${POSTGRES_PVC_SIZE} }
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath: { path: ${POSTGRES_DATA_DIR}, type: DirectoryOrCreate }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: postgres-pvc, namespace: ${POSTGRES_NS} }
spec:
  accessModes: ["ReadWriteOnce"]
  resources: { requests: { storage: ${POSTGRES_PVC_SIZE} } }
  storageClassName: ""
  volumeName: ${POSTGRES_PV_NAME}
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: postgres, namespace: ${POSTGRES_NS} }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      containers:
        - name: postgres
          image: ${POSTGRES_IMAGE}
          ports: [{ containerPort: 5432 }]
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: { name: postgres-superuser, key: POSTGRES_PASSWORD }
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts: [{ name: data, mountPath: /var/lib/postgresql/data }]
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "postgres"] }
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            exec: { command: ["pg_isready", "-U", "postgres"] }
            initialDelaySeconds: 15
            periodSeconds: 10
      volumes: [{ name: data, persistentVolumeClaim: { claimName: postgres-pvc } }]
---
apiVersion: v1
kind: Service
metadata: { name: postgres, namespace: ${POSTGRES_NS} }
spec:
  selector: { app: postgres }
  ports:
    - { name: postgres, port: 5432, targetPort: 5432 }
YAML

log "Waiting for Postgres to be ready"
kubectl -n "${POSTGRES_NS}" rollout status deploy/postgres --timeout=5m

if [[ -n "${POSTGRES_CONSUMER_DB}" && -n "${POSTGRES_CONSUMER_USER}" ]]; then
  log "Provisioning consumer database '${POSTGRES_CONSUMER_DB}' / role '${POSTGRES_CONSUMER_USER}'"

  if [[ -z "${POSTGRES_CONSUMER_PASSWORD}" ]]; then
    POSTGRES_CONSUMER_PASSWORD="$(openssl rand -base64 24)"
  fi

  # \gexec runs the CREATE only if the SELECT found no existing row -- safe to re-run. The role's
  # password is set only at creation time so re-running this script never resets an already-issued
  # app credential.
  kubectl -n "${POSTGRES_NS}" exec deploy/postgres -- psql -U postgres -v ON_ERROR_STOP=1 <<SQL
SELECT 'CREATE DATABASE ${POSTGRES_CONSUMER_DB}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POSTGRES_CONSUMER_DB}')\gexec

SELECT 'CREATE ROLE ${POSTGRES_CONSUMER_USER} LOGIN PASSWORD ''${POSTGRES_CONSUMER_PASSWORD}'''
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${POSTGRES_CONSUMER_USER}')\gexec

GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_CONSUMER_DB} TO ${POSTGRES_CONSUMER_USER};
SQL

  # PG15+ no longer grants CREATE on the public schema to all roles by default.
  kubectl -n "${POSTGRES_NS}" exec deploy/postgres -- \
    psql -U postgres -d "${POSTGRES_CONSUMER_DB}" -v ON_ERROR_STOP=1 \
    -c "GRANT ALL ON SCHEMA public TO ${POSTGRES_CONSUMER_USER};"

  log "✅ Consumer database ready"
  echo "DATABASE_URL=postgresql://${POSTGRES_CONSUMER_USER}:${POSTGRES_CONSUMER_PASSWORD}@postgres.${POSTGRES_NS}.svc.cluster.local:5432/${POSTGRES_CONSUMER_DB}"
  echo "(Copy this into the consumer app's secret -- it is not stored anywhere else.)"
fi

log "✅ Complete"
echo "Postgres (in-cluster): postgres.${POSTGRES_NS}.svc.cluster.local:5432"
echo ""
echo "Ad hoc access: kubectl -n ${POSTGRES_NS} exec -it deploy/postgres -- psql -U postgres"
