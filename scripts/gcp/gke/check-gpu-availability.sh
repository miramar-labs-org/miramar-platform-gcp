#!/usr/bin/env bash
set -euo pipefail

# Checks GPU availability across zones for a given GPU type.
#
# Usage:
#   ./check-gpu-availability.sh [gpu_type] [region] [--probe]
#
# Without --probe: shows which zones advertise the GPU and quota status.
#
# With --probe: actively creates a minimal test instance in each zone to
#   detect actual hardware capacity (not just quota). Fails fast when a
#   zone is exhausted (<5s per failure). Requires compute.instances.create
#   permission (local gcloud sessions; not available in the workflow SA).
#   Exit code 0 if the cluster zone has capacity; 1 if exhausted.
#
# Examples:
#   ./check-gpu-availability.sh
#   ./check-gpu-availability.sh nvidia-tesla-t4
#   ./check-gpu-availability.sh nvidia-l4 us-central1
#   ./check-gpu-availability.sh nvidia-tesla-t4 us-central1 --probe

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../../../gcp/terraform/terraform.tfvars"

tfvar() {
  grep -E "^[[:space:]]*${1}[[:space:]]*=" "$TFVARS" \
    | head -1 \
    | sed 's/.*=[[:space:]]*//' \
    | tr -d '"' | tr -d "'" | tr -d ' '
}

# Parse args — allow --probe anywhere in the argument list
GPU_TYPE="nvidia-tesla-t4"
REGION=""
PROBE=false

for arg in "$@"; do
  case "$arg" in
    --probe) PROBE=true ;;
    nvidia-*|--gpu=*) GPU_TYPE="${arg#--gpu=}" ;;
    us-*|europe-*|asia-*) REGION="$arg" ;;
    *) GPU_TYPE="$arg" ;;
  esac
done

PROJECT="$(tfvar project_id)"
CLUSTER_ZONE="$(tfvar zone)"
REGION="${REGION:-$(echo "$CLUSTER_ZONE" | sed 's/-[a-z]$//')}"

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

echo "GPU type     : $GPU_TYPE  (machine: $MACHINE_TYPE)"
echo "Region       : $REGION"
echo "Project      : $PROJECT"
echo "Cluster zone : $CLUSTER_ZONE"
$PROBE && echo "Mode         : PROBE (creates+deletes a test instance per zone)"
echo ""

# --- Step 1: list zones in the region that advertise this GPU ---
echo "==> Zones in $REGION with $GPU_TYPE:"
echo ""

AVAILABLE_ZONES=$(gcloud compute accelerator-types list \
  --filter="name:${GPU_TYPE} AND zone~${REGION}" \
  --format="value(zone)" \
  --project "$PROJECT" | sort -u)

ALTERNATIVE_ZONES=()
if [[ -z "$AVAILABLE_ZONES" ]]; then
  echo "    None found in $REGION."
else
  while IFS= read -r zone; do
    if [[ "$zone" == "$CLUSTER_ZONE" ]]; then
      echo "    $zone  ← current cluster zone"
    else
      echo "    $zone  ← alternative (requires cluster recreation to use)"
      ALTERNATIVE_ZONES+=("$zone")
    fi
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
echo "Note: quota shows your project ceiling. ZONE_RESOURCE_POOL_EXHAUSTED is a"
echo "      GCE hardware shortage — separate from quota and not visible here."

# --- Step 3: Active capacity probe (--probe only) ---
if $PROBE; then
  echo ""
  echo "==> Probing actual capacity (creates+deletes a test instance per zone):"
  echo ""

  probe_zone() {
    local zone="$1"
    local name="gpu-probe-$$"
    local out rc
    out=$(gcloud compute instances create "$name" \
      --machine-type="$MACHINE_TYPE" \
      --accelerator="type=${GPU_TYPE},count=1" \
      --maintenance-policy=TERMINATE \
      --no-restart-on-failure \
      --zone="$zone" \
      --project="$PROJECT" \
      --no-address \
      --image-family=debian-12 \
      --image-project=debian-cloud \
      --boot-disk-size=10 \
      2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
      gcloud compute instances delete "$name" \
        --zone="$zone" --project="$PROJECT" --quiet --async 2>/dev/null &
      echo "available"
    elif echo "$out" | grep -q "ZONE_RESOURCE_POOL_EXHAUSTED"; then
      echo "exhausted"
    else
      echo "error ($(echo "$out" | grep -oE '[A-Z_]{5,}' | head -1 || echo 'unknown'))"
    fi
  }

  CLUSTER_ZONE_STATUS=""
  FIRST_AVAILABLE_ZONE=""

  if [[ -n "$AVAILABLE_ZONES" ]]; then
    while IFS= read -r zone; do
      printf "    %-20s  probing..." "$zone"
      STATUS=$(probe_zone "$zone")
      printf "\r    %-20s  %s\n" "$zone" "$STATUS"
      if [[ "$zone" == "$CLUSTER_ZONE" ]]; then
        CLUSTER_ZONE_STATUS="$STATUS"
      fi
      if [[ "$STATUS" == "available" && -z "$FIRST_AVAILABLE_ZONE" ]]; then
        FIRST_AVAILABLE_ZONE="$zone"
      fi
    done <<< "$AVAILABLE_ZONES"
  fi

  echo ""
  if [[ "$CLUSTER_ZONE_STATUS" == "available" ]]; then
    echo "✓ $CLUSTER_ZONE has capacity — GKE Expand GPU should succeed."
  else
    echo "✗ $CLUSTER_ZONE is EXHAUSTED for $GPU_TYPE."
    if [[ -n "$FIRST_AVAILABLE_ZONE" ]]; then
      FIRST_REGION="$(echo "$FIRST_AVAILABLE_ZONE" | sed 's/-[a-z]$//')"
      echo ""
      echo "  To move the cluster to $FIRST_AVAILABLE_ZONE:"
      echo "    1. Edit gcp/terraform/terraform.tfvars:"
      echo "         zone = \"$FIRST_AVAILABLE_ZONE\""
      echo "         region = \"$FIRST_REGION\""
      echo "       Edit gcp/terraform-gpu/gpu.tfvars:"
      echo "         cluster_zone = \"$FIRST_AVAILABLE_ZONE\""
      echo "         region = \"$FIRST_REGION\""
      echo "    2. git commit -am 'move cluster to $FIRST_AVAILABLE_ZONE' && git push"
      echo "    3. Run: GKE Restore GPU → Miramar Platform Destroy → Miramar Platform Create → GKE Expand GPU"
    else
      echo "  No available zones found in $REGION for $GPU_TYPE."
      echo "  Try a different region or GPU type (e.g. nvidia-l4)."
    fi
    exit 1
  fi

# --- Step 3 (no probe): static alternatives ---
else
  echo ""
  echo "==> If $CLUSTER_ZONE is exhausted, to move the cluster:"
  echo ""
  if [[ ${#ALTERNATIVE_ZONES[@]} -eq 0 ]]; then
    echo "    No alternative zones in $REGION. Try a different region or GPU type."
  else
    echo "    Run with --probe to confirm which zones have actual capacity, then:"
    echo ""
    echo "    1. Edit gcp/terraform/terraform.tfvars and gcp/terraform-gpu/gpu.tfvars"
    echo "       (zone + cluster_zone → one of the alternatives above)"
    echo "    2. git commit -am 'move cluster to <zone>' && git push"
    echo "    3. Run: GKE Restore GPU → Miramar Platform Destroy → Miramar Platform Create → GKE Expand GPU"
  fi
fi

echo ""
echo "==> GKE Expand GPU workflow inputs:"
echo ""
echo "    Namespace    : mlops-torch-triton-gke-pipeline"
echo "    Machine type : $MACHINE_TYPE"
echo "    GPU type     : $GPU_TYPE"
