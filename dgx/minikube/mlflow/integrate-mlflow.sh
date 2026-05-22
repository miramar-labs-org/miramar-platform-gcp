#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log()  { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
die()  { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }
rand_alnum() { (set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-24}"); }

need kubectl
need helm
need base64
need awk
need sed

log "Starting NeMo ↔ MLflow integration (Helm-values driven)"

# ---- Config ----
NEMO_RELEASE="nemo"
NEMO_NS="default"

MLFLOW_NS="mlflow-system"
MLFLOW_RELEASE="mlflow-tracking"     # results in svc/mlflow-tracking
MINIO_RELEASE="minio"                # used only for cleanup now; we deploy MinIO via YAML

# In-cluster URLs (stable DNS)
PG_HOST="nemo-postgresql.${NEMO_NS}.svc.cluster.local"
MINIO_SVC_DNS="minio.${MLFLOW_NS}.svc.cluster.local"
MLFLOW_SVC_DNS="${MLFLOW_RELEASE}.${MLFLOW_NS}.svc.cluster.local"

MLFLOW_TRACKING_URL="http://${MLFLOW_SVC_DNS}:80"
MLFLOW_S3_ENDPOINT_URL="http://${MINIO_SVC_DNS}:9000"

# You can override these via env vars if you want fixed credentials
MLFLOW_DB_NAME="${MLFLOW_DB_NAME:-mlflow}"
MLFLOW_DB_USER="${MLFLOW_DB_USER:-mlflow}"
MLFLOW_DB_PASSWORD="${MLFLOW_DB_PASSWORD:-$(rand_alnum 24)}"

# MinIO creds
MINIO_ROOT_USER="${MINIO_ROOT_USER:-mlflowadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-mlflowadmin12345678}"

# MinIO settings
MINIO_IMAGE="${MINIO_IMAGE:-minio/minio:RELEASE.2024-05-10T01-41-38Z}"
MINIO_PVC_SIZE="${MINIO_PVC_SIZE:-20Gi}"
MINIO_STORAGE_CLASS="${MINIO_STORAGE_CLASS:-standard}"
MINIO_BUCKET="${MINIO_BUCKET:-mlflow}"

# ---- Preflight: confirm NeMo release + nemo-postgresql exist ----
log "Checking NeMo Helm release exists: ${NEMO_RELEASE} in ${NEMO_NS}"
helm -n "${NEMO_NS}" status "${NEMO_RELEASE}" >/dev/null 2>&1 || die "Helm release ${NEMO_RELEASE} not found in ${NEMO_NS}"

log "Checking nemo-postgresql exists in ${NEMO_NS}"
kubectl -n "${NEMO_NS}" get svc nemo-postgresql >/dev/null 2>&1 || die "Service nemo-postgresql not found in ${NEMO_NS}"
kubectl -n "${NEMO_NS}" get secret nemo-postgresql >/dev/null 2>&1 || die "Secret nemo-postgresql not found in ${NEMO_NS}"

PG_POD="$(kubectl -n "${NEMO_NS}" get pods --no-headers | awk '$1 ~ /^nemo-postgresql/ {print $1; exit}')"
[[ -n "${PG_POD}" ]] || die "Could not find a pod starting with nemo-postgresql in ${NEMO_NS}"

# Extract postgres superuser password from NeMo secret (support multiple common keys)
get_b64() {
  local key="${1:-}"
  [[ -n "${key}" ]] || return 0
  # bracket form handles keys containing dashes
  kubectl -n "${NEMO_NS}" get secret nemo-postgresql -o "jsonpath={.data['${key}']}" 2>/dev/null || true
}

PG_ADMIN_PW_B64="$(get_b64 postgres-password)"
[[ -n "${PG_ADMIN_PW_B64}" ]] || PG_ADMIN_PW_B64="$(get_b64 password)"
[[ -n "${PG_ADMIN_PW_B64}" ]] || PG_ADMIN_PW_B64="$(get_b64 postgresql-postgres-password)"
[[ -n "${PG_ADMIN_PW_B64}" ]] || die "Couldn't find a postgres admin password key in secret nemo-postgresql (tried postgres-password, password, postgresql-postgres-password)"
PG_ADMIN_PW="$(printf "%s" "${PG_ADMIN_PW_B64}" | base64 -d)"

# ---- Ensure namespace for MLflow/MinIO ----
log "Ensuring namespace ${MLFLOW_NS} exists"
kubectl get ns "${MLFLOW_NS}" >/dev/null 2>&1 || kubectl create ns "${MLFLOW_NS}" >/dev/null

# ---- Create MLflow DB + user inside NeMo Postgres (Job-based) ----
log "Creating/ensuring DB '${MLFLOW_DB_NAME}' and user '${MLFLOW_DB_USER}' in NeMo Postgres (via Job)"

JOB_NAME="psql-mlflow-bootstrap"
kubectl -n "${NEMO_NS}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1 || true

kubectl -n "${NEMO_NS}" apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: psql
        image: postgres:16
        env:
        - name: PGHOST
          value: "${PG_HOST}"
        - name: PGPORT
          value: "5432"
        - name: PGUSER
          value: "postgres"
        - name: PGPASSWORD
          value: "${PG_ADMIN_PW}"
        - name: MLFLOW_DB_USER
          value: "${MLFLOW_DB_USER}"
        - name: MLFLOW_DB_PASSWORD
          value: "${MLFLOW_DB_PASSWORD}"
        - name: MLFLOW_DB_NAME
          value: "${MLFLOW_DB_NAME}"
        command: ["/bin/bash","-lc"]
        args:
          - |
            set -euo pipefail

            echo "Waiting for Postgres to accept connections..."
            for i in {1..60}; do
              if psql -d postgres -Atqc "select 1" >/dev/null 2>&1; then
                break
              fi
              sleep 2
            done

            # Hard fail if still not reachable
            psql -d postgres -v ON_ERROR_STOP=1 -Atqc "select 1" >/dev/null

            # IMPORTANT: escape $ so outer script doesn't expand it under set -u
            psql_admin() { psql -v ON_ERROR_STOP=1 -d postgres -Atqc "\$1"; }

            role_exists="\$(psql_admin "SELECT 1 FROM pg_roles WHERE rolname='${MLFLOW_DB_USER}'")"
            if [[ "\${role_exists}" != "1" ]]; then
              echo "Creating role ${MLFLOW_DB_USER}"
              psql -v ON_ERROR_STOP=1 -d postgres -qc \
                "CREATE ROLE ${MLFLOW_DB_USER} LOGIN PASSWORD '${MLFLOW_DB_PASSWORD}';"
            else
              echo "Updating password for role ${MLFLOW_DB_USER}"
              psql -v ON_ERROR_STOP=1 -d postgres -qc \
                "ALTER ROLE ${MLFLOW_DB_USER} WITH PASSWORD '${MLFLOW_DB_PASSWORD}';"
            fi

            db_exists="\$(psql_admin "SELECT 1 FROM pg_database WHERE datname='${MLFLOW_DB_NAME}'")"
            if [[ "\${db_exists}" != "1" ]]; then
              echo "Creating database ${MLFLOW_DB_NAME}"
              psql -v ON_ERROR_STOP=1 -d postgres -qc \
                "CREATE DATABASE ${MLFLOW_DB_NAME} OWNER ${MLFLOW_DB_USER};"
            else
              echo "Database ${MLFLOW_DB_NAME} already exists"
            fi

            echo "Granting privileges"
            psql -v ON_ERROR_STOP=1 -d postgres -qc \
              "GRANT ALL PRIVILEGES ON DATABASE ${MLFLOW_DB_NAME} TO ${MLFLOW_DB_USER};"
YAML

log "Waiting for DB bootstrap job to complete"
if ! kubectl -n "${NEMO_NS}" wait --for=condition=complete "job/${JOB_NAME}" --timeout=5m >/dev/null; then
  echo
  echo "----- DB bootstrap job did not complete; dumping diagnostics -----" >&2
  kubectl -n "${NEMO_NS}" get pods -l job-name="${JOB_NAME}" -o wide >&2 || true
  POD="$(kubectl -n "${NEMO_NS}" get pods -l job-name="${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${POD}" ]]; then
    kubectl -n "${NEMO_NS}" describe pod "${POD}" >&2 || true
    kubectl -n "${NEMO_NS}" logs "${POD}" >&2 || true
  fi
  die "DB bootstrap job failed or timed out"
fi

log "DB bootstrap completed"

# ---- Helm repos ----
log "Adding/updating Helm repos"
helm repo add community-charts https://community-charts.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# ---- Install MinIO (NO Bitnami; use your known-good manifest) ----
log "Removing any existing MinIO Helm release (if present) to avoid conflicts"
if helm -n "${MLFLOW_NS}" status "${MINIO_RELEASE}" >/dev/null 2>&1; then
  helm -n "${MLFLOW_NS}" uninstall "${MINIO_RELEASE}" || true
fi

log "Ensuring old MinIO objects are not conflicting (safe to ignore if missing)"
kubectl -n "${MLFLOW_NS}" delete deploy/minio svc/minio pvc/minio-pvc secret/minio-creds job/minio-make-mlflow-bucket --ignore-not-found >/dev/null 2>&1 || true

log "Deploying MinIO via manifest (image: ${MINIO_IMAGE})"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: minio-creds
  namespace: ${MLFLOW_NS}
type: Opaque
stringData:
  rootUser: ${MINIO_ROOT_USER}
  rootPassword: ${MINIO_ROOT_PASSWORD}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: ${MLFLOW_NS}
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: ${MINIO_PVC_SIZE}
  storageClassName: ${MINIO_STORAGE_CLASS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: ${MLFLOW_NS}
spec:
  replicas: 1
  selector:
    matchLabels: { app: minio }
  template:
    metadata:
      labels: { app: minio }
    spec:
      containers:
        - name: minio
          image: ${MINIO_IMAGE}
          args: ["server", "/data", "--console-address", ":9001"]
          env:
            - name: MINIO_ROOT_USER
              valueFrom: { secretKeyRef: { name: minio-creds, key: rootUser } }
            - name: MINIO_ROOT_PASSWORD
              valueFrom: { secretKeyRef: { name: minio-creds, key: rootPassword } }
            - name: MINIO_DEFAULT_BUCKETS
              value: "${MINIO_BUCKET}"
          ports:
            - containerPort: 9000
            - containerPort: 9001
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: ${MLFLOW_NS}
spec:
  selector: { app: minio }
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
YAML

log "Waiting for MinIO to be Ready"
kubectl -n "${MLFLOW_NS}" rollout status deploy/minio --timeout=5m

# ---- Install MLflow (community chart) ----
log "Installing/upgrading MLflow (${MLFLOW_RELEASE}) in ${MLFLOW_NS} using community-charts/mlflow"
MLFLOW_VALUES="$(mktemp -t mlflow-values.XXXXXX.yaml)"
cat >"${MLFLOW_VALUES}" <<YAML
backendStore:
  databaseMigration: true
  postgres:
    enabled: true
    host: ${PG_HOST}
    port: 5432
    database: ${MLFLOW_DB_NAME}
    user: ${MLFLOW_DB_USER}
    password: ${MLFLOW_DB_PASSWORD}

artifactRoot:
  s3:
    enabled: true
    bucket: ${MINIO_BUCKET}
    path: ""
    awsAccessKeyId: ${MINIO_ROOT_USER}
    awsSecretAccessKey: ${MINIO_ROOT_PASSWORD}

extraEnvVars:
  AWS_DEFAULT_REGION: "us-east-1"
  AWS_S3_FORCE_PATH_STYLE: "true"
  MLFLOW_S3_ENDPOINT_URL: "${MLFLOW_S3_ENDPOINT_URL}"
  MLFLOW_S3_IGNORE_TLS: "true"

service:
  type: ClusterIP
  port: 80
YAML

helm upgrade --install "${MLFLOW_RELEASE}" community-charts/mlflow \
  -n "${MLFLOW_NS}" \
  -f "${MLFLOW_VALUES}" \
  --wait --timeout 10m

rm -f "${MLFLOW_VALUES}"

# ---- Integrate NeMo WITHOUT Helm upgrade ----
log "Injecting MLflow/MinIO env vars into NeMo deployments via kubectl set env"

kubectl -n "${NEMO_NS}" set env deploy/nemo-evaluator \
  MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URL}" \
  MLFLOW_EXPERIMENT_NAME="nemo-evaluator" \
  MLFLOW_S3_ENDPOINT_URL="${MLFLOW_S3_ENDPOINT_URL}" \
  AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
  AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
  AWS_DEFAULT_REGION="us-east-1" \
  AWS_S3_FORCE_PATH_STYLE="true" \
  >/dev/null

kubectl -n "${NEMO_NS}" set env deploy/nemo-customizer \
  MLFLOW_TRACKING_URI="${MLFLOW_TRACKING_URL}" \
  MLFLOW_S3_ENDPOINT_URL="${MLFLOW_S3_ENDPOINT_URL}" \
  AWS_ACCESS_KEY_ID="${MINIO_ROOT_USER}" \
  AWS_SECRET_ACCESS_KEY="${MINIO_ROOT_PASSWORD}" \
  AWS_DEFAULT_REGION="us-east-1" \
  AWS_S3_FORCE_PATH_STYLE="true" \
  >/dev/null || true

log "Waiting for NeMo customizer/evaluator rollout"
kubectl -n "${NEMO_NS}" rollout status deploy/nemo-evaluator  --timeout=5m || true
kubectl -n "${NEMO_NS}" rollout status deploy/nemo-customizer --timeout=5m || true

log "✅ Complete"
echo "MLflow Tracking (in-cluster): ${MLFLOW_TRACKING_URL}"
echo "MinIO S3 endpoint  (in-cluster): ${MLFLOW_S3_ENDPOINT_URL}"
echo
echo "Open MLflow UI locally:"
echo "  kubectl -n ${MLFLOW_NS} port-forward svc/${MLFLOW_RELEASE} 5000:80"
echo "  http://127.0.0.1:5000"
echo
echo "Credentials (dev):"
echo "  MinIO access key:  ${MINIO_ROOT_USER}"
echo "  MinIO secret key:  ${MINIO_ROOT_PASSWORD}"
echo
echo "Postgres (reused): ${PG_HOST}:5432 db=${MLFLOW_DB_NAME} user=${MLFLOW_DB_USER}"
