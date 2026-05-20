#!/usr/bin/env bash
set -euo pipefail

# Refreshes ~/.kube/config for the miramar-shared-gke cluster.
# Run this after a cluster recreate or when kubectl shows a connection timeout.
#
# Reads cluster_name, zone, and project_id from terraform.tfvars.
# Requires: gcloud, authenticated with an account that has container.clusters.get.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../../../gcp/terraform/terraform.tfvars"

if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: tfvars not found at $TFVARS" >&2
  exit 1
fi

tfvar() {
  grep -E "^[[:space:]]*${1}[[:space:]]*=" "$TFVARS" \
    | head -1 \
    | sed 's/.*=[[:space:]]*//' \
    | tr -d '"' | tr -d "'" | tr -d ' '
}

CLUSTER="$(tfvar cluster_name)"
ZONE="$(tfvar zone)"
PROJECT="$(tfvar project_id)"

echo "Cluster  : $CLUSTER"
echo "Zone     : $ZONE"
echo "Project  : $PROJECT"
echo ""

gcloud container clusters get-credentials "$CLUSTER" \
  --zone "$ZONE" \
  --project "$PROJECT"

echo ""
echo "Context set to: $(kubectl config current-context)"
