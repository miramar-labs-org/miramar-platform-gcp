#!/usr/bin/env bash
# Runs on the DGX host via SSH — pipe via stdin, pass model as $1:
#   ssh ... bash -s -- <model> < dgx/ollama/deploy_ollama.sh

set -euo pipefail

MODEL="${1:?model name required (e.g. llama3.3:70b-instruct-q4_K_M)}"

log()  { printf "\033[1;32m[INFO]\033[0m %b\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %b\n" "$*"; }
err()  { printf "\033[1;31m[ERROR]\033[0m %b\n" "$*" >&2; }

CONFLICT=0

# --- Check Ollama is reachable ---
log "Checking Ollama service..."
if ! curl -sf --connect-timeout 5 --max-time 10 \
  http://localhost:11434/api/tags >/dev/null 2>&1; then
  err "Ollama is not reachable at http://localhost:11434"
  warn "Start the service: sudo systemctl start ollama"
  exit 1
fi

# --- Check for NIM conflict ---
# The minikube Docker network is not routed from the DGX host OS, so we cannot curl
# the ingress IP directly. Instead: kubectl port-forward to the NeMo API service
# (kubectl works on the host since ~/.kube/config and ~/.minikube/ are present),
# with a pod-label check as fallback if the namespace or ingress is not found.
log "Checking for active NIM deployments..."
active_nims=""

if kubectl --context minikube get ns nemo-microservices &>/dev/null 2>&1; then
  # Find the NeMo API service that backs the nemo.test host in the ingress
  nemo_svc=$(kubectl --context minikube get ingress -n nemo-microservices -o json 2>/dev/null \
    | jq -r '
        .items[].spec.rules[]
        | select(.host == "nemo.test")
        | .http.paths[0].backend.service
        | "\(.name):\(.port.number // .port.name)"
      ' 2>/dev/null | head -1 || true)

  if [[ -n "$nemo_svc" ]]; then
    svc_name="${nemo_svc%:*}"
    svc_port="${nemo_svc#*:}"
    pf_port=19871

    kubectl --context minikube port-forward -n nemo-microservices \
      "svc/${svc_name}" "${pf_port}:${svc_port}" &>/dev/null &
    pf_pid=$!
    sleep 2

    nim_response=$(curl -s --connect-timeout 5 --max-time 10 \
      "http://localhost:${pf_port}/v1/deployment/model-deployments" 2>/dev/null || true)
    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true

    # Any item in the list means a NIM is registered (deploying or ready)
    nim_count=$(printf '%s' "$nim_response" | jq '.items | length' 2>/dev/null || echo 0)
    if (( nim_count > 0 )); then
      active_nims=$(printf '%s' "$nim_response" \
        | jq -r '.items[] | "\(.namespace // "")/\(.name)"' 2>/dev/null || true)
    fi
  else
    # Fallback: check for running pods whose app label matches DGX Spark NIM naming
    log "NeMo ingress not found — falling back to pod check."
    active_nims=$(kubectl --context minikube get pods -n nemo-microservices \
      --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.labels.app}{"\n"}{end}' \
      2>/dev/null | grep -v '^$' | grep 'dgx-spark' || true)
  fi
else
  log "nemo-microservices namespace not found — no NIM deployed."
fi

if [[ -n "$active_nims" ]]; then
  err "A NIM is currently deployed and holds GPU memory on the shared 128 GB pool:"
  while IFS= read -r nim; do err "  → $nim"; done <<< "$active_nims"
  warn "Run the NIM Undeploy workflow first, then retry."
  CONFLICT=1
else
  log "No active NIM deployments."
fi

# --- Check for Ollama model already loaded ---
log "Checking for loaded Ollama models..."
loaded=$(curl -s --connect-timeout 5 --max-time 10 \
  http://localhost:11434/api/ps 2>/dev/null \
  | jq -r '.models[]?.name' 2>/dev/null || true)
if [[ -n "$loaded" ]]; then
  err "An Ollama model is already loaded in GPU memory:"
  while IFS= read -r m; do err "  → $m"; done <<< "$loaded"
  warn "Run the Ollama Undeploy workflow first, then retry."
  CONFLICT=1
else
  log "No Ollama models currently loaded."
fi

if (( CONFLICT )); then
  echo ""
  err "Cannot deploy $MODEL — resolve the conflict(s) above first."
  exit 1
fi

# --- Pull model ---
log "Pulling $MODEL (no-op if already on disk)..."
ollama pull "$MODEL"

# --- Load into GPU memory ---
log "Loading $MODEL into GPU memory (keep_alive=-1 = permanent until undeployed)..."
curl -sf --connect-timeout 10 --max-time 300 \
  -X POST http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"keep_alive\":-1}" \
  | jq -r 'if .done then empty else "response: \(.)" end' 2>/dev/null || true

# --- Verify ---
log "Verifying..."
result=$(curl -s http://localhost:11434/api/ps \
  | jq -r '.models[] | "\(.name)  (\((.size_vram // 0) / 1073741824 | . * 10 | round / 10) GB VRAM)"' \
  2>/dev/null || true)
if [[ -z "$result" ]]; then
  warn "Model not showing in ollama ps — it may still be loading. Check with: ollama ps"
else
  log "Loaded: $result"
fi

log "Done. $MODEL is ready at http://localhost:11434/v1"
