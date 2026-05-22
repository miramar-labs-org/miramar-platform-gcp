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

# === Phase X: Undeploy NIM ===
# USAGE: 
# source ./undeploy_nim.sh && undeploy_nim meta llama-3.1-8b-instruct-dgx-spark

undeploy_nim() {
  local nim_api_namespace="${1:?namespace required}"
  local nim_name="${2:?name required}"

  log "Requesting undeploy of $nim_name NIM..."

  # NeMo deployment API path pattern matches your wait_for_nim() URL:
  #   http://nemo.test/v1/deployment/model-deployments/$namespace/$name
  local url="http://nemo.test/v1/deployment/model-deployments/${nim_api_namespace}/${nim_name}"

  local body http
  body="$(curl -sS -w '\n%{http_code}' \
    --connect-timeout 10 \
    --max-time 30 \
    --location \
    -X DELETE "$url" \
    -H 'accept: application/json' \
    -H 'Content-Type: application/json' \
    || true)"

  http="${body##*$'\n'}"
  body="${body%$'\n'*}"

  # If the API returns 404 when it's already gone, treat as success.
  if [[ "$http" == "404" ]]; then
    warn "NIM $nim_api_namespace/$nim_name not found (already undeployed)."
    return 0
  fi

  if [[ ! "$http" =~ ^[0-9]+$ ]] || (( http < 200 || http >= 300 )); then
    err "NIM undeploy request failed (HTTP ${http:-unknown}). Response:"
    printf '%s\n' "${body:-<empty>}" >&2
    die "Failed to submit NIM undeploy request for $nim_name."
  fi

  log "NIM undeploy request for $nim_name submitted."
}
