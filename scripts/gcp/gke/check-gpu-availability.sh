#!/usr/bin/env bash
set -euo pipefail

# Checks GPU availability in GCP zones near the cluster.
#
# Usage:
#   ./check-gpu-availability.sh [gpu_type] [region]
#
# Examples:
#   ./check-gpu-availability.sh
#   ./check-gpu-availability.sh nvidia-tesla-t4
#   ./check-gpu-availability.sh nvidia-l4
#   ./check-gpu-availability.sh nvidia-tesla-t4 us-central1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../../../gcp/terraform/terraform.tfvars"

tfvar() {
  grep -E "^[[:space:]]*${1}[[:space:]]*=" "$TFVARS" \
    | head -1 \
    | sed 's/.*=[[:space:]]*//' \
    | tr -d '"' | tr -d "'" | tr -d ' '
}

GPU_TYPE="${1:-nvidia-tesla-t4}"
PROJECT="$(tfvar project_id)"
CLUSTER_ZONE="$(tfvar zone)"
REGION="${2:-$(echo "$CLUSTER_ZONE" | sed 's/-[a-z]$//')}"   # strip zone suffix → region

# Recommended machine type per GPU
case "$GPU_TYPE" in
  nvidia-tesla-t4)   MACHINE_TYPE="n1-standard-4"  QUOTA_METRIC="NVIDIA_T4_GPUS"    ;;
  nvidia-l4)         MACHINE_TYPE="g2-standard-4"  QUOTA_METRIC="NVIDIA_L4_GPUS"    ;;
  nvidia-tesla-p4)   MACHINE_TYPE="n1-standard-4"  QUOTA_METRIC="NVIDIA_P4_GPUS"    ;;
  nvidia-tesla-p100) MACHINE_TYPE="n1-standard-8"  QUOTA_METRIC="NVIDIA_P100_GPUS"  ;;
  nvidia-tesla-v100) MACHINE_TYPE="n1-standard-8"  QUOTA_METRIC="NVIDIA_V100_GPUS"  ;;
  nvidia-h100-80gb)  MACHINE_TYPE="a3-highgpu-1g"  QUOTA_METRIC="NVIDIA_H100_GPUS"  ;;
  *)                 MACHINE_TYPE="n1-standard-4"  QUOTA_METRIC=""                  ;;
esac

echo "GPU type     : $GPU_TYPE"
echo "Region       : $REGION"
echo "Project      : $PROJECT"
echo "Cluster zone : $CLUSTER_ZONE"
echo ""

# --- Step 1: list zones in the region that advertise this GPU ---
echo "==> Zones in $REGION advertising $GPU_TYPE:"
AVAILABLE_ZONES=$(gcloud compute accelerator-types list \
  --filter="name:${GPU_TYPE} AND zone~${REGION}" \
  --format="value(zone)" \
  --project "$PROJECT" | sort -u)

if [[ -z "$AVAILABLE_ZONES" ]]; then
  echo "    None found in $REGION."
else
  while IFS= read -r zone; do
    marker=""
    [[ "$zone" == "$CLUSTER_ZONE" ]] && marker=" ← cluster zone"
    echo "    $zone$marker"
  done <<< "$AVAILABLE_ZONES"
fi

echo ""

# --- Step 2: GPU quota for the region ---
echo "==> GPU quota in $REGION (metric: ${QUOTA_METRIC:-unknown}):"
echo ""
if [[ -n "$QUOTA_METRIC" ]]; then
  gcloud compute regions describe "$REGION" \
    --project "$PROJECT" \
    --format="json(quotas)" \
    | python3 -c "
import json, sys
quotas = json.load(sys.stdin).get('quotas', [])
needle = '${QUOTA_METRIC}'
rows = [q for q in quotas if needle in q.get('metric', '')]
if not rows:
    print('    (no quota entry found for', needle, ')')
else:
    for q in rows:
        limit = int(q.get('limit', 0))
        usage = int(q.get('usage', 0))
        is_committed = q.get('metric', '').startswith('COMMITTED_')
        warn = '  *** LIMIT IS 0 — request a quota increase ***' if limit == 0 and not is_committed else ''
        print(f'    {q[\"metric\"]:<42s}  limit={limit:>4}  usage={usage:>4}{warn}')
"
else
  echo "    (unrecognised GPU type — cannot map to quota metric)"
fi

echo ""
echo "Note: quota shows your project allocation ceiling — a GCE stockout is a"
echo "separate capacity shortage on Google's side."

echo ""
echo "==> GKE Expand GPU workflow inputs:"
echo ""
echo "    Namespace    : mlops-torch-triton-gke-pipeline"
echo "    Machine type : $MACHINE_TYPE"
echo "    GPU type     : $GPU_TYPE"
