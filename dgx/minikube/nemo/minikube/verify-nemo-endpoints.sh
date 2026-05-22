#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG (edit or override via env) ----------
NS="${NS:-default}"

SVC_EVALUATOR="${SVC_EVALUATOR:-nemo-evaluator}"
SVC_CUSTOMIZER="${SVC_CUSTOMIZER:-nemo-customizer}"
SVC_ENTITY_STORE="${SVC_ENTITY_STORE:-nemo-entity-store}"
SVC_DATASTORE="${SVC_DATASTORE:-nemo-postgresql}"     # postgres svc
SVC_NIM_INFER="${SVC_NIM_INFER:-nemo-nim-proxy}"     # or nimservice svc name

# Set to a number OR "auto" (auto picks first port on the service)
PORT_HTTP_EVALUATOR="${PORT_HTTP_EVALUATOR:-auto}"
PORT_HTTP_CUSTOMIZER="${PORT_HTTP_CUSTOMIZER:-auto}"
PORT_HTTP_ENTITY_STORE="${PORT_HTTP_ENTITY_STORE:-auto}"
PORT_HTTP_NIM="${PORT_HTTP_NIM:-auto}"
PORT_TCP_DATASTORE="${PORT_TCP_DATASTORE:-5432}"

HTTP_PATHS=("/health" "/v1/health" "/v1/health/ready" "/readyz" "/livez")
SKIP_PSQL="${SKIP_PSQL:-1}"              # default: just TCP connect
PF_START_TIMEOUT="${PF_START_TIMEOUT:-10}"
CURL_TIMEOUT="${CURL_TIMEOUT:-3}"
# ------------------------------------------------------

GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; YELLOW=$'\033[1;33m'; RESET=$'\033[0m'

need() { command -v "$1" >/dev/null 2>&1 || { echo "${RED}Missing: $1${RESET}" >&2; exit 2; }; }
need kubectl
need curl

find_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

svc_ports() {
  local svc="$1"
  kubectl -n "$NS" get svc "$svc" -o jsonpath='{range .spec.ports[*]}{.name}{" "}{.port}{" "}{.targetPort}{"\n"}{end}' 2>/dev/null || true
}

resolve_port() {
  local svc="$1" requested="$2"
  if [[ "$requested" != "auto" ]]; then
    echo "$requested"
    return 0
  fi
  # first .spec.ports[0].port
  kubectl -n "$NS" get svc "$svc" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true
}

wait_pf_ready() {
  local logfile="$1" local_port="$2"
  local end=$((SECONDS + PF_START_TIMEOUT))
  while (( SECONDS < end )); do
    if grep -q "Forwarding from 127.0.0.1:${local_port}" "$logfile" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

with_port_forward() {
  local svc="$1" svc_port="$2"
  local fn="$3"
  shift 3

  local local_port logfile pid
  local_port="$(find_free_port)"
  logfile="/tmp/pf-${svc}-${svc_port}.log"
  pid=""

  # Start port-forward
  kubectl -n "$NS" port-forward "svc/${svc}" "${local_port}:${svc_port}" >"$logfile" 2>&1 &
  pid=$!

  # Cleanup always
  cleanup_pf() { [[ -n "${pid:-}" ]] && kill "$pid" >/dev/null 2>&1 || true; }
  trap cleanup_pf RETURN

  if ! wait_pf_ready "$logfile" "$local_port"; then
    echo "${RED}FAIL${RESET}  ${svc} (port-forward failed on service port ${svc_port})"
    sed -n '1,120p' "$logfile" 2>/dev/null || true
    echo "${YELLOW}Service ports for ${svc}:${RESET}"
    svc_ports "$svc" | sed 's/^/  /' || true
    return 1
  fi

  "$fn" "$local_port" "$@"
}

probe_http() {
  local name="$1" svc="$2" port_req="$3"

  if ! kubectl -n "$NS" get svc "$svc" >/dev/null 2>&1; then
    echo "${RED}FAIL${RESET}  ${name}: service '${svc}' not found in ns '${NS}'"
    return 1
  fi

  local port
  port="$(resolve_port "$svc" "$port_req")"
  if [[ -z "${port:-}" ]]; then
    echo "${RED}FAIL${RESET}  ${name}: could not resolve port for service '${svc}' (set PORT_* or use auto)"
    echo "${YELLOW}Service ports for ${svc}:${RESET}"
    svc_ports "$svc" | sed 's/^/  /' || true
    return 1
  fi

  # Validate requested/auto port exists on service
  if ! kubectl -n "$NS" get svc "$svc" -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' | grep -qx "$port"; then
    echo "${RED}FAIL${RESET}  ${name}: service '${svc}' does not have a service port ${port}"
    echo "${YELLOW}Service ports for ${svc}:${RESET}"
    svc_ports "$svc" | sed 's/^/  /' || true
    return 1
  fi

  with_port_forward "$svc" "$port" _probe_http_inner "$name" "$svc" "$port"
}

_probe_http_inner() {
  local local_port="$1" name="$2" svc="$3" svc_port="$4"
  local base="http://127.0.0.1:${local_port}"

  for path in "${HTTP_PATHS[@]}"; do
    if body="$(curl --silent --show-error --fail --max-time "$CURL_TIMEOUT" "${base}${path}" 2>/dev/null)"; then
      snip="$(echo "$body" | tr '\n' ' ' | cut -c1-120)"
      echo "${GREEN}PASS${RESET}  ${name}: ${svc}:${svc_port} -> ${path}  (${snip})"
      return 0
    fi
  done

  echo "${RED}FAIL${RESET}  ${name}: ${svc}:${svc_port} (no health endpoint responded; tried ${HTTP_PATHS[*]})"
  return 1
}

probe_postgres() {
  local name="$1" svc="$2" port="$3"

  if ! kubectl -n "$NS" get svc "$svc" >/dev/null 2>&1; then
    echo "${RED}FAIL${RESET}  ${name}: service '${svc}' not found in ns '${NS}'"
    return 1
  fi

  if ! kubectl -n "$NS" get svc "$svc" -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' | grep -qx "$port"; then
    echo "${RED}FAIL${RESET}  ${name}: service '${svc}' does not have a service port ${port}"
    echo "${YELLOW}Service ports for ${svc}:${RESET}"
    svc_ports "$svc" | sed 's/^/  /' || true
    return 1
  fi

  if [[ "$SKIP_PSQL" == "1" ]]; then
    with_port_forward "$svc" "$port" _probe_tcp_inner "$name" "$svc" "$port"
    return $?
  fi

  need psql
  : "${PGUSER:?Set PGUSER (or set SKIP_PSQL=1)}"
  : "${PGPASSWORD:?Set PGPASSWORD (or set SKIP_PSQL=1)}"
  : "${PGDATABASE:?Set PGDATABASE (or set SKIP_PSQL=1)}"
  with_port_forward "$svc" "$port" _probe_psql_inner "$name" "$svc" "$port"
}

_probe_tcp_inner() {
  local local_port="$1" name="$2" svc="$3" svc_port="$4"
  if timeout 2 bash -lc "echo >/dev/tcp/127.0.0.1/${local_port}" 2>/dev/null; then
    echo "${GREEN}PASS${RESET}  ${name}: ${svc}:${svc_port} (TCP connect OK)"
    return 0
  fi
  echo "${RED}FAIL${RESET}  ${name}: ${svc}:${svc_port} (TCP connect failed)"
  return 1
}

_probe_psql_inner() {
  local local_port="$1" name="$2" svc="$3" svc_port="$4"
  if PGPASSWORD="$PGPASSWORD" psql -h 127.0.0.1 -p "$local_port" -U "$PGUSER" -d "$PGDATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
    echo "${GREEN}PASS${RESET}  ${name}: ${svc}:${svc_port} (psql SELECT 1 OK)"
    return 0
  fi
  echo "${RED}FAIL${RESET}  ${name}: ${svc}:${svc_port} (psql auth/query failed)"
  return 1
}

main() {
  echo "==> Namespace: ${NS}"
  echo "==> Probing fixed endpoints (no discovery)"
  echo

  local failures=0

  probe_http "Evaluator"     "$SVC_EVALUATOR"     "$PORT_HTTP_EVALUATOR" || failures=$((failures+1))
  probe_http "Customizer"    "$SVC_CUSTOMIZER"    "$PORT_HTTP_CUSTOMIZER" || failures=$((failures+1))
  probe_http "Entity Store"  "$SVC_ENTITY_STORE"  "$PORT_HTTP_ENTITY_STORE" || failures=$((failures+1))
  probe_http "NIM Inference" "$SVC_NIM_INFER"      "$PORT_HTTP_NIM" || failures=$((failures+1))
  probe_postgres "Datastore" "$SVC_DATASTORE"     "$PORT_TCP_DATASTORE" || failures=$((failures+1))

  echo
  if [[ "$failures" -eq 0 ]]; then
    echo "${GREEN}All requested endpoints look healthy.${RESET}"
    exit 0
  else
    echo "${RED}${failures} endpoint(s) failed.${RESET}"
    exit 1
  fi
}

main "$@"
