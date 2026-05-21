#!/usr/bin/env bash
# Find GPU options across all zones in parallel.
# Probes by creating+deleting a minimal instance (exhausted zones fail in <5s).
#
# Shows top 5 cheapest options in two tiers:
#   [USE NOW]           — available immediately
#   [REQUEST QUOTA]     — hardware may be there, quota not yet granted
#
# Usage:
#   ./find-gpu-capacity.sh [region_filter]
#
# Examples:
#   ./find-gpu-capacity.sh              # all US regions (default)
#   ./find-gpu-capacity.sh us-central1  # us-central1 only
#   ./find-gpu-capacity.sh ""           # all regions globally

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../../../gcp/terraform/terraform.tfvars"
PROJECT="$(grep -E '^[[:space:]]*project_id' "$TFVARS" | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d ' ')"
CLUSTER_ZONE="$(grep -E '^[[:space:]]*zone' "$TFVARS" | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '"' | tr -d "'" | tr -d ' ')"
REGION_FILTER="${1:-us-}"

# GPU types: name  machine_type  on_demand_cost  spot_cost
GPU_TYPES=(
  "nvidia-tesla-p4   n1-standard-4  0.42  0.13"
  "nvidia-tesla-t4   n1-standard-4  0.54  0.16"
  "nvidia-l4         g2-standard-4  0.74  0.22"
  "nvidia-tesla-p100 n1-standard-8  1.46  0.44"
  "nvidia-tesla-v100 n1-standard-8  2.48  0.74"
)

# Maps gpu_type + spot → GCP quota metric name
quota_metric() {
  local gpu="$1" spot="$2"
  local prefix=""
  [[ "$spot" == "true" ]] && prefix="PREEMPTIBLE_"
  case "$gpu" in
    nvidia-tesla-t4)   echo "${prefix}NVIDIA_T4_GPUS" ;;
    nvidia-l4)         echo "${prefix}NVIDIA_L4_GPUS" ;;
    nvidia-tesla-p4)   echo "${prefix}NVIDIA_P4_GPUS" ;;
    nvidia-tesla-p100) echo "${prefix}NVIDIA_P100_GPUS" ;;
    nvidia-tesla-v100) echo "${prefix}NVIDIA_V100_GPUS" ;;
    *)                 echo "${prefix}NVIDIA_GPUS" ;;
  esac
}
export -f quota_metric

TMPDIR_RESULTS="$(mktemp -d)"
mkdir -p "$TMPDIR_RESULTS/available" "$TMPDIR_RESULTS/quota"
cleanup() { rm -rf "$TMPDIR_RESULTS"; }
trap cleanup EXIT

probe_instance() {
  local zone="$1" gpu="$2" machine="$3" spot="$4" project="$5"
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
  status=$(probe_instance "$zone" "$gpu" "$machine" "$spot" "$project")

  local spotlabel; [[ "$spot" == "true" ]] && spotlabel="spot" || spotlabel="on-demand"

  case "$status" in
    available)
      printf "available  \$%s/hr (%s)  %s  %s\n" "$cost" "$spotlabel" "$zone" "$gpu"
      # prefix 0_ so available sorts before quota at same price
      touch "$outdir/available/0_${cost}_${zone}_${gpu}_${spot}"
      ;;
    quota)
      printf "quota      \$%s/hr (%s)  %s  %s\n" "$cost" "$spotlabel" "$zone" "$gpu"
      touch "$outdir/quota/${cost}_${zone}_${gpu}_${spot}"
      ;;
    exhausted)
      printf "exhausted  \$%s/hr (%s)  %s  %s\n" "$cost" "$spotlabel" "$zone" "$gpu"
      ;;
    *)
      printf "error      \$%s/hr (%s)  %s  %s\n" "$cost" "$spotlabel" "$zone" "$gpu"
      ;;
  esac
}
export -f probe_combo

echo "Project      : $PROJECT"
echo "Cluster zone : $CLUSTER_ZONE"
echo "Region filter: $REGION_FILTER"
echo ""
echo "Probing all GPU types and zones in parallel..."
echo "(Results print as they arrive)"
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
echo "Top 5 options (cheapest first):"
echo ""

# Merge available (prefixed 0_) and quota results, sort by cost, take top 5
ALL_RESULTS=$(
  { ls "$TMPDIR_RESULTS/available/" 2>/dev/null | sed 's|^|available/|';
    ls "$TMPDIR_RESULTS/quota/"     2>/dev/null | sed 's|^|quota/|'; } \
  | sort -t_ -k2 -n \
  | head -5
)

if [[ -z "$ALL_RESULTS" ]]; then
  echo "  No options found — all zones exhausted."
  echo "  Try a different region or check back later."
  exit 1
fi

N=1
while IFS= read -r entry; do
  tier="${entry%%/*}"        # available or quota
  filename="${entry##*/}"    # 0_cost_zone_gpu_spot  or  cost_zone_gpu_spot

  # Strip leading 0_ prefix from available files
  filename="${filename#0_}"
  # Filename format: {cost}_{zone}_{gpu}_{spot}
  # zone has no underscores; gpu starts with "nvidia-"; spot is true/false
  cost="${filename%%_*}"
  rest="${filename#${cost}_}"        # zone_gpu_spot
  zone="${rest%%_nvidia-*}"          # everything before _nvidia-
  gpu_spot="${rest#${zone}_}"        # nvidia-xxx_true/false
  gpu="${gpu_spot%_*}"               # strip trailing _true or _false
  spot="${gpu_spot##*_}"             # true or false

  machine="n1-standard-4"
  [[ "$gpu" == "nvidia-l4" ]] && machine="g2-standard-4"
  [[ "$gpu" == "nvidia-tesla-p100" || "$gpu" == "nvidia-tesla-v100" ]] && machine="n1-standard-8"

  spotlabel="on-demand"; [[ "$spot" == "true" ]] && spotlabel="spot"
  region="${zone%-*}"

  if [[ "$tier" == "available" ]]; then
    echo "  #$N — \$$cost/hr ($spotlabel)  [USE NOW]"
  else
    metric=$(quota_metric "$gpu" "$spot")
    echo "  #$N — \$$cost/hr ($spotlabel)  [REQUEST QUOTA FIRST]"
  fi

  if [[ "$zone" == "$CLUSTER_ZONE" ]]; then
    zone_note="current cluster zone"
  else
    zone_note="requires cluster move"
  fi

  echo "     gpu_type     : $gpu"
  echo "     machine_type : $machine"
  echo "     zone         : $zone  ($zone_note)"
  echo "     spot         : $spot"

  if [[ "$tier" == "quota" ]]; then
    echo "     → Request quota: $metric in region $region (limit: 1)"
    echo "       https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT"
  fi
  echo ""
  (( N++ ))
done <<< "$ALL_RESULTS"

# ── Situation summary ────────────────────────────────────────────────────────
echo "============================================================"
echo "Summary"
echo ""

AVAIL_COUNT=$(ls "$TMPDIR_RESULTS/available/" 2>/dev/null | wc -l | tr -d ' ')
QUOTA_COUNT=$(ls "$TMPDIR_RESULTS/quota/"     2>/dev/null | wc -l | tr -d ' ')

if [[ "$AVAIL_COUNT" -gt 0 ]]; then
  # Parse the cheapest available option
  BEST=$(ls "$TMPDIR_RESULTS/available/" | sort -t_ -k2 -n | head -1)
  BEST="${BEST#0_}"
  best_cost="${BEST%%_*}"; rest="${BEST#${best_cost}_}"
  best_zone="${rest%%_nvidia-*}"; gpu_spot="${rest#${best_zone}_}"
  best_gpu="${gpu_spot%_*}"; best_spot="${gpu_spot##*_}"
  best_machine="n1-standard-4"
  [[ "$best_gpu" == "nvidia-l4" ]] && best_machine="g2-standard-4"
  [[ "$best_gpu" == "nvidia-tesla-p100" || "$best_gpu" == "nvidia-tesla-v100" ]] && best_machine="n1-standard-8"
  best_spotlabel="on-demand"; [[ "$best_spot" == "true" ]] && best_spotlabel="spot"

  echo "  $AVAIL_COUNT option(s) available immediately. Cheapest: \$$best_cost/hr ($best_spotlabel) in $best_zone."
  echo ""
  if [[ "$best_zone" != "$CLUSTER_ZONE" ]]; then
    best_region="${best_zone%-*}"
    echo "  The cluster is in $CLUSTER_ZONE. To use $best_zone:"
    echo "    1. Edit gcp/terraform/terraform.tfvars:    zone = \"$best_zone\" / region = \"$best_region\""
    echo "       Edit gcp/terraform-gpu/gpu.tfvars:      cluster_zone = \"$best_zone\" / region = \"$best_region\""
    echo "    2. git commit -am 'move cluster to $best_zone' && git push"
    echo "    3. GKE Restore GPU → Miramar Platform Destroy → Miramar Platform Create"
    echo ""
    echo "  Then run GKE Expand GPU with:"
  else
    echo "  Run GKE Expand GPU with:"
  fi
  echo "    gpu_type     : $best_gpu"
  echo "    machine_type : $best_machine"
  echo "    spot         : $best_spot"

elif [[ "$QUOTA_COUNT" -gt 0 ]]; then
  # Parse cheapest quota option
  BEST=$(ls "$TMPDIR_RESULTS/quota/" | sort -t_ -k1 -n | head -1)
  best_cost="${BEST%%_*}"; rest="${BEST#${best_cost}_}"
  best_zone="${rest%%_nvidia-*}"; gpu_spot="${rest#${best_zone}_}"
  best_gpu="${gpu_spot%_*}"; best_spot="${gpu_spot##*_}"
  best_region="${best_zone%-*}"
  best_metric=$(quota_metric "$best_gpu" "$best_spot")
  best_spotlabel="on-demand"; [[ "$best_spot" == "true" ]] && best_spotlabel="spot"

  # Collect unique quota metrics needed across top results
  QUOTA_METRICS=$(ls "$TMPDIR_RESULTS/quota/" | sort -t_ -k1 -n | head -5 | while read -r f; do
    c="${f%%_*}"; r="${f#${c}_}"; z="${r%%_nvidia-*}"; gs="${r#${z}_}"; g="${gs%_*}"; s="${gs##*_}"
    reg="${z%-*}"
    quota_metric "$g" "$s" | sed "s/$/ in $reg/"
  done | sort -u)

  echo "  No GPU capacity available immediately — all options require quota first."
  echo ""
  echo "  The cluster currently has GPU quota only in ${CLUSTER_ZONE%-*},"
  echo "  but that region is physically exhausted."
  echo ""
  echo "  Cheapest path: \$$best_cost/hr ($best_spotlabel) using $best_gpu in $best_region."
  echo "  Request quota limit=1 for: $best_metric"
  echo "  → https://console.cloud.google.com/iam-admin/quotas?project=$PROJECT"
  echo ""
  echo "  Other useful quotas to request (covers top 5 options):"
  echo "$QUOTA_METRICS" | while read -r line; do echo "    $line"; done
  echo ""
  echo "  Once approved: update terraform.tfvars + gpu.tfvars zone/region, then"
  echo "  GKE Restore GPU → Miramar Platform Destroy → Miramar Platform Create → GKE Expand GPU."

else
  echo "  All zones exhausted (hardware shortage). No quota requests will help."
  echo "  Try again later or consider a different GPU type."
fi
echo ""
