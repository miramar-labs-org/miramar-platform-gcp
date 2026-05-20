#!/usr/bin/env zsh
set -euo pipefail

###############################################################################
# MIRAMAR PLATFORM — K8s NAMESPACE AND RBAC SETUP
#
# Applies per-namespace configuration assuming Terraform has already
# provisioned the GKE cluster and Artifact Registry repo:
#   - Artifact Registry IAM write bindings for deploy service accounts
#   - Kubernetes namespaces + resource quotas + default limits + RBAC
#
# Requires:
#   - bootstrap-miramar-platform.zsh has run (WIF + service accounts exist)
#   - kubectl is configured for the target cluster
#   - gcloud is authenticated
###############################################################################

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

###############################################################################
# CONFIG
###############################################################################

PROJECT_ID="${PROJECT_ID:-miramar-platform}"
REGION="${GCP_REGION:-us-west1}"
AR_REPO="${AR_REPO:-apps}"

GITHUB_OWNER="miramar-labs-org"

PROJECT_NAMES=(
  "mlops-torch-triton-gke-pipeline"
)

PER_NAMESPACE_SERVICE_ACCOUNTS="true"

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

typeset -A APP_TO_SA

for APP in "${PROJECT_NAMES[@]}"; do
  if [[ "$PER_NAMESPACE_SERVICE_ACCOUNTS" == "true" ]]; then
    SA_NAME="$(sanitize_sa_name "github-deploy-${APP}")"
    SA_EMAIL="$(sa_email_for "$SA_NAME")"
    add_artifact_repo_iam_binding "serviceAccount:${SA_EMAIL}" "roles/artifactregistry.writer"
  else
    SA_EMAIL="$(sa_email_for "github-deploy")"
    add_artifact_repo_iam_binding "serviceAccount:${SA_EMAIL}" "roles/artifactregistry.writer"
  fi

  APP_TO_SA[$APP]="$SA_EMAIL"
done

for APP in "${PROJECT_NAMES[@]}"; do
  ensure_namespace_and_rbac "$APP" "${APP_TO_SA[$APP]}"
done

log "K8s namespace and RBAC setup complete."
