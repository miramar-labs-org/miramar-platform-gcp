#!/usr/bin/env bash
# Runs on the AGX host via SSH — pipe via stdin:
#   ssh ... bash -s -- [model] [delete_model] < agx/ollama/undeploy_ollama.sh
# $1: model name (optional — auto-detected from ollama ps if not given)
# $2: delete model from disk (optional — "true" to run `ollama rm`)

set -euo pipefail

MODEL="${1:-}"
DELETE_MODEL="${2:-false}"
# Guard: SSH drops empty-string args, shifting delete_model into $1
if [[ ("$MODEL" == "true" || "$MODEL" == "false") && -z "${2:-}" ]]; then
  DELETE_MODEL="$MODEL"
  MODEL=""
fi

log()  { printf "\033[1;32m[INFO]\033[0m %b\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %b\n" "$*"; }
err()  { printf "\033[1;31m[ERROR]\033[0m %b\n" "$*" >&2; }

# --- Check Ollama is reachable ---
if ! curl -sf --connect-timeout 5 --max-time 10 \
  http://localhost:11434/api/tags >/dev/null 2>&1; then
  err "Ollama is not reachable at http://localhost:11434"
  warn "Nothing to undeploy — is the Ollama service running?"
  exit 1
fi

# --- Detect loaded model if not specified ---
if [[ -z "$MODEL" ]]; then
  log "No model specified — detecting from ollama ps..."
  MODEL=$(curl -s http://localhost:11434/api/ps 2>/dev/null \
    | jq -r '.models[0]?.name // ""' 2>/dev/null || true)
  if [[ -z "$MODEL" ]]; then
    log "No Ollama model is currently loaded. Nothing to do."
    exit 0
  fi
  log "Detected loaded model: $MODEL"
fi

# --- Unload from GPU memory ---
log "Unloading $MODEL from GPU memory..."
if ! curl -sf --connect-timeout 10 --max-time 120 \
  -X POST http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"\",\"keep_alive\":0}" \
  > /dev/null; then
  err "Unload request failed for model: $MODEL"
  exit 1
fi
log "Unload request sent."

# --- Verify (poll up to 60s for VRAM to free) ---
log "Waiting for model to unload..."
unloaded=false
for i in $(seq 1 30); do
  sleep 2
  remaining=$(curl -s http://localhost:11434/api/ps \
    | jq -r '.models[]?.name' 2>/dev/null || true)
  if [[ -z "$remaining" ]]; then
    unloaded=true
    break
  fi
done
if [[ "$unloaded" != "true" ]]; then
  err "Model still loaded after 60s: $remaining"
  exit 1
fi
log "GPU memory cleared."

# --- Optionally delete from disk ---
if [[ "$DELETE_MODEL" == "true" ]]; then
  log "Deleting $MODEL from disk..."
  ollama rm "$MODEL"
  log "Model deleted."
else
  log "Model kept on disk (set delete_model=true to also remove from disk)."
fi

log "Done."
