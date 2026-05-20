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
  nvidia-tesla-t4)   MACHINE_TYPE="n1-standard-4" ;;
  nvidia-l4)         MACHINE_TYPE="g2-standard-4" ;;
  nvidia-tesla-p4)   MACHINE_TYPE="n1-standard-4" ;;
  nvidia-tesla-p100) MACHINE_TYPE="n1-standard-8" ;;
  nvidia-tesla-v100) MACHINE_TYPE="n1-standard-8" ;;
  nvidia-h100-80gb)  MACHINE_TYPE="a3-highgpu-1g" ;;
  *)                 MACHINE_TYPE="n1-standard-4" ;;
esac

echo "GPU type     : $GPU_TYPE"
echo "Region       : $REGION"
echo "Project      : $PROJECT"
echo "Cluster zone : $CLUSTER_ZONE"
echo ""

# --- Step 1: list zones in the region that advertise this GPU ---
echo "==> Zones in $REGION advertising $GPU_TYPE:"
AVAILABLE_ZONES=$(gcloud compute accelerator-types list \
  --filter="name=${GPU_TYPE} AND zone~${REGION}" \
  --format="value(zone)" \
  --project "$PROJECT" 2>/dev/null | sort)

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

# --- Step 2: dry-run instance creation per zone (catches quota issues) ---
echo "==> Dry-run instance creation (catches quota/config errors, not stockouts):"
echo ""

ALL_ZONES=$(gcloud compute accelerator-types list \
  --filter="name=${GPU_TYPE} AND zone~${REGION}" \
  --format="value(zone)" \
  --project "$PROJECT" 2>/dev/null | sort)

if [[ -z "$ALL_ZONES" ]]; then
  echo "    No zones to check."
  exit 0
fi

while IFS= read -r zone; do
  marker=""
  [[ "$zone" == "$CLUSTER_ZONE" ]] && marker=" ← cluster zone"
  printf "  %-20s%s  " "$zone" "$marker"
  RESULT=$(gcloud compute instances create "gpu-probe-$$" \
    --zone "$zone" \
    --project "$PROJECT" \
    --machine-type "$MACHINE_TYPE" \
    --accelerator "type=${GPU_TYPE},count=1" \
    --maintenance-policy TERMINATE \
    --no-restart-on-failure \
    --dry-run \
    --format="value(name)" 2>&1 || true)

  if echo "$RESULT" | grep -qi "quota\|stockout\|does not have enough\|not available\|error\|fail"; then
    echo "UNAVAILABLE — $RESULT" | head -1
  else
    echo "OK (quota/config valid — stockout only detectable on real create)"
  fi
done <<< "$ALL_ZONES"

echo ""
echo "Note: dry-run validates quota and machine config but cannot detect live"
echo "GCE stockouts. A stockout will only surface when the workflow actually"
echo "tries to create the node pool."
