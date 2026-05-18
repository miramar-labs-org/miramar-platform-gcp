#!/usr/bin/env zsh
set -euo pipefail

###############################################################################
# PATCH: Add namespace get/create/delete ClusterRole to existing deploy SAs
#
# Applies a ClusterRole + ClusterRoleBinding for each namespace granting the
# deploy SA permission to get, list, create, and delete namespaces.
#
# Run this once against an existing cluster bootstrapped before this RBAC
# was added to setup-miramar-gke-cicd.zsh.
###############################################################################

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

PLATFORM_PROJECT_ID="miramar-cicd"
GKE_PROJECT_ID="miramar-platform"
GKE_LOCATION="us-west1-a"
CLUSTER_NAME="miramar-shared-gke"

PROJECT_NAMES=(
  "github-actions-hello"
)

PER_NAMESPACE_SERVICE_ACCOUNTS="true"

sanitize_sa_name() {
  local raw="$1"
  local cleaned
  cleaned="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
  local base="gh-${cleaned}"
  echo "${base:0:30}" | sed -E 's/-+$//'
}

log() { print -P "%F{cyan}==>%f $*" >&2 }

log "Fetching GKE credentials for ${CLUSTER_NAME}"
gcloud --quiet container clusters get-credentials "$CLUSTER_NAME" \
  --project "$GKE_PROJECT_ID" \
  --zone "$GKE_LOCATION"

for APP in "${PROJECT_NAMES[@]}"; do
  if [[ "$PER_NAMESPACE_SERVICE_ACCOUNTS" == "true" ]]; then
    SA_NAME="$(sanitize_sa_name "github-deploy-${APP}")"
    SA_EMAIL="${SA_NAME}@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com"
  else
    SA_EMAIL="github-deploy@${PLATFORM_PROJECT_ID}.iam.gserviceaccount.com"
  fi

  log "Patching namespace-manager RBAC for namespace=${APP} sa=${SA_EMAIL}"

  cat <<YAML | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-manager-${APP}
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: github-namespace-manager-${APP}
subjects:
  - kind: User
    name: ${SA_EMAIL}
    apiGroup: rbac.authorization.k8s.io
  - kind: User
    name: serviceAccount:${SA_EMAIL}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: namespace-manager-${APP}
  apiGroup: rbac.authorization.k8s.io
YAML

  log "Done: ${APP}"
done

log "Patch complete. Verify with:"
log "  kubectl get clusterrole,clusterrolebinding | grep namespace-manager"
