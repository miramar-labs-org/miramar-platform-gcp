#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG (override via env) ----------
NS="${NS:-postgres-system}"
SVC="${SVC:-postgres}"
DEPLOY="${DEPLOY:-postgres}"
# -----------------------------------------------

GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; RESET=$'\033[0m'

need() { command -v "$1" >/dev/null 2>&1 || { echo "${RED}Missing: $1${RESET}" >&2; exit 2; }; }
need kubectl

main() {
  echo "==> Namespace: ${NS}"
  echo
  local failures=0

  # Pod Ready
  if kubectl -n "$NS" rollout status "deploy/${DEPLOY}" --timeout=30s >/dev/null 2>&1; then
    echo "${GREEN}PASS${RESET}  Deployment ${DEPLOY}: rollout complete"
  else
    echo "${RED}FAIL${RESET}  Deployment ${DEPLOY}: not ready"
    failures=$((failures+1))
  fi

  # Service resolves -- i.e. the Service actually selects the ready pod
  if kubectl -n "$NS" get svc "$SVC" >/dev/null 2>&1; then
    endpoints="$(kubectl -n "$NS" get endpoints "$SVC" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
    if [[ -n "$endpoints" ]]; then
      echo "${GREEN}PASS${RESET}  Service ${SVC}: has endpoint(s) (${endpoints})"
    else
      echo "${RED}FAIL${RESET}  Service ${SVC}: no endpoints (pod not selected/ready)"
      failures=$((failures+1))
    fi
  else
    echo "${RED}FAIL${RESET}  Service ${SVC}: not found in ns '${NS}'"
    failures=$((failures+1))
  fi

  # pg_isready -- a protocol-level check, not HTTP, so this runs inside the pod itself rather than
  # via port-forward + curl (Postgres intentionally has no laptop tunnel; see README.md).
  if kubectl -n "$NS" exec "deploy/${DEPLOY}" -- pg_isready -U postgres >/dev/null 2>&1; then
    echo "${GREEN}PASS${RESET}  pg_isready: accepting connections"
  else
    echo "${RED}FAIL${RESET}  pg_isready: not accepting connections"
    failures=$((failures+1))
  fi

  echo
  if [[ "$failures" -eq 0 ]]; then
    echo "${GREEN}All Postgres endpoints healthy.${RESET}"
    exit 0
  else
    echo "${RED}${failures} check(s) failed.${RESET}"
    exit 1
  fi
}

main "$@"
