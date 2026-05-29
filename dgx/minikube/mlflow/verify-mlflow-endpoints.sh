#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG (override via env) ----------
NS="${NS:-mlflow-system}"
SVC_TRACKING="${SVC_TRACKING:-mlflow-tracking}"
PORT_TRACKING="${PORT_TRACKING:-80}"
PF_START_TIMEOUT="${PF_START_TIMEOUT:-10}"
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
# -----------------------------------------------

GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; RESET=$'\033[0m'

need() { command -v "$1" >/dev/null 2>&1 || { echo "${RED}Missing: $1${RESET}" >&2; exit 2; }; }
need kubectl
need curl

find_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
}

wait_pf_ready() {
  local logfile="$1" local_port="$2"
  local end=$((SECONDS + PF_START_TIMEOUT))
  while (( SECONDS < end )); do
    grep -q "Forwarding from 127.0.0.1:${local_port}" "$logfile" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

with_port_forward() {
  local svc="$1" svc_port="$2" fn="$3"; shift 3
  local local_port logfile pid
  local_port="$(find_free_port)"
  logfile="/tmp/pf-mlflow-${svc}.log"
  kubectl -n "$NS" port-forward "svc/${svc}" "${local_port}:${svc_port}" >"$logfile" 2>&1 &
  pid=$!
  trap 'kill "$pid" >/dev/null 2>&1 || true' RETURN
  if ! wait_pf_ready "$logfile" "$local_port"; then
    echo "${RED}FAIL${RESET}  ${svc}: port-forward failed (port ${svc_port})"
    sed -n '1,20p' "$logfile" 2>/dev/null || true
    return 1
  fi
  "$fn" "$local_port" "$@"
}

_probe_inner() {
  local local_port="$1" name="$2" svc="$3" svc_port="$4"; shift 4
  local base="http://127.0.0.1:${local_port}"
  for path in "$@"; do
    if body="$(curl --silent --fail --max-time "$CURL_TIMEOUT" "${base}${path}" 2>/dev/null)"; then
      snip="$(echo "$body" | tr '\n' ' ' | cut -c1-100)"
      echo "${GREEN}PASS${RESET}  ${name}: ${svc}:${svc_port} -> ${path}  (${snip})"
      return 0
    fi
  done
  echo "${RED}FAIL${RESET}  ${name}: ${svc}:${svc_port} (no endpoint responded; tried: $*)"
  return 1
}

probe_http() {
  local name="$1" svc="$2" svc_port="$3"; shift 3
  if ! kubectl -n "$NS" get svc "$svc" >/dev/null 2>&1; then
    echo "${RED}FAIL${RESET}  ${name}: service '${svc}' not found in ns '${NS}'"
    return 1
  fi
  with_port_forward "$svc" "$svc_port" _probe_inner "$name" "$svc" "$svc_port" "$@"
}

main() {
  echo "==> Namespace: ${NS}"
  echo
  local failures=0

  # UI + backend health
  probe_http "MLflow tracking (health)" "$SVC_TRACKING" "$PORT_TRACKING" \
    "/health" "/" \
    || failures=$((failures+1))

  # DB connectivity — experiments/list hits the PostgreSQL backend store
  probe_http "MLflow tracking (DB)"    "$SVC_TRACKING" "$PORT_TRACKING" \
    "/api/2.0/mlflow/experiments/list" \
    || failures=$((failures+1))

  echo
  if [[ "$failures" -eq 0 ]]; then
    echo "${GREEN}All MLflow endpoints healthy.${RESET}"
    exit 0
  else
    echo "${RED}${failures} endpoint(s) failed.${RESET}"
    exit 1
  fi
}

main "$@"
