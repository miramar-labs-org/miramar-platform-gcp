#!/usr/bin/env zsh
set -euo pipefail

###############################################################################
# MIRAMAR PLATFORM — ONE-TIME PROJECT BOOTSTRAP
#
# Creates if missing:
#   - miramar-platform GCP project
#   - billing link
#   - $50/month billing budget alert
#   - required APIs
#   - GitHub Workload Identity Federation pool/provider
#   - per-namespace GitHub deploy service accounts + WIF/GKE/SA IAM bindings
#   - cluster operations service account + IAM bindings
#
# Run once before miramar-platform-create. Idempotent — existing resources
# are left untouched. After completion, set WIF_PROVIDER and
# GCP_SERVICE_ACCOUNT as GitHub Actions secrets, then run
# miramar-platform-create to provision GKE and the cluster state bucket.
###############################################################################

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

###############################################################################
# CONFIG
###############################################################################

PROJECT_ID="miramar-platform"

PARENT_TYPE=""
PARENT_ID=""

BILLING_ACCOUNT_ID="013748-719993-DAB64D"

BUDGET_NAME="Miramar Kubernetes Free Tier Guardrail"
BUDGET_AMOUNT_USD="50"

REGION="us-west1"

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

project_exists() {
  gcloud --quiet projects describe "$1" >/dev/null 2>&1
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
  log "Enabling base APIs needed for non-interactive billing checks in ${PROJECT_ID}"

  gcloud --quiet services enable \
    serviceusage.googleapis.com \
    cloudbilling.googleapis.com \
    billingbudgets.googleapis.com \
    --project "$PROJECT_ID"
}

link_billing_if_configured() {
  if [[ -z "$BILLING_ACCOUNT_ID" ]]; then
    warn "BILLING_ACCOUNT_ID is blank; not linking billing."
    return 0
  fi

  log "Checking billing for project: ${PROJECT_ID}"

  local current_billing
  current_billing="$(
    gcloud --quiet beta billing projects describe "$PROJECT_ID" \
      --billing-project="$PROJECT_ID" \
      --format='value(billingAccountName)' 2>/dev/null || true
  )"

  if [[ "$current_billing" == "billingAccounts/${BILLING_ACCOUNT_ID}" ]]; then
    log "Billing already linked: ${BILLING_ACCOUNT_ID}"
    return 0
  fi

  log "Linking billing account ${BILLING_ACCOUNT_ID} to ${PROJECT_ID}"

  gcloud --quiet beta billing projects link "$PROJECT_ID" \
    --billing-account="$BILLING_ACCOUNT_ID" \
    --billing-project="$PROJECT_ID"
}

ensure_budget_alert() {
  if [[ -z "$BILLING_ACCOUNT_ID" ]]; then
    warn "BILLING_ACCOUNT_ID is blank; skipping budget alert."
    return 0
  fi

  log "Checking billing budget alert: ${BUDGET_NAME}"

  if gcloud --quiet beta billing budgets list \
      --billing-account="$BILLING_ACCOUNT_ID" \
      --billing-project="$PROJECT_ID" \
      --format="value(displayName)" 2>/dev/null \
      | grep -qx "$BUDGET_NAME"; then
    log "Budget alert already exists: ${BUDGET_NAME}"
    return 0
  fi

  log "Creating billing budget alert: ${BUDGET_NAME}"

  gcloud --quiet beta billing budgets create \
    --billing-account="$BILLING_ACCOUNT_ID" \
    --billing-project="$PROJECT_ID" \
    --display-name="$BUDGET_NAME" \
    --budget-amount="${BUDGET_AMOUNT_USD}USD" \
    --threshold-rule=percent=0.25,basis=current-spend \
    --threshold-rule=percent=0.50,basis=current-spend \
    --threshold-rule=percent=0.75,basis=current-spend \
    --threshold-rule=percent=0.90,basis=current-spend \
    --threshold-rule=percent=1.00,basis=current-spend
}

enable_apis() {
  log "Enabling required APIs in ${PROJECT_ID}"

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
    storage.googleapis.com \
    --project "$PROJECT_ID"
}

get_project_number() {
  gcloud --quiet projects describe "$PROJECT_ID" --format='value(projectNumber)'
}

ensure_wif_pool() {
  if gcloud --quiet iam workload-identity-pools describe "$WIF_POOL_ID" \
      --project "$PROJECT_ID" \
      --location="global" >/dev/null 2>&1; then
    log "Workload Identity Pool already exists: ${WIF_POOL_ID}"
    return 0
  fi

  log "Creating Workload Identity Pool: ${WIF_POOL_ID}"

  gcloud --quiet iam workload-identity-pools create "$WIF_POOL_ID" \
    --project="$PROJECT_ID" \
    --location="global" \
    --display-name="GitHub Actions"
}

ensure_wif_provider() {
  if gcloud --quiet iam workload-identity-pools providers describe "$WIF_PROVIDER_ID" \
      --project "$PROJECT_ID" \
      --location="global" \
      --workload-identity-pool="$WIF_POOL_ID" >/dev/null 2>&1; then
    log "Workload Identity Provider already exists: ${WIF_PROVIDER_ID}"
    return 0
  fi

  log "Creating GitHub OIDC provider: ${WIF_PROVIDER_ID}"

  gcloud --quiet iam workload-identity-pools providers create-oidc "$WIF_PROVIDER_ID" \
    --project="$PROJECT_ID" \
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
  local sa_email="${sa_name}@${PROJECT_ID}.iam.gserviceaccount.com"

  if gcloud --quiet iam service-accounts describe "$sa_email" \
      --project "$PROJECT_ID" >/dev/null 2>&1; then
    log "Service account already exists: ${sa_email}"
  else
    log "Creating service account: ${sa_email}"

    gcloud --quiet iam service-accounts create "$sa_name" \
      --project "$PROJECT_ID" \
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

add_service_account_iam_binding() {
  local sa_email="$1"
  local member="$2"
  local role="$3"

  if gcloud --quiet iam service-accounts get-iam-policy "$sa_email" \
      --project "$PROJECT_ID" \
      --flatten="bindings[].members" \
      --filter="bindings.role=${role} AND bindings.members=${member}" \
      --format="value(bindings.members)" | grep -qx "$member"; then
    log "Service account IAM binding already exists: ${sa_email}: ${member} ${role}"
    return 0
  fi

  log "Adding service account IAM binding: ${sa_email}: ${member} ${role}"

  gcloud --quiet iam service-accounts add-iam-policy-binding "$sa_email" \
    --project "$PROJECT_ID" \
    --member="$member" \
    --role="$role" >/dev/null
}

sanitize_sa_name() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"

  local base="gh-${cleaned}"

  echo "${base:0:30}" | sed -E 's/-+$//'
}

###############################################################################
# MAIN
###############################################################################

require_cmd gcloud
require_cmd sed
require_cmd grep

log "Active gcloud account:"
gcloud --quiet auth list --filter=status:ACTIVE --format='value(account)' || true

log "Setting active project to ${PROJECT_ID}"
gcloud --quiet config set project "$PROJECT_ID" >/dev/null || true
# billing/quota_project is set AFTER the project is confirmed to exist —
# setting it to a deleted project poisons all subsequent API calls.

log "Creating/checking project"
create_project_if_missing "$PROJECT_ID" "Miramar Platform"

gcloud --quiet config set billing/quota_project "$PROJECT_ID" >/dev/null || true

log "Enabling base APIs before billing checks"
enable_base_apis_for_billing_checks

log "Linking billing"
link_billing_if_configured

log "Creating/checking billing budget alert"
ensure_budget_alert || warn "Budget alert creation failed; continuing."

log "Enabling required APIs"
enable_apis

PROJECT_NUMBER="$(get_project_number)"
log "PROJECT_NUMBER=${PROJECT_NUMBER}"

ensure_wif_pool
ensure_wif_provider

WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/providers/${WIF_PROVIDER_ID}"
WIF_PRINCIPAL_SET="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL_ID}/attribute.repository_owner/${GITHUB_OWNER}"

log "WIF provider resource: ${WIF_PROVIDER_RESOURCE}"
log "WIF principal set: ${WIF_PRINCIPAL_SET}"

typeset -A APP_TO_SA

if [[ "$PER_NAMESPACE_SERVICE_ACCOUNTS" == "false" ]]; then
  SHARED_SA_EMAIL="$(ensure_service_account "github-deploy" "GitHub deploy shared")"
  add_service_account_iam_binding "$SHARED_SA_EMAIL" "$WIF_PRINCIPAL_SET" "roles/iam.workloadIdentityUser"
  add_project_iam_binding "$PROJECT_ID" "serviceAccount:${SHARED_SA_EMAIL}" "roles/container.clusterViewer"
  add_project_iam_binding "$PROJECT_ID" "serviceAccount:${SHARED_SA_EMAIL}" "roles/iam.serviceAccountUser"
fi

for APP in "${PROJECT_NAMES[@]}"; do
  if [[ "$PER_NAMESPACE_SERVICE_ACCOUNTS" == "true" ]]; then
    SA_NAME="$(sanitize_sa_name "github-deploy-${APP}")"
    SA_EMAIL="$(ensure_service_account "$SA_NAME" "GitHub deploy for ${APP}")"

    add_service_account_iam_binding "$SA_EMAIL" "$WIF_PRINCIPAL_SET" "roles/iam.workloadIdentityUser"
    add_project_iam_binding "$PROJECT_ID" "serviceAccount:${SA_EMAIL}" "roles/container.clusterViewer"
    add_project_iam_binding "$PROJECT_ID" "serviceAccount:${SA_EMAIL}" "roles/iam.serviceAccountUser"
  else
    SA_EMAIL="$SHARED_SA_EMAIL"
  fi

  APP_TO_SA[$APP]="$SA_EMAIL"
done

# Cluster management SA
CLUSTER_SA_NAME="$(sanitize_sa_name "$GHA_CLUSTER_SA_NAME")"
GHA_CLUSTER_SA="${CLUSTER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

ensure_service_account "$CLUSTER_SA_NAME" "GKE cluster operations"
add_service_account_iam_binding "$GHA_CLUSTER_SA" "$WIF_PRINCIPAL_SET" "roles/iam.workloadIdentityUser"
add_project_iam_binding "$PROJECT_ID" "serviceAccount:${GHA_CLUSTER_SA}" "roles/container.admin"
add_project_iam_binding "$PROJECT_ID" "serviceAccount:${GHA_CLUSTER_SA}" "roles/storage.admin"
add_project_iam_binding "$PROJECT_ID" "serviceAccount:${GHA_CLUSTER_SA}" "roles/artifactregistry.admin"
add_project_iam_binding "$PROJECT_ID" "serviceAccount:${GHA_CLUSTER_SA}" "roles/serviceusage.serviceUsageConsumer"
# Terraform reads instance group managers after node pool creation to confirm state
add_project_iam_binding "$PROJECT_ID" "serviceAccount:${GHA_CLUSTER_SA}" "roles/compute.viewer"
# Find GPU Capacity workflow creates+deletes probe instances to test actual hardware availability
add_project_iam_binding "$PROJECT_ID" "serviceAccount:${GHA_CLUSTER_SA}" "roles/compute.instanceAdmin"

# GKE cluster creation requires serviceAccountUser on the default Compute SA
# (used as the node pool identity).
DEFAULT_COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
add_service_account_iam_binding "$DEFAULT_COMPUTE_SA" "serviceAccount:${GHA_CLUSTER_SA}" "roles/iam.serviceAccountUser"
log "Cluster management SA: ${GHA_CLUSTER_SA}"

###############################################################################
# OUTPUT
###############################################################################

cat <<OUT

===============================================================================
BOOTSTRAP COMPLETE
===============================================================================

Project:
  ${PROJECT_ID}

Billing budget alert:
  ${BUDGET_NAME}
  ${BUDGET_AMOUNT_USD} USD/month

GitHub owner:
  ${GITHUB_OWNER}

Workload Identity Provider:
  ${WIF_PROVIDER_RESOURCE}

Cluster management SA (set as GCP_SERVICE_ACCOUNT secret for cluster workflows):
  ${GHA_CLUSTER_SA}

Namespaces and deploy service accounts:
OUT

for APP in "${PROJECT_NAMES[@]}"; do
  echo "  ${APP}: ${APP_TO_SA[$APP]}"
done

cat <<OUT

Next steps:
  1. Set these GitHub Actions secrets in miramar-labs-org/miramar-platform-gcp:
       WIF_PROVIDER        = ${WIF_PROVIDER_RESOURCE}
       GCP_SERVICE_ACCOUNT = ${GHA_CLUSTER_SA}

  2. Run the "Miramar Platform Create" workflow to provision GKE and storage.

OUT
