#!/usr/bin/env bash
set -euo pipefail

NS="default"
APP="modeldeployment-meta-llama-3-1-8b-instruct-dgx-spark"
CTR="${APP}-ctr"

latest_pod() {
  kubectl -n "$NS" get pods -l app="$APP" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1].metadata.name}'
}

wait_container_running() {
  local timeout_sec="${1:-1800}"
  local start now pod
  start="$(date +%s)"

  while :; do
    now="$(date +%s)"
    if (( now - start > timeout_sec )); then
      echo "Timed out waiting for $APP ($CTR) to start" >&2
      pod="$(latest_pod 2>/dev/null || true)"
      [[ -n "$pod" ]] && kubectl -n "$NS" describe pod "$pod" | tail -n 120 >&2 || true
      return 1
    fi

    pod="$(latest_pod 2>/dev/null || true)"
    if [[ -z "$pod" ]]; then
      echo "Waiting for pod with label app=$APP to appear..." >&2
      sleep 2
      continue
    fi

    # Pull out state in one shot (may be blank early on)
    local running waiting_reason terminated_reason
    running="$(kubectl -n "$NS" get pod "$pod" \
      -o jsonpath="{range .status.containerStatuses[?(@.name=='$CTR')]}{.state.running.startedAt}{end}" 2>/dev/null || true)"
    waiting_reason="$(kubectl -n "$NS" get pod "$pod" \
      -o jsonpath="{range .status.containerStatuses[?(@.name=='$CTR')]}{.state.waiting.reason}{end}" 2>/dev/null || true)"
    terminated_reason="$(kubectl -n "$NS" get pod "$pod" \
      -o jsonpath="{range .status.containerStatuses[?(@.name=='$CTR')]}{.state.terminated.reason}{end}" 2>/dev/null || true)"

    if [[ -n "$running" ]]; then
      echo "Container is running in pod=$pod" >&2
      echo "$pod"
      return 0
    fi

    # If containerStatuses not populated yet, waiting_reason/terminated_reason will be empty
    if [[ -n "$terminated_reason" ]]; then
      echo "Container terminated in pod=$pod: $terminated_reason" >&2
      kubectl -n "$NS" describe pod "$pod" | tail -n 120 >&2 || true
      return 1
    fi

    case "${waiting_reason:-}" in
      ContainerCreating|"")
        # "" happens when containerStatuses exists but the container isn't in waiting (rare), or not populated yet
        echo "Waiting... pod=$pod reason=${waiting_reason:-<none yet>}" >&2
        sleep 2
        ;;
      ImagePullBackOff|ErrImagePull|CreateContainerConfigError|CreateContainerError|RunContainerError|CrashLoopBackOff)
        echo "Container error in pod=$pod: $waiting_reason" >&2
        kubectl -n "$NS" describe pod "$pod" | tail -n 160 >&2 || true
        return 1
        ;;
      *)
        echo "Waiting... pod=$pod reason=$waiting_reason" >&2
        sleep 2
        ;;
    esac
  done
}

echo "Waiting for $APP ($CTR) to start..."
POD="$(wait_container_running 3600)"   # up to 60 minutes for big model pulls/loads
echo "Tailing logs from pod=$POD container=$CTR"
kubectl -n "$NS" logs -f "pod/$POD" -c "$CTR" --tail=200
