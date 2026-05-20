#!/usr/bin/env zsh
set -euo pipefail

###############################################################################
# MIRAMAR GKE + GITHUB ACTIONS CI/CD BOOTSTRAP
#
# Creates if missing:
#   - miramar-cicd project
#   - miramar-platform project
#   - billing links
#   - $50/month billing budget alert
#   - required APIs
#   - GitHub Workload Identity Federation pool/provider
#   - GitHub deploy service accounts
#   - Artifact Registry Docker repo
#   - GKE Standard zonal cluster
#   - Kubernetes namespaces
#   - namespace-scoped Kubernetes RBAC
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

# CI/CD identity project.
PLATFORM_PROJECT_ID="miramar-cicd"

# Project that hosts GKE, Artifact Registry, and workloads.
GKE_PROJECT_ID="miramar-platform"

# Optional parent folder/org.
# Leave blank unless needed.
PARENT_TYPE=""
PARENT_ID=""

# Billing account.
BILLING_ACCOUNT_ID="013748-719993-DAB64D"

# Billing budget alert.
BUDGET_NAME="Miramar Kubernetes Free Tier Guardrail"
BUDGET_AMOUNT_USD="50"

# GCP region/location.
REGION="us-west1"
GKE_LOCATION="us-west1-a"

# Shared GKE Standard cluster.
CLUSTER_NAME="miramar-shared-gke"
CREATE_CLUSTER="true"
GKE_RELEASE_CHANNEL="regular"

# Node settings.
MACHINE_TYPE="e2-medium"
NUM_NODES="1"
DISK_TYPE="pd-standard"
DISK_SIZE_GB="30"

# Shared Artifact Registry Docker repository.
AR_REPO="apps"

# GitHub org/user that owns the repos.
GITHUB_OWNER="miramar-labs"

# One namespace per app/project/repo.
PROJECT_NAMES=(
  "github-actions-hello"
  "mlops-torch-triton-gke-pipeline"
)

# Prefer one deploy service account per namespace.
PER_NAMESPACE_SERVICE_ACCOUNTS="true"

# Workload Identity Federation IDs.
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

project_exists() {
  local project_id="$1"
  gcloud --quiet projects describe "$project_id" >/dev/null 2>&1
}

create_project_if_missing() {
  local project_id="$1"
  local name="$2"

  if project_exists "$project_id"; then
    log "Project already exists: ${project_id}"
    return 0
  fi

  log "Creating project: ${project_id}"

  local args=("$project_id" "--name=${name}")

  if [[ -n "$PARENT_TYPE" && -n "$PARENT_ID" ]]; then
    case "$PARENT_TYPE" in
      folder)
        args+=("--folder=${PARENT_ID}")
        ;;
      organization|org)
        args+=("--organization=${PARENT_ID}")
        ;;
      *)
        die "PARENT_TYPE must be blank, folder, or organization"
        ;;
    esac
  fi

  gcloud --quiet projects create "${args[@]}"
}

enable_base_apis_for_billing_checks() {
  local project_id="$1"

  log "Enabling base APIs needed for non-interactive billing checks in ${project_id}"

  gcloud --quiet services enable \
    serviceusage.googleapis.com \
    cloudbilling.googleapis.com \
    billingbudgets.googleapis.com \
    --project "$project_id"
}

link_billing_if_configured() {
  local project_id="$1"

  if [[ -z "$BILLING_ACCOUNT_ID" ]]; then
    warn "BILLING_ACCOUNT_ID is blank; not linking billing for ${project_id}."
    return 0
  fi

  log "Checking billing for project: ${project_id}"

  local current_billing
  current_billing="$(
    gcloud --quiet beta billing projects describe "$project_id" \
      --billing-project="$PLATFORM_PROJECT_ID" \
      --format='value(billingAccountName)' 2>/dev/null || true
  )"

  if [[ "$current_billing" == "billingAccounts/${BILLING_ACCOUNT_ID}" ]]; then
    log "Billing already linked for ${project_id}: ${BILLING_ACCOUNT_ID}"
    return 0
  fi

  log "Linking billing account ${BILLING_ACCOUNT_ID} to ${project_id}"

  gcloud --quiet beta billing projects link "$project_id" \
    --billing-account="$BILLING_ACCOUNT_ID" \
    --billing-project="$PLATFORM_PROJECT_ID"
}

ensure_budget_alert() {
  if [[ -z "$BILLING_ACCOUNT_ID" ]]; then
    warn "BILLING_ACCOUNT_ID is blank; skipping budget alert."
    return 0
  fi

  log "Checking billing budget alert: ${BUDGET_NAME}"

  if gcloud --quiet beta billing budgets list \
      --billing-account="$BILLING_ACCOUNT_ID" \
      --billing-project="$PLATFORM_PROJECT_ID" \
      --format="value(displayName)" 2>/dev/null \
      | grep -qx "$BUDGET_NAME"; then
    log "Budget alert already exists: ${BUDGET_NAME}"
    return 0
  fi

  log "Creating billing budget alert: ${BUDGET_NAME}"

  gcloud --quiet beta billing budgets create \
    --billing-account="$BILLING_ACCOUNT_ID" \
    --billing-project="$PLATFORM_PROJECT_ID" \
    --display-name="$BUDGET_NAME" \
    --budget-amount="${BUDGET_AMOUNT_USD}USD" \
    --threshold-rule=percent=0.25,basis=current-spend \
    --threshold-rule=percent=0.50,basis=current-spend \
    --threshold-rule=percent=0.75,basis=current-spend \
    --threshold-rule=percent=0.90,basis=current-spend \
    --threshold-rule=percent=1.00,basis=current-spend
}

enable_apis() {
  local project_id="$1"

  log "Enabling required APIs in ${project_id}"

  gcloud --quiet services enable \
    cloudbilling.googleapis.com \
    billingbudgets.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    sts.googleapis.com \
    cloudresourcemanager.googleapis.com \
    serviceusage.googleapis.com \
    artifactregistry.googleapis.com \
    container.googleapis.com \
    compute.googleapis.com \
    --project "$project_id"
}

get_project_number() {
  local project_id="$1"
  gcloud --quiet projects describe "$project_id" --format='value(projectNumber)'
}

ensure_artifact_repo() {
  if gcloud --quiet artifacts repositories describe "$AR_REPO" \
      --project "$GKE_PROJECT_ID" \
      --location "$REGION" >/dev/null 2>&1; then
    log "Artifact Registry repo already exists: ${AR_REPO}"
    return 0
  fi

  log "Creating Artifact Registry Docker repo: ${AR_REPO}"

  gcloud --quiet artifacts repositories create "$AR_REPO" \
    --project "$GKE_PROJECT_ID" \
    --location "$REGION" \
    --repository-format=docker \
    --description="Shared Docker images for Miramar apps"
}

ensure_gke_cluster() {
  if [[ "$CREATE_CLUSTER" != "true" ]]; then
    log "Skipping GKE cluster creation because CREATE_CLUSTER=${CREATE_CLUSTER}"
    return 0
  fi

  if gcloud --quiet container clusters describe "$CLUSTER_NAME" \
      --project "$GKE_PROJECT_ID" \
      --zone "$GKE_LOCATION" >/dev/null 2>&1; then
    log "GKE cluster already exists: ${CLUSTER_NAME}"
    return 0
  fi

  log "Creating GKE Standard zonal cluster: ${CLUSTER_NAME}"

  gcloud --quiet container clusters create "$CLUSTER_NAME" \
    --project "$GKE_PROJECT_ID" \
    --zone "$GKE_LOCATION" \
    --release-channel "$GKE_RELEASE_CHANNEL" \
    --machine-type "$MACHINE_TYPE" \
    --num-nodes "$NUM_NODES" \
    --disk-type "$DISK_TYPE" \
    --disk-size "$DISK_SIZE_GB" \
    --enable-ip-alias \
}

get_gke_credentials() {
  log "Fetching GKE credentials"

  gcloud --quiet container clusters get-credentials "$CLUSTER_NAME" \
    --project "$GKE_PROJECT_ID" \
    --zone "$GKE_LOCATION"
}

ensure_wif_pool() {
  if gcloud --quiet iam workload-identity-pools describe "$WIF_POOL_ID" \
      --project "$PLATFORM_PROJECT_ID" \
      --location="global" >/dev/null 2>&1; then
    log "Workload Identity Pool already exists: ${WIF_POOL_ID}"
    return 0
  fi

  log "Creating Workload Identity Pool: ${WIF_POOL_ID}"

  gcloud --quiet iam workload-identity-pools create "$WIF_POOL_ID" \
    --project="$PLATFORM_PROJECT_ID" \
    --location="global" \
    --display-name="GitHub Actions"
}

ensure_wif_provider() {
  if gcloud --quiet iam workload-identity-pools providers describe "$WIF_PROVIDER_ID" \
      --project "$PLATFORM_PROJECT_ID" \
      --location="global" \
      --workload-identity-pool="$WIF_POOL_ID" >/dev/null 2>&1; then
    log "Workload Identity Provider already exists: ${WIF_PROVIDER_ID}"
    return 0
  fi

  log "Creating GitHub OIDC provider: ${WIF_PROVIDER_ID}"

  gcloud --quiet iam workload-identity-pools providers create-oidc "$WIF_PROVIDER_ID" \
    --project="$PLATFORM_PROJECT_ID" \
    --location="global" \
    --workload-identity-pool="$WIF_POOL_ID" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
    --attribute-condition="assertion.repository_owner == '${GITHUB_OWNER}'"
}

ensure_service_account() {
  local sa_name="$1"
  local display_name="$2"
  local sa_email="${sa_name}@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com"

  if gcloud --quiet iam service-accounts describe "$sa_email" \
      --project "$PLATFORM_PROJECT_ID" >/dev/null 2>&1; then
    log "Service account already exists: ${sa_email}"
  else
    log "Creating service account: ${sa_email}"

    gcloud --quiet iam service-accounts create "$sa_name" \
      --project "$PLATFORM_PROJECT_ID" \
      --display-name="$display_name"
  fi

  echo "$sa_email"
}

add_project_iam_binding() {
  local project_id="$1"
  local member="$2"
  local role="$3"

  if gcloud --quiet projects get-iam-policy "$project_id" \
      --flatten="bindings[].members" \
      --filter="bindings.role=${role} AND bindings.members=${member}" \
      --format="value(bindings.members)" | grep -qx "$member"; then
    log "IAM binding already exists on ${project_id}: ${member} ${role}"
    return 0
  fi

  log "Adding IAM binding on ${project_id}: ${member} ${role}"

  gcloud --quiet projects add-iam-policy-binding "$project_id" \
    --member="$member" \
    --role="$role" >/dev/null
}

add_artifact_repo_iam_binding() {
  local member="$1"
  local role="$2"

  if gcloud --quiet artifacts repositories get-iam-policy "$AR_REPO" \
      --project "$GKE_PROJECT_ID" \
      --location "$REGION" \
      --flatten="bindings[].members" \
      --filter="bindings.role=${role} AND bindings.members=${member}" \
      --format="value(bindings.members)" | grep -qx "$member"; then
    log "Artifact Registry IAM binding already exists: ${member} ${role}"
    return 0
  fi

  log "Adding Artifact Registry IAM binding: ${member} ${role}"

  gcloud --quiet artifacts repositories add-iam-policy-binding "$AR_REPO" \
    --project "$GKE_PROJECT_ID" \
    --location "$REGION" \
    --member="$member" \
    --role="$role" >/dev/null
}

add_service_account_iam_binding() {
  local sa_email="$1"
  local member="$2"
  local role="$3"

  if gcloud --quiet iam service-accounts get-iam-policy "$sa_email" \
      --project "$PLATFORM_PROJECT_ID" \
      --flatten="bindings[].members" \
      --filter="bindings.role=${role} AND bindings.members=${member}" \
      --format="value(bindings.members)" | grep -qx "$member"; then
    log "Service account IAM binding already exists: ${sa_email}: ${member} ${role}"
    return 0
  fi

  log "Adding service account IAM binding: ${sa_email}: ${member} ${role}"

  gcloud --quiet iam service-accounts add-iam-policy-binding "$sa_email" \
    --project "$PLATFORM_PROJECT_ID" \
    --member="$member" \
    --role="$role" >/dev/null
}

sanitize_sa_name() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"

  local base="gh-${cleaned}"

  # Service account ID must be <= 30 chars.
  echo "${base:0:30}" | sed -E 's/-+$//'
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

log "Setting active project to ${PLATFORM_PROJECT_ID}"
gcloud --quiet config set project "$PLATFORM_PROJECT_ID" >/dev/null || true
gcloud --quiet config set billing/quota_project "$PLATFORM_PROJECT_ID" >/dev/null || true

log "Creating/checking projects"
create_project_if_missing "$PLATFORM_PROJECT_ID" "Miramar CICD"
create_project_if_missing "$GKE_PROJECT_ID" "Miramar Platform"

log "Enabling base APIs before billing checks"
enable_base_apis_for_billing_checks "$PLATFORM_PROJECT_ID"
enable_base_apis_for_billing_checks "$GKE_PROJECT_ID"

log "Linking billing"
link_billing_if_configured "$PLATFORM_PROJECT_ID"
link_billing_if_configured "$GKE_PROJECT_ID"

log "Creating/checking billing budget alert"
ensure_budget_alert || warn "Budget alert creation failed; continuing."

log "Enabling required APIs"
enable_apis "$PLATFORM_PROJECT_ID"
enable_apis "$GKE_PROJECT_ID"

PLATFORM_PROJECT_NUMBER="$(get_project_number "$PLATFORM_PROJECT_ID")"
GKE_PROJECT_NUMBER="$(get_project_number "$GKE_PROJECT_ID")"

log "PLATFORM_PROJECT_NUMBER=${PLATFORM_PROJECT_NUMBER}"
log "GKE_PROJECT_NUMBER=${GKE_PROJECT_NUMBER}"

ensure_artifact_repo
ensure_gke_cluster
get_gke_credentials

ensure_wif_pool
ensure_wif_provider

WIF_PROVIDER_RESOURCE="projects/${PLATFORM_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/providers/${WIF_PROVIDER_ID}"

WIF_PRINCIPAL_SET="principalSet://iam.googleapis.com/projects/${PLATFORM_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/attribute.repository_owner/${GITHUB_OWNER}"

log "WIF provider resource: ${WIF_PROVIDER_RESOURCE}"
log "WIF principal set: ${WIF_PRINCIPAL_SET}"

typeset -A APP_TO_SA

if [[ "$PER_NAMESPACE_SERVICE_ACCOUNTS" == "false" ]]; then
  SHARED_SA_EMAIL="$(ensure_service_account "github-deploy" "GitHub deploy shared")"

  add_service_account_iam_binding "$SHARED_SA_EMAIL" "$WIF_PRINCIPAL_SET" "roles/iam.workloadIdentityUser"
  add_project_iam_binding "$GKE_PROJECT_ID" "serviceAccount:${SHARED_SA_EMAIL}" "roles/container.clusterViewer"
  add_project_iam_binding "$GKE_PROJECT_ID" "serviceAccount:${SHARED_SA_EMAIL}" "roles/iam.serviceAccountUser"
  add_artifact_repo_iam_binding "serviceAccount:${SHARED_SA_EMAIL}" "roles/artifactregistry.writer"
fi

for APP in "${PROJECT_NAMES[@]}"; do
  NAMESPACE="$APP"

  if [[ "$PER_NAMESPACE_SERVICE_ACCOUNTS" == "true" ]]; then
    SA_NAME="$(sanitize_sa_name "github-deploy-${APP}")"
    SA_EMAIL="$(ensure_service_account "$SA_NAME" "GitHub deploy for ${APP}")"

    add_service_account_iam_binding "$SA_EMAIL" "$WIF_PRINCIPAL_SET" "roles/iam.workloadIdentityUser"
    add_project_iam_binding "$GKE_PROJECT_ID" "serviceAccount:${SA_EMAIL}" "roles/container.clusterViewer"
    add_project_iam_binding "$GKE_PROJECT_ID" "serviceAccount:${SA_EMAIL}" "roles/iam.serviceAccountUser"
    add_artifact_repo_iam_binding "serviceAccount:${SA_EMAIL}" "roles/artifactregistry.writer"
  else
    SA_EMAIL="$SHARED_SA_EMAIL"
  fi

  APP_TO_SA[$APP]="$SA_EMAIL"
  ensure_namespace_and_rbac "$NAMESPACE" "$SA_EMAIL"
done

###############################################################################
# OUTPUT
###############################################################################

cat <<OUT

===============================================================================
SETUP COMPLETE
===============================================================================

CI/CD project:
  ${PLATFORM_PROJECT_ID}

GKE/workload project:
  ${GKE_PROJECT_ID}

GKE cluster:
  ${CLUSTER_NAME}

GKE zone:
  ${GKE_LOCATION}

Node pool:
  ${NUM_NODES} x ${MACHINE_TYPE}
  ${DISK_SIZE_GB}GB ${DISK_TYPE}

Artifact Registry image prefix:
  ${REGION}-docker.pkg.dev/${GKE_PROJECT_ID}/${AR_REPO}

Billing budget alert:
  ${BUDGET_NAME}
  ${BUDGET_AMOUNT_USD} USD/month

GitHub owner:
  ${GITHUB_OWNER}

Workload Identity Provider:
  ${WIF_PROVIDER_RESOURCE}

Namespaces and service accounts:
OUT

for APP in "${PROJECT_NAMES[@]}"; do
  echo "  ${APP}: ${APP_TO_SA[$APP]}"
done

FIRST_APP="${PROJECT_NAMES[1]}"
FIRST_SA="${APP_TO_SA[$FIRST_APP]}"

cat <<OUT

Example GitHub Actions auth/deploy skeleton:

permissions:
  contents: read
  id-token: write

env:
  GKE_PROJECT_ID: ${GKE_PROJECT_ID}
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
          project_id: "\${{ env.GKE_PROJECT_ID }}"

      - name: Configure Docker for Artifact Registry
        run: gcloud auth configure-docker "\${GAR_LOCATION}-docker.pkg.dev" --quiet

      - name: Build and push image
        run: |
          IMAGE="\${GAR_LOCATION}-docker.pkg.dev/\${GKE_PROJECT_ID}/\${GAR_REPOSITORY}/\${K8S_NAMESPACE}:\${GITHUB_SHA}"
          docker build -t "\$IMAGE" .
          docker push "\$IMAGE"
          echo "IMAGE=\$IMAGE" >> "\$GITHUB_ENV"

      - name: Deploy
        run: |
          kubectl -n "\${K8S_NAMESPACE}" set image deployment/\${K8S_NAMESPACE} \${K8S_NAMESPACE}="\${IMAGE}"
          kubectl -n "\${K8S_NAMESPACE}" rollout status deployment/\${K8S_NAMESPACE}

Verify:

  gcloud projects describe ${PLATFORM_PROJECT_ID}
  gcloud projects describe ${GKE_PROJECT_ID}

  gcloud beta billing projects describe ${PLATFORM_PROJECT_ID} --billing-project ${PLATFORM_PROJECT_ID}
  gcloud beta billing projects describe ${GKE_PROJECT_ID} --billing-project ${PLATFORM_PROJECT_ID}

  gcloud beta billing budgets list \\
    --billing-account ${BILLING_ACCOUNT_ID} \\
    --billing-project ${PLATFORM_PROJECT_ID}

  gcloud container clusters list --project ${GKE_PROJECT_ID}
  gcloud artifacts repositories list --project ${GKE_PROJECT_ID} --location ${REGION}

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

Notes:
  - Budget alerts notify you but do not hard-stop spending.
  - This WIF setup currently allows repos under ${GITHUB_OWNER} to impersonate the deploy service accounts.
  - For stronger isolation, later restrict WIF bindings per repo.

OUT
