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
# the ingress IP directly. Strategy:
#  1. kubectl port-forward to nemo-deployment-management:8000 and query the API
#     (NeMo API response uses "data" array, not "items")
#  2. Fall back to kubectl label selector app.nvidia.com/nim-type=inference if the
#     namespace or service is unavailable
log "Checking for active NIM deployments..."
active_nims=""

if kubectl --context minikube get ns nemo-microservices &>/dev/null 2>&1; then
  pf_port=19871
  kubectl --context minikube port-forward -n nemo-microservices \
    svc/nemo-deployment-management "${pf_port}:8000" &>/dev/null &
  pf_pid=$!
  sleep 2

  nim_response=$(curl -s --connect-timeout 5 --max-time 10 \
    "http://localhost:${pf_port}/v1/deployment/model-deployments" 2>/dev/null || true)
  kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true

  # NeMo API returns { "data": [...] } — any entry means a NIM is registered
  nim_count=$(printf '%s' "$nim_response" | jq '.data | length' 2>/dev/null || echo 0)
  if (( nim_count > 0 )); then
    active_nims=$(printf '%s' "$nim_response" \
      | jq -r '.data[] | "\(.namespace)/\(.name)"' 2>/dev/null || true)
  else
    # Fallback: pods labelled as NIM inference pods (set by k8s-nim-operator)
    active_nims=$(kubectl --context minikube get pods -n nemo-microservices \
      -l 'app.nvidia.com/nim-type=inference' \
      --field-selector=status.phase=Running \
      --no-headers \
      -o custom-columns='APP:.metadata.labels.app' \
      2>/dev/null | grep -v '^$' || true)
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
# Retry up to 3 times: Ollama downloads from Cloudflare R2 and DNS resolution
# for that CDN hostname can transiently fail ("server misbehaving" from
# systemd-resolved), causing the pull to fail after ~10 minutes of retries.
# Each failed attempt exits non-zero — catch it explicitly and retry with backoff
# so the error is visible rather than silently killing the script via pipefail.
MAX_PULL_ATTEMPTS=3
for attempt in $(seq 1 $MAX_PULL_ATTEMPTS); do
  log "Pulling $MODEL (attempt $attempt/$MAX_PULL_ATTEMPTS)..."
  if ollama pull "$MODEL"; then
    break
  fi
  if (( attempt == MAX_PULL_ATTEMPTS )); then
    err "ollama pull failed after $MAX_PULL_ATTEMPTS attempts."
    err "Last error is above. Common cause: transient DNS failure for Cloudflare R2."
    warn "Diagnostics:"
    warn "  curl -sv https://ollama.com 2>&1 | grep -E 'Host|Connected|SSL'"
    warn "  sudo resolvectl flush-caches && sudo systemctl restart systemd-resolved"
    exit 1
  fi
  warn "Pull attempt $attempt failed — retrying in 60s..."
  sleep 60
done

# Verify the model actually landed — ollama pull can exit 0 on partial failures
if ! ollama list 2>/dev/null | grep -q "^${MODEL%%:*}"; then
  err "Model $MODEL not found in 'ollama list' after pull — download may be incomplete."
  err "Run: ollama list"
  exit 1
fi

# --- Load into GPU memory ---
log "Loading $MODEL into GPU memory (keep_alive=-1 = permanent until undeployed)..."
curl -sf --connect-timeout 10 --max-time 600 \
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
