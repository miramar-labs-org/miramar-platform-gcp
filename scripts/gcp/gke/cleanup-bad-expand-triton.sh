#!/usr/bin/env bash
set -euo pipefail

# Cleans up after a failed GKE Expand Triton workflow run.
#
# When Terraform fails during node pool creation (e.g. GCE stockout), the
# pool may exist in GKE in an ERROR state but not in Terraform state. This
# script handles both cases:
#   1. terraform destroy  — removes the pool if it made it into TF state
#   2. gcloud delete      — removes the pool directly if it exists in GKE
#   3. kubectl apply      — restores the tight namespace quota
#
# Requires: gcloud, terraform, kubectl — all authenticated.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_MAIN="${SCRIPT_DIR}/../../../gcp/terraform/terraform.tfvars"
TFVARS_GPU="${SCRIPT_DIR}/../../../gcp/terraform-gpu/gpu.tfvars"
TF_GPU_DIR="${SCRIPT_DIR}/../../../gcp/terraform-gpu"

NAMESPACE="${1:-mlops-torch-triton-gke-pipeline}"
GPU_POOL="gpu-triton-pool"

tfvar() {
  local file="$1" key="$2"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" \
    | head -1 \
    | sed 's/.*=[[:space:]]*//' \
    | tr -d '"' | tr -d "'" | tr -d ' '
}

CLUSTER="$(tfvar "$TFVARS_MAIN" cluster_name)"
ZONE="$(tfvar "$TFVARS_MAIN" zone)"
PROJECT="$(tfvar "$TFVARS_MAIN" project_id)"
STATE_BUCKET="$(tfvar "$TFVARS_MAIN" project_id)"  # fallback; bucket name set via GKE_STATE_BUCKET

# Allow override via env (matches what the workflow uses)
STATE_BUCKET="${GKE_STATE_BUCKET:-miramar-platform-cluster-state}"

echo "Cluster   : $CLUSTER"
echo "Zone      : $ZONE"
echo "Project   : $PROJECT"
echo "Namespace : $NAMESPACE"
echo "GPU pool  : $GPU_POOL"
echo ""

# --- Step 1: terraform destroy (removes pool if it's in TF state) ---
echo "==> Step 1: terraform destroy (skips if pool not in state)"
cd "$TF_GPU_DIR"
terraform init -backend-config="bucket=$STATE_BUCKET" -reconfigure > /dev/null
if terraform show -json 2>/dev/null \
    | python3 -c "import json,sys; r=json.load(sys.stdin).get('values',{}).get('root_module',{}).get('resources',[]); sys.exit(0 if r else 1)" 2>/dev/null; then
  terraform destroy -auto-approve -var-file=gpu.tfvars
  echo "    Pool removed via terraform destroy."
else
  echo "    No resources in Terraform state — skipping."
fi
cd - > /dev/null

# --- Step 2: gcloud delete (removes pool if it still exists in GKE) ---
echo ""
echo "==> Step 2: gcloud node-pool delete (skips if pool not found)"
if gcloud container node-pools describe "$GPU_POOL" \
    --cluster "$CLUSTER" \
    --zone "$ZONE" \
    --project "$PROJECT" &>/dev/null; then
  echo "    Pool found — deleting via gcloud..."
  gcloud container node-pools delete "$GPU_POOL" \
    --cluster "$CLUSTER" \
    --zone "$ZONE" \
    --project "$PROJECT" \
    --quiet
  echo "    Pool deleted."
else
  echo "    Pool not found in GKE — skipping."
fi

# --- Step 3: restore tight namespace quota ---
echo ""
echo "==> Step 3: restore namespace quota for $NAMESPACE"
STATE_PATH="gs://$STATE_BUCKET/gke/quota-${NAMESPACE}.json"
if gsutil -q stat "$STATE_PATH" 2>/dev/null; then
  gsutil cp "$STATE_PATH" /tmp/quota-backup.json
  kubectl apply -f /tmp/quota-backup.json
  echo "    Quota restored from $STATE_PATH"
else
  echo "    No snapshot found — applying default tight quota"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-quota
  namespace: ${NAMESPACE}
spec:
  hard:
    requests.cpu: "200m"
    requests.memory: 512Mi
    limits.cpu: "500m"
    limits.memory: 1Gi
    pods: "5"
EOF
fi

echo ""
echo "Done. Re-run GKE Expand Triton when ready."
