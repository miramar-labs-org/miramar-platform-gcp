#!/usr/bin/env bash
# Find actual GPU capacity across all zones in parallel.
# Probes by creating+deleting a minimal instance (exhausted zones fail in <5s).
# Shows top 5 cheapest available options with ready-to-use GKE expand settings.
#
# Usage:
#   ./find-gpu-capacity.sh [region_filter]
#
# Examples:
#   ./find-gpu-capacity.sh              # all regions
#   ./find-gpu-capacity.sh us-central1  # us-central1 only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../../../gcp/terraform/terraform.tfvars"
PROJECT="$(grep -E '^[[:space:]]*project_id' "$TFVARS" | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d ' ')"
REGION_FILTER="${1:-}"

# GPU types: name  machine_type  on_demand_cost  spot_cost
GPU_TYPES=(
  "nvidia-tesla-p4   n1-standard-4  0.42  0.13"
  "nvidia-tesla-t4   n1-standard-4  0.54  0.16"
  "nvidia-l4         g2-standard-4  0.74  0.22"
  "nvidia-tesla-p100 n1-standard-8  1.46  0.44"
  "nvidia-tesla-v100 n1-standard-8  2.48  0.74"
)

TMPDIR_RESULTS="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_RESULTS"; }
trap cleanup EXIT

probe_instance() {
  local zone="$1" gpu="$2" machine="$3" spot="$4" project="$5" outdir="$6"
  local name="gpu-probe-$$-${RANDOM}"
  local extra_args=()
  [[ "$spot" == "true" ]] && extra_args+=(--provisioning-model=SPOT)

  local out rc
  out=$(gcloud compute instances create "$name" \
    --machine-type="$machine" \
    --accelerator="type=${gpu},count=1" \
    --maintenance-policy=TERMINATE \
    --no-restart-on-failure \
    --zone="$zone" \
    --project="$project" \
    --no-address \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=10 \
    "${extra_args[@]}" \
    2>&1)
  rc=$?
  if [[ $rc -eq 0 ]]; then
    gcloud compute instances delete "$name" --zone="$zone" --project="$project" --quiet --async 2>/dev/null &
    echo "available"
  elif echo "$out" | grep -qE "ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_NOT_AVAILABLE"; then
    echo "exhausted"
  elif echo "$out" | grep -q "QUOTA_EXCEEDED\|limit name"; then
    echo "quota"
  else
    echo "error"
  fi
}
export -f probe_instance

probe_combo() {
  local zone="$1" gpu="$2" machine="$3" spot="$4" cost="$5" project="$6" outdir="$7"
  local status
  status=$(probe_instance "$zone" "$gpu" "$machine" "$spot" "$project" "$outdir")
  if [[ "$status" == "available" ]]; then
    local label
    [[ "$spot" == "true" ]] && label="spot" || label="on-demand"
    printf "AVAILABLE  \$%.2f/hr %-10s  %-25s  %-22s  spot=%-5s\n" \
      "$cost" "($label)" "$zone" "$gpu" "$spot" | tee "$outdir/${cost}_${zone}_${gpu}_${spot}"
  else
    printf "%-9s  %s  %s  spot=%s\n" "$status" "$zone" "$gpu" "$spot"
  fi
}
export -f probe_combo

echo "Project : $PROJECT"
[[ -n "$REGION_FILTER" ]] && echo "Region  : $REGION_FILTER" || echo "Region  : all"
echo ""
echo "Probing all GPU types and zones in parallel..."
echo "(Available options print immediately)"
echo ""

JOBS=()
for entry in "${GPU_TYPES[@]}"; do
  read -r gpu machine od_cost spot_cost <<< "$entry"
  FILTER="name:${gpu}"
  [[ -n "$REGION_FILTER" ]] && FILTER="${FILTER} AND zone~${REGION_FILTER}"

  ZONES=$(gcloud compute accelerator-types list \
    --filter="$FILTER" \
    --format="value(zone)" \
    --project "$PROJECT" 2>/dev/null | sort -u)

  [[ -z "$ZONES" ]] && continue

  while IFS= read -r zone; do
    JOBS+=("$zone $gpu $machine false $od_cost $PROJECT $TMPDIR_RESULTS")
    JOBS+=("$zone $gpu $machine true  $spot_cost $PROJECT $TMPDIR_RESULTS")
  done <<< "$ZONES"
done

printf '%s\n' "${JOBS[@]}" | xargs -P 30 -I{} bash -c 'probe_combo $@' _ {}

echo ""
echo "============================================================"

RESULTS=$(ls "$TMPDIR_RESULTS" 2>/dev/null | sort -t_ -k1 -n | head -5)
if [[ -z "$RESULTS" ]]; then
  echo "No GPU capacity found. Try again later or request quota increases."
  exit 1
fi

echo "Top 5 cheapest available (use these as GKE Expand GPU inputs):"
echo ""
N=1
for f in $RESULTS; do
  read -r _avail cost_raw label zone gpu spot_raw < "$TMPDIR_RESULTS/$f" || true
  # parse from filename: cost_zone_gpu_spot
  IFS='_' read -r cost zone gpu spot <<< "$f"
  machine="n1-standard-4"
  [[ "$gpu" == "nvidia-l4" ]] && machine="g2-standard-4"
  [[ "$gpu" == "nvidia-tesla-p100" || "$gpu" == "nvidia-tesla-v100" ]] && machine="n1-standard-8"

  echo "  #$N — \$$cost/hr"
  echo "     gpu_type     : $gpu"
  echo "     machine_type : $machine"
  echo "     zone         : $zone  ← $(if [[ "$(grep zone "$TFVARS" | head -1 | grep -o '"[^"]*"')" == "\"$zone\"" ]]; then echo "current cluster zone"; else echo "REQUIRES CLUSTER MOVE"; fi)"
  echo "     spot         : $spot"
  echo ""
  (( N++ ))
done
