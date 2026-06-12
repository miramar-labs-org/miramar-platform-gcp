#!/usr/bin/env bash
set -euo pipefail

# Reads terraform.tfvars and syncs the values to GitHub org variables.
# Run this after changing terraform.tfvars.
#
# Requires: gh (GitHub CLI), authenticated with org admin scope.
#
# GKE_STATE_BUCKET is NOT in tfvars (it is the Terraform backend, not a
# Terraform variable) — update it manually if it ever changes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../../gcp/terraform/terraform.tfvars"
GITHUB_ORG="miramar-labs-org"

if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: tfvars not found at $TFVARS" >&2
  exit 1
fi

tfvar() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$TFVARS" \
    | head -1 \
    | sed 's/.*=[[:space:]]*//' \
    | tr -d '"' | tr -d "'" | tr -d ' '
}

set_var() {
  local gh_name="$1"
  local value="$2"
  echo "  $gh_name = $value"
  gh variable set "$gh_name" --org "$GITHUB_ORG" --body "$value" --visibility all
}

echo "Syncing from: $TFVARS"
echo ""

set_var GCP_PROJECT_ID   "$(tfvar project_id)"
set_var GCP_REGION       "$(tfvar region)"
set_var GKE_ZONE         "$(tfvar zone)"
set_var GKE_CLUSTER_NAME "$(tfvar cluster_name)"
set_var GAR_REPO         "$(tfvar ar_repo)"
set_var GKE_MACHINE_TYPE "$(tfvar machine_type)"

echo ""
echo "Done. GKE_STATE_BUCKET is not managed by this script — update manually if needed."
