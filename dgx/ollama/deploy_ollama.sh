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
log "Checking for active NIM deployments..."
MINIKUBE_IP=$(minikube ip 2>/dev/null || true)
if [[ -n "$MINIKUBE_IP" ]]; then
  nim_response=$(curl -s --connect-timeout 5 --max-time 10 \
    -H "Host: nemo.test" \
    "http://${MINIKUBE_IP}/v1/deployment/model-deployments" 2>/dev/null || true)
  active_nims=$(printf '%s' "$nim_response" \
    | jq -r '.items[]? | select(.status_details.status == "ready") | "\(.namespace)/\(.name)"' \
    2>/dev/null || true)
  if [[ -n "$active_nims" ]]; then
    err "A NIM is currently deployed and holds GPU memory on the shared 128 GB pool:"
    while IFS= read -r nim; do err "  → $nim"; done <<< "$active_nims"
    warn "Run the NIM Undeploy workflow first, then retry."
    CONFLICT=1
  else
    log "No active NIM deployments."
  fi
else
  log "Minikube not running — skipping NIM conflict check."
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
