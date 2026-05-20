#!/usr/bin/env zsh
set -euo pipefail

###############################################################################
# MIRAMAR PLATFORM — GCP RESOURCE PROVISIONING
#
# Creates if missing:
#   - Artifact Registry Docker repository
#   - Artifact Registry IAM bindings for deploy service accounts
#   - GKE Standard zonal cluster
#   - GCS cluster state bucket
#   - Kubernetes namespaces + resource quotas + RBAC
#
# Assumes bootstrap-miramar-project.zsh has already run and WIF +
# service accounts exist. Idempotent — existing resources are left untouched.
#
# Cost-control design:
#   - us-west1-a
#   - GKE Standard, not Autopilot
#   - one e2-medium node by default
#   - one 30 GB pd-standard boot disk
#
# WARNING:
#   This minimizes cost but does not guarantee $0.
#   Avoid LoadBalancer Services, PersistentVolumeClaims, Cloud NAT,
#   regional clusters, multiple nodes, larger nodes, large images,
#   snapshots, and heavy egress.
###############################################################################

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

###############################################################################
# CONFIG
###############################################################################

PROJECT_ID="miramar-platform"

REGION="us-west1"
GKE_LOCATION="us-west1-a"

CLUSTER_NAME="miramar-shared-gke"
CREATE_CLUSTER="true"
GKE_RELEASE_CHANNEL="regular"

MACHINE_TYPE="e2-medium"
NUM_NODES="1"
DISK_TYPE="pd-standard"
DISK_SIZE_GB="30"

AR_REPO="apps"

CLUSTER_STATE_BUCKET="miramar-platform-cluster-state"

GHA_CLUSTER_SA_NAME="gke-cluster-ops"

GITHUB_OWNER="miramar-labs-org"

PROJECT_NAMES=(
  "mlops-torch-triton-gke-pipeline"
)

PER_NAMESPACE_SERVICE_ACCOUNTS="true"

WIF_POOL_ID="github-actions"
WIF_PROVIDER_ID="github"

###############################################################################
# HELPERS
###############################################################################

log() {
  print -P "%F{cyan}==>%f $*" >&2
}

warn() {
  print -P "%F{yellow}WARNING:%f $*" >&2
}

die() {
  print -P "%F{red}ERROR:%f $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

get_project_number() {
  gcloud --quiet projects describe "$PROJECT_ID" --format='value(projectNumber)'
}

sanitize_sa_name() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"

  local base="gh-${cleaned}"

  echo "${base:0:30}" | sed -E 's/-+$//'
}

sa_email_for() {
  local sa_name="$1"
  echo "${sa_name}@${PROJECT_ID}.iam.gserviceaccount.com"
}

ensure_artifact_repo() {
  if gcloud --quiet artifacts repositories describe "$AR_REPO" \
      --project "$PROJECT_ID" \
      --location "$REGION" >/dev/null 2>&1; then
    log "Artifact Registry repo already exists: ${AR_REPO}"
    return 0
  fi

  log "Creating Artifact Registry Docker repo: ${AR_REPO}"

  gcloud --quiet artifacts repositories create "$AR_REPO" \
    --project "$PROJECT_ID" \
    --location "$REGION" \
    --repository-format=docker \
    --description="Shared Docker images for Miramar apps"
}

add_artifact_repo_iam_binding() {
  local member="$1"
  local role="$2"

  if gcloud --quiet artifacts repositories get-iam-policy "$AR_REPO" \
      --project "$PROJECT_ID" \
      --location "$REGION" \
      --flatten="bindings[].members" \
      --filter="bindings.role=${role} AND bindings.members=${member}" \
      --format="value(bindings.members)" | grep -qx "$member"; then
    log "Artifact Registry IAM binding already exists: ${member} ${role}"
    return 0
  fi

  log "Adding Artifact Registry IAM binding: ${member} ${role}"

  gcloud --quiet artifacts repositories add-iam-policy-binding "$AR_REPO" \
    --project "$PROJECT_ID" \
    --location "$REGION" \
    --member="$member" \
    --role="$role" >/dev/null
}

ensure_gke_cluster() {
  if [[ "$CREATE_CLUSTER" != "true" ]]; then
    log "Skipping GKE cluster creation because CREATE_CLUSTER=${CREATE_CLUSTER}"
    return 0
  fi

  if gcloud --quiet container clusters describe "$CLUSTER_NAME" \
      --project "$PROJECT_ID" \
      --zone "$GKE_LOCATION" >/dev/null 2>&1; then
    log "GKE cluster already exists: ${CLUSTER_NAME}"
    return 0
  fi

  log "Creating GKE Standard zonal cluster: ${CLUSTER_NAME}"

  gcloud --quiet container clusters create "$CLUSTER_NAME" \
    --project "$PROJECT_ID" \
    --zone "$GKE_LOCATION" \
    --release-channel "$GKE_RELEASE_CHANNEL" \
    --machine-type "$MACHINE_TYPE" \
    --num-nodes "$NUM_NODES" \
    --disk-type "$DISK_TYPE" \
    --disk-size "$DISK_SIZE_GB" \
    --enable-ip-alias
}

get_gke_credentials() {
  log "Fetching GKE credentials"

  gcloud --quiet container clusters get-credentials "$CLUSTER_NAME" \
    --project "$PROJECT_ID" \
    --zone "$GKE_LOCATION"
}

ensure_cluster_state_bucket() {
  if gcloud --quiet storage buckets describe "gs://${CLUSTER_STATE_BUCKET}" \
      --project "$PROJECT_ID" >/dev/null 2>&1; then
    log "Cluster state bucket already exists: gs://${CLUSTER_STATE_BUCKET}"
    return 0
  fi

  log "Creating cluster state bucket: gs://${CLUSTER_STATE_BUCKET}"

  gcloud --quiet storage buckets create "gs://${CLUSTER_STATE_BUCKET}" \
    --project "$PROJECT_ID" \
    --location "$REGION"
}

ensure_namespace_and_rbac() {
  local namespace="$1"
  local sa_email="$2"

  log "Applying namespace, quota, limits, and RBAC for ${namespace}"

  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

  cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-quota
  namespace: ${namespace}
spec:
  hard:
    requests.cpu: "200m"
    requests.memory: 512Mi
    limits.cpu: "500m"
    limits.memory: 1Gi
    pods: "5"
---
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: ${namespace}
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: "50m"
        memory: "128Mi"
      default:
        cpu: "200m"
        memory: "256Mi"
YAML

  cat <<YAML | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-manager-${namespace}
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: github-namespace-manager-${namespace}
subjects:
  - kind: User
    name: ${sa_email}
    apiGroup: rbac.authorization.k8s.io
  - kind: User
    name: serviceAccount:${sa_email}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: namespace-manager-${namespace}
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: namespace-deployer
  namespace: ${namespace}
rules:
  - apiGroups: [""]
    resources:
      - configmaps
      - secrets
      - services
      - serviceaccounts
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: [""]
    resources:
      - pods
      - pods/log
      - events
    verbs: ["get", "list", "watch"]

  - apiGroups: ["apps"]
    resources:
      - deployments
      - replicasets
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: ["batch"]
    resources:
      - jobs
      - cronjobs
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]

  - apiGroups: ["networking.k8s.io"]
    resources:
      - networkpolicies
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: github-deployer-binding-email
  namespace: ${namespace}
subjects:
  - kind: User
    name: ${sa_email}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: namespace-deployer
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: github-deployer-binding-serviceaccount-email
  namespace: ${namespace}
subjects:
  - kind: User
    name: serviceAccount:${sa_email}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: namespace-deployer
  apiGroup: rbac.authorization.k8s.io
YAML
}

###############################################################################
# MAIN
###############################################################################

require_cmd gcloud
require_cmd kubectl
require_cmd sed
require_cmd grep

log "Active gcloud account:"
gcloud --quiet auth list --filter=status:ACTIVE --format='value(account)' || true

log "Setting active project to ${PROJECT_ID}"
gcloud --quiet config set project "$PROJECT_ID" >/dev/null || true

PROJECT_NUMBER="$(get_project_number)"
log "PROJECT_NUMBER=${PROJECT_NUMBER}"

WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/providers/${WIF_PROVIDER_ID}"

ensure_artifact_repo

# Grant deploy SAs write access to AR (SAs already created by bootstrap).
if [[ "$PER_NAMESPACE_SERVICE_ACCOUNTS" == "false" ]]; then
  SHARED_SA_EMAIL="$(sa_email_for "github-deploy")"
  add_artifact_repo_iam_binding "serviceAccount:${SHARED_SA_EMAIL}" "roles/artifactregistry.writer"
fi

typeset -A APP_TO_SA

for APP in "${PROJECT_NAMES[@]}"; do
  if [[ "$PER_NAMESPACE_SERVICE_ACCOUNTS" == "true" ]]; then
    SA_NAME="$(sanitize_sa_name "github-deploy-${APP}")"
    SA_EMAIL="$(sa_email_for "$SA_NAME")"
    add_artifact_repo_iam_binding "serviceAccount:${SA_EMAIL}" "roles/artifactregistry.writer"
  else
    SA_EMAIL="$SHARED_SA_EMAIL"
  fi

  APP_TO_SA[$APP]="$SA_EMAIL"
done

ensure_gke_cluster
get_gke_credentials
ensure_cluster_state_bucket

for APP in "${PROJECT_NAMES[@]}"; do
  ensure_namespace_and_rbac "$APP" "${APP_TO_SA[$APP]}"
done

###############################################################################
# OUTPUT
###############################################################################

FIRST_APP="${PROJECT_NAMES[1]}"
FIRST_SA="${APP_TO_SA[$FIRST_APP]}"

cat <<OUT

===============================================================================
PLATFORM CREATE COMPLETE
===============================================================================

Project:
  ${PROJECT_ID}

GKE cluster:
  ${CLUSTER_NAME}

GKE zone:
  ${GKE_LOCATION}

Node pool:
  ${NUM_NODES} x ${MACHINE_TYPE}
  ${DISK_SIZE_GB}GB ${DISK_TYPE}

Artifact Registry image prefix:
  ${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}

Cluster state bucket:
  gs://${CLUSTER_STATE_BUCKET}

Workload Identity Provider:
  ${WIF_PROVIDER_RESOURCE}

Namespaces and service accounts:
OUT

for APP in "${PROJECT_NAMES[@]}"; do
  echo "  ${APP}: ${APP_TO_SA[$APP]}"
done

cat <<OUT

Example GitHub Actions auth/deploy skeleton:

permissions:
  contents: read
  id-token: write

env:
  PROJECT_ID: ${PROJECT_ID}
  GKE_CLUSTER: ${CLUSTER_NAME}
  GKE_LOCATION: ${GKE_LOCATION}
  GAR_LOCATION: ${REGION}
  GAR_REPOSITORY: ${AR_REPO}
  K8S_NAMESPACE: ${FIRST_APP}

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: "${WIF_PROVIDER_RESOURCE}"
          service_account: "${FIRST_SA}"

      - uses: google-github-actions/setup-gcloud@v2

      - uses: google-github-actions/get-gke-credentials@v2
        with:
          cluster_name: "\${{ env.GKE_CLUSTER }}"
          location: "\${{ env.GKE_LOCATION }}"
          project_id: "\${{ env.PROJECT_ID }}"

      - name: Configure Docker for Artifact Registry
        run: gcloud auth configure-docker "\${GAR_LOCATION}-docker.pkg.dev" --quiet

      - name: Build and push image
        run: |
          IMAGE="\${GAR_LOCATION}-docker.pkg.dev/\${PROJECT_ID}/\${GAR_REPOSITORY}/\${K8S_NAMESPACE}:\${GITHUB_SHA}"
          docker build -t "\$IMAGE" .
          docker push "\$IMAGE"
          echo "IMAGE=\$IMAGE" >> "\$GITHUB_ENV"

      - name: Deploy
        run: |
          kubectl -n "\${K8S_NAMESPACE}" set image deployment/\${K8S_NAMESPACE} \${K8S_NAMESPACE}="\${IMAGE}"
          kubectl -n "\${K8S_NAMESPACE}" rollout status deployment/\${K8S_NAMESPACE}

Verify:

  gcloud container clusters list --project ${PROJECT_ID}
  gcloud artifacts repositories list --project ${PROJECT_ID} --location ${REGION}
  gcloud storage buckets list --project ${PROJECT_ID}

  kubectl get nodes -o wide
  kubectl get namespaces
  kubectl get role,rolebinding -n ${FIRST_APP}

Cost-control rules:

  Do NOT create Kubernetes Services with:
    type: LoadBalancer

  Prefer:
    type: ClusterIP

  For testing:
    kubectl -n <namespace> port-forward svc/<service> 8080:80

  Avoid:
    - PersistentVolumeClaims
    - Cloud NAT
    - Ingress that creates a Google Cloud Load Balancer
    - regional GKE clusters
    - multiple nodes
    - bigger node types
    - large images in Artifact Registry
    - snapshots
    - external egress-heavy workloads

OUT
