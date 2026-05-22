#!/usr/bin/env bash
# === Utility ===
# NOTE: Use %b (not %s) so embedded \n sequences render as real newlines.
log() { printf "\033[1;32m[INFO]\033[0m %b\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %b\n" "$*"; }
err() { printf "\033[1;31m[ERROR]\033[0m %b\n" "$*" >&2; }
suggest_fix() { printf "\033[1;36m[SUGGESTION]\033[0m %b\n" "$*"; }
die() {
  show_help
  err "$*"
  echo
  exit 1
}

# Toggle xtrace around noisy assignments so verbose mode doesn't show $'...\n...' blobs
_xtrace_push() { __XTRACE_WAS_ON=0; case "$-" in *x*) __XTRACE_WAS_ON=1; set +x ;; esac; }
_xtrace_pop()  { (( ${__XTRACE_WAS_ON:-0} )) && set -x; unset __XTRACE_WAS_ON; }

# Kubernetes namespace for NIM pods; inherits from parent script or defaults to "default"
NAMESPACE="${NAMESPACE:-default}"

# === Phase 6: Deploy NIM ===
# USAGE:
# source ./deploy_nim.sh && deploy_nim meta llama-3.1-8b-instruct-dgx-spark 1.0.0-variant

deploy_nim() {
  local nim_api_namespace="${1:?namespace required}"
  local nim_name="${2:?name required}"
  local image_tag="${3:?tag required}"

  log "Requesting deployment of $nim_name NIM..."

  local body http
  body="$(curl -sS -w '\n%{http_code}' \
    --connect-timeout 10 \
    --max-time 30 \
    --location "http://nemo.test/v1/deployment/model-deployments" \
    -H 'accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "{
      \"name\": \"${nim_name}\",
      \"namespace\": \"${nim_api_namespace}\",
      \"config\": {
        \"model\": \"${nim_api_namespace}/${nim_name}\",
        \"nim_deployment\": {
          \"image_name\": \"nvcr.io/nim/${nim_api_namespace}/${nim_name}\",
          \"image_tag\": \"${image_tag}\",
          \"pvc_size\": \"25Gi\",
          \"gpu\": 1,
          \"additional_envs\": {
            \"NIM_GUIDED_DECODING_BACKEND\": \"fast_outlines\"
          }
        }
      }
    }" || true)"

  http="${body##*$'\n'}"
  body="${body%$'\n'*}"

  if [[ ! "$http" =~ ^[0-9]+$ ]] || (( http < 200 || http >= 300 )); then
    err "NIM deploy request failed (HTTP ${http:-unknown}). Response:"
    printf '%s\n' "${body:-<empty>}" >&2
    die "Failed to submit NIM deployment request for $nim_name."
  fi

  log "NIM deployment request for $nim_name submitted."
  wait_for_nim $nim_api_namespace $nim_name
  verify_nim_endpoint
}

# === Phase 7: Wait for NIM Readiness ===
wait_for_nim() {
  local nim_api_namespace="${1:?namespace required}"
  local nim_name="${2:?name required}"
  local nim_label_selector="app=$nim_name"
  local nim_api_url="http://nemo.test/v1/deployment/model-deployments/$nim_api_namespace/$nim_name"

  log "Waiting for $nim_name NIM to reach READY status (up to 30 minutes)... Press Ctrl+C to exit early."

  local old_err_trap
  old_err_trap=$(trap -p ERR)
  trap 'echo "Interrupted by user during NIM wait. Exiting."; exit 1;' SIGINT

  local start_time end_time
  start_time=$(date +%s)
  end_time=$((start_time + 3600))

  while true; do
    local nim_pod_statuses
    _xtrace_push
    nim_pod_statuses="$(kubectl get pods -n "$NAMESPACE" -l "$nim_label_selector" --no-headers 2>/dev/null || true)"
    _xtrace_pop

    local nim_pod_names=()
    if [[ -n "$nim_pod_statuses" ]]; then
      mapfile -t nim_pod_names < <(printf '%s\n' "$nim_pod_statuses" | awk '{print $1}')
    fi

    if [[ -n "$nim_pod_statuses" ]]; then
      local image_pull_errors
      image_pull_errors="$(printf '%s\n' "$nim_pod_statuses" | grep -E "ImagePullBackOff|ErrImagePull" || true)"
      if [[ -n "$image_pull_errors" ]]; then
        err "Detected ImagePull errors for $nim_name NIM pods!"
        printf '%s\n' "$image_pull_errors" >&2
        warn "Gathering diagnostics for $nim_name pods with ImagePull errors..."
        local error_pods=()
        mapfile -t error_pods < <(printf '%s\n' "$image_pull_errors" | awk '{print $1}')
        local err_dir="nemo-errors-$(date +%s)"
        mkdir -p "$err_dir" || warn "Could not create error directory: $err_dir"
        for pod in "${error_pods[@]}"; do
          collect_pod_diagnostics "$pod" "$NAMESPACE" "$err_dir"
        done
        eval "$old_err_trap"
        trap - SIGINT
        echo ""
        err "Exiting due to ImagePull errors during $nim_name deployment"
        echo ""
        suggest_fix "This usually indicates an authentication issue with NGC registry"
        suggest_fix "Verify your NVIDIA API key is correct:"
        echo "  curl -H \"Authorization: Bearer \$NVIDIA_API_KEY\" https://api.ngc.nvidia.com/v2/org"
        echo ""
        suggest_fix "If authentication fails, regenerate your key at build.nvidia.com"
        suggest_fix "Then clean up and retry:"
        echo "  ./destroy-nmp-deployment.sh"
        echo "  ./$(basename "$0")"
        echo ""
        suggest_fix "Diagnostics collected to: $err_dir"
        exit 1
      fi
    fi

    # NOTE: don't use "status" (read-only in zsh)
    local nim_status
    nim_status="$(curl -s --fail --connect-timeout 5 --max-time 10 "$nim_api_url" 2>/dev/null | jq -r '.status_details.status' 2>/dev/null || true)"
    if [[ -z "$nim_status" || "$nim_status" == "null" ]]; then
      nim_status="API_UNAVAILABLE"
    fi

    if [[ "$nim_status" == "ready" ]]; then
      log "$nim_name NIM deployment successful and status is READY."
      break
    fi

    local is_downloading=false
    if [[ "$nim_status" != "ready" && ${#nim_pod_names[@]} -gt 0 ]]; then
      local nim_pod_name="${nim_pod_names[0]}"
      local pod_line readiness log_check_output
      pod_line="$(printf '%s\n' "$nim_pod_statuses" | grep -F "$nim_pod_name" || true)"
      readiness="$(printf '%s\n' "$pod_line" | awk '{print $2}' || true)"

      if [[ "$readiness" == 0/* ]]; then
        log_check_output="$(kubectl logs "$nim_pod_name" -n "$NAMESPACE" --tail 1 2>/dev/null || true)"
        if [[ -n "$log_check_output" ]]; then
          is_downloading=true
          log "NIM pod $nim_pod_name not ready ($readiness) but has logs; likely downloading/loading weights. API status: $nim_status. Waiting..."
        fi
      fi
    fi

    local current_time
    current_time=$(date +%s)
    if (( current_time >= end_time )); then
      err "Timeout waiting for $nim_name NIM to reach READY state after 30 minutes."
      warn "Gathering final diagnostics for $nim_name pods (if any exist)..."
      local final_pods=()
      mapfile -t final_pods < <(kubectl get pods -n "$NAMESPACE" -l "$nim_label_selector" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
      local err_dir="nemo-errors-$(date +%s)"
      mkdir -p "$err_dir" || warn "Could not create error directory: $err_dir"
      if [[ ${#final_pods[@]} -gt 0 ]]; then
        for pod in "${final_pods[@]}"; do
          collect_pod_diagnostics "$pod" "$NAMESPACE" "$err_dir"
        done
      else
        log "No pods found matching label $nim_label_selector to collect diagnostics from."
      fi
      log "Last known API status for $nim_name: $nim_status"
      kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' >"$err_dir/cluster_events.txt" 2>/dev/null || warn "Failed to get cluster events."
      eval "$old_err_trap"
      trap - SIGINT
      die "NIM deployment $nim_name did not reach READY state in time. Diagnostics gathered to $err_dir (if possible)."
    fi

    if ! $is_downloading; then
      if [[ ${#nim_pod_names[@]} -eq 0 ]]; then
        log "Waiting for NIM pod(s) with label $nim_label_selector to be created... API status: $nim_status"
      else
        log "Current $nim_name NIM status: $nim_status. Pod(s) found: ${nim_pod_names[*]}. Waiting..."
      fi
    fi

    sleep 15
  done

  eval "$old_err_trap"
  trap - SIGINT
  log "NIM deployment check complete."
}

# === Phase 8: Verify NIM Endpoint ===
verify_nim_endpoint() {
  local models_endpoint="http://nim.test/v1/models"
  log "Verifying NIM endpoint $models_endpoint is responsive..."

  local attempts=3
  local delay=5
  for ((i = 1; i <= attempts; i++)); do
    if curl --fail --silent --show-error --connect-timeout 5 --max-time 10 "$models_endpoint" >/dev/null; then
      log "✓ NIM endpoint $models_endpoint is up and responding"
      return 0
    fi
    if ((i < attempts)); then
      warn "NIM endpoint check failed (attempt $i/$attempts). Retrying in ${delay}s..."
      sleep "$delay"
    fi
  done

  echo ""
  err "Failed to verify NIM endpoint $models_endpoint after $attempts attempts"
  echo ""
  suggest_fix "This usually indicates a DNS or networking issue"
  suggest_fix "Verify DNS configuration:"
  echo "  cat /etc/hosts | grep nemo.test"
  echo "  Expected: $(minikube ip) nemo.test"
  echo ""
  suggest_fix "Test DNS resolution:"
  echo "  ping -c 1 nim.test"
  echo ""
  suggest_fix "Check ingress controller:"
  echo "  kubectl get ingress -n default"
  echo "  kubectl get pods -n ingress-nginx"
  echo ""
  warn "Attempting verbose connection for debugging:"
  curl -v "$models_endpoint" 2>&1 || true
  echo ""
  exit 1
}
