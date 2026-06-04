#!/usr/bin/env bash
# Generate a self-contained dashboard.html listing all public Miramar platform repos.
# Usage: GH_TOKEN=<token> [GH_ADMIN_TOKEN=<token>] [GH_DISPATCH_TOKEN=<token>] bash generate-dashboard.sh --org <org> --output <path>
#
# GH_TOKEN          — GITHUB_TOKEN; used for org repo listing (read:public_repo)
# GH_ADMIN_TOKEN    — GITHUB_ORG_ADMIN_PAT; used for per-project workflow run queries
#                     (falls back to GH_TOKEN if not set, but won't work for private runner data)
# GH_DISPATCH_TOKEN — DASHBOARD_DISPATCH_TOKEN; embedded in HTML for browser → workflow dispatch
#                     Fine-grained PAT: Actions write on miramar-platform-gcp only
set -euo pipefail

ORG=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)    ORG="$2";    shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$ORG" ]]    && { echo "ERROR: --org required" >&2; exit 1; }
[[ -z "$OUTPUT" ]] && { echo "ERROR: --output required" >&2; exit 1; }
[[ -z "${GH_TOKEN:-}" ]] && { echo "ERROR: GH_TOKEN not set" >&2; exit 1; }

ADMIN_TOKEN="${GH_ADMIN_TOKEN:-$GH_TOKEN}"
DISPATCH_TOKEN="${GH_DISPATCH_TOKEN:-}"

mkdir -p "$(dirname "$OUTPUT")"

echo "==> Fetching public repos for ${ORG} ..."
REPOS_JSON=$(GH_TOKEN="$GH_TOKEN" gh api --paginate \
  "orgs/${ORG}/repos?type=public&per_page=100" \
  --jq '[.[] | select(.topics != null and (.topics | index("miramar-project") != null))]')

REPO_COUNT=$(echo "$REPOS_JSON" | jq 'length')
echo "    Found ${REPO_COUNT} repos tagged miramar-project"

# Build HTML rows in a bash loop so we can augment each repo with live workflow status
ROWS=""
while IFS= read -r repo_json; do
  name=$(echo    "$repo_json" | jq -r '.name')
  url=$(echo     "$repo_json" | jq -r '.html_url')
  type=$(echo    "$repo_json" | jq -r '.topics | if index("miramar-kfp-ft-eval") then "kfp-ft-eval" elif index("miramar-kfp-finetune") then "kfp-finetune" elif index("miramar-kfp") then "kfp" elif index("miramar-nemo") then "nemo" elif index("miramar-default") then "default" else "other" end')
  desc=$(echo    "$repo_json" | jq -r '.description // ""')
  sha=$(GH_TOKEN="$GH_TOKEN" gh api \
    "repos/${ORG}/${name}/commits?per_page=1" 2>/dev/null \
    | jq -r 'if type == "array" then (.[0].sha // "")[:7] else "" end' 2>/dev/null || echo "")

  # --- Host affinity (PROJECT_HOST repo variable, set by Create Project workflow) ---
  # gh api outputs the 404 JSON body to stdout on error, so capture raw JSON and
  # extract with jq separately to avoid concatenating error body with the fallback.
  host_json=$(GH_TOKEN="$ADMIN_TOKEN" gh api \
    "repos/${ORG}/${name}/actions/variables/PROJECT_HOST" 2>/dev/null) || host_json="{}"
  host=$(printf '%s' "$host_json" | jq -r '.value // empty')
  [[ -z "$host" || "$host" == "null" ]] && host="dgx"
  host_html="<span class=\"badge badge-${host}\">${host}</span>"

  # --- JupyterLab direct link — port depends on host (DGX=8888, AGX=8887) ---
  jl_port=8888; [[ "$host" == "agx" ]] && jl_port=8887
  jl_path="git-miramar-labs-org/projects/${name}/notebook.ipynb"
  jl_url="http://localhost:${jl_port}/lab/tree/${jl_path}"
  jl_html="<a href=\"${jl_url}\" class=\"jl-link\" title=\"${jl_url}\">&#x1F9EA; Open</a>"

  ROWS+="<tr>
  <td><a href=\"${url}\" target=\"_blank\">${name}</a></td>
  <td><span class=\"badge badge-${type}\">${type}</span></td>
  <td>${desc}</td>
  <td>${host_html}</td>
  <td>${jl_html}</td>
  <td><code>${sha}</code></td>
  <td><button class=\"del-btn\" data-repo=\"${name}\" title=\"Delete ${name}\">&#x1F5D1;</button></td>
</tr>
"
done < <(echo "$REPOS_JSON" | jq -c '
  sort_by(
    (.topics // []) | map(select(test("^order-[0-9]+$"))) | .[0]
    | if . then (ltrimstr("order-") | tonumber) else 9999 end
  ) | .[]
')

GENERATED_AT=$(date -u '+%Y-%m-%d %H:%M UTC')

# --- Platform state ---
echo "==> Fetching platform state..."
read_platform_var() {
  local val
  val=$(GH_TOKEN="$ADMIN_TOKEN" gh api \
    "repos/${ORG}/miramar-platform-gcp/actions/variables/${1}" \
    --jq '.value' 2>/dev/null) || val=""
  echo "${val}"
}
read_org_var() {
  local val
  val=$(GH_TOKEN="$ADMIN_TOKEN" gh api \
    "orgs/${ORG}/actions/variables/${1}" \
    --jq '.value' 2>/dev/null) || val=""
  echo "${val}"
}
NIM_MODEL=$(read_platform_var "CURRENT_NIM_MODEL")
OLLAMA_MODEL=$(read_platform_var "CURRENT_OLLAMA_MODEL")
NIM_VRAM_GB=$(read_platform_var "CURRENT_NIM_VRAM_GB")
OLLAMA_VRAM_GB=$(read_platform_var "CURRENT_OLLAMA_VRAM_GB")
DGX_VRAM_USEABLE=$(read_org_var "DGX_VRAM_USEABLE")
DGX_MINIKUBE_ACTIVE=$(read_org_var "DGX_MINIKUBE_ACTIVE")
DGX_NEMO_ACTIVE=$(read_org_var "DGX_NEMO_ACTIVE")
DGX_KFP_ACTIVE=$(read_org_var "DGX_KFP_ACTIVE")
DGX_OLLAMA_ACTIVE=$(read_org_var "DGX_OLLAMA_ACTIVE")
DGX_MLFLOW_ACTIVE=$(read_org_var "DGX_MLFLOW_ACTIVE")
DGX_QDRANT_ACTIVE=$(read_org_var "DGX_QDRANT_ACTIVE")

AGX_OLLAMA_MODEL=$(read_platform_var "CURRENT_OLLAMA_MODEL_AGX")
AGX_OLLAMA_VRAM_GB=$(read_platform_var "CURRENT_OLLAMA_VRAM_GB_AGX")
AGX_NIM_MODEL=$(read_platform_var "CURRENT_NIM_MODEL_AGX")
AGX_NIM_VRAM_GB=$(read_platform_var "CURRENT_NIM_VRAM_GB_AGX")
AGX_VRAM_USEABLE=$(read_org_var "AGX_VRAM_USEABLE")
AGX_MINIKUBE_ACTIVE=$(read_org_var "AGX_MINIKUBE_ACTIVE")
AGX_NEMO_ACTIVE=$(read_org_var "AGX_NEMO_ACTIVE")
AGX_KFP_ACTIVE=$(read_org_var "AGX_KFP_ACTIVE")
AGX_OLLAMA_ACTIVE=$(read_org_var "AGX_OLLAMA_ACTIVE")
AGX_MLFLOW_ACTIVE=$(read_org_var "AGX_MLFLOW_ACTIVE")
AGX_QDRANT_ACTIVE=$(read_org_var "AGX_QDRANT_ACTIVE")

GCP_PROJECT_ID=$(read_org_var "GCP_PROJECT_ID")
GCP_REGION=$(read_org_var "GCP_REGION")
GAR_REPO=$(read_org_var "GAR_REPO")
GKE_CLUSTER_NAME=$(read_org_var "GKE_CLUSTER_NAME")
GKE_ZONE=$(read_org_var "GKE_ZONE")
GKE_STATE_BUCKET=$(read_org_var "GKE_STATE_BUCKET")
GKE_CLUSTER_ACTIVE=$(read_org_var "GKE_CLUSTER_ACTIVE")
GKE_GPU_POOL_ACTIVE=$(read_org_var "GKE_GPU_POOL_ACTIVE")
GKE_GPU_TYPE=$(read_org_var "GKE_GPU_TYPE")
GKE_NODE_COUNT=$(read_org_var "GKE_NODE_COUNT")

[[ -z "$NIM_MODEL" ]]      && NIM_MODEL="none"
[[ -z "$OLLAMA_MODEL" ]]   && OLLAMA_MODEL="none"
[[ -z "$NIM_VRAM_GB" || "$NIM_VRAM_GB" == "null" ]]       && NIM_VRAM_GB="0"
[[ -z "$OLLAMA_VRAM_GB" || "$OLLAMA_VRAM_GB" == "null" ]] && OLLAMA_VRAM_GB="0"
[[ -z "$DGX_VRAM_USEABLE" || "$DGX_VRAM_USEABLE" == "null" ]] && DGX_VRAM_USEABLE="100"
[[ -z "$AGX_OLLAMA_MODEL" ]]   && AGX_OLLAMA_MODEL="none"
[[ -z "$AGX_OLLAMA_VRAM_GB" || "$AGX_OLLAMA_VRAM_GB" == "null" ]] && AGX_OLLAMA_VRAM_GB="0"
[[ -z "$AGX_VRAM_USEABLE" || "$AGX_VRAM_USEABLE" == "null" ]] && AGX_VRAM_USEABLE="40"
[[ -z "$AGX_NIM_MODEL" ]]      && AGX_NIM_MODEL="none"
[[ -z "$AGX_NIM_VRAM_GB" || "$AGX_NIM_VRAM_GB" == "null" ]] && AGX_NIM_VRAM_GB="0"
[[ -z "$GCP_PROJECT_ID" ]]      && GCP_PROJECT_ID="miramar-platform"
[[ -z "$GCP_REGION" ]]          && GCP_REGION="us-central1"
[[ -z "$GAR_REPO" ]]            && GAR_REPO="apps"
[[ -z "$GKE_CLUSTER_NAME" ]]    && GKE_CLUSTER_NAME="miramar-shared-gke"
[[ -z "$GKE_ZONE" ]]            && GKE_ZONE="us-central1-b"
[[ -z "$GKE_STATE_BUCKET" ]]    && GKE_STATE_BUCKET="miramar-platform-cluster-state"
[[ -z "$GKE_CLUSTER_ACTIVE" ]] && GKE_CLUSTER_ACTIVE="false"
[[ -z "$GKE_GPU_POOL_ACTIVE" ]] && GKE_GPU_POOL_ACTIVE="false"
[[ -z "$GKE_GPU_TYPE" || "$GKE_GPU_TYPE" == "none" ]] && GKE_GPU_TYPE=""
[[ -z "$GKE_NODE_COUNT" ]] && GKE_NODE_COUNT="1"

VRAM_USED_GB=$(( NIM_VRAM_GB + OLLAMA_VRAM_GB ))
VRAM_AVAIL_GB=$(( DGX_VRAM_USEABLE - VRAM_USED_GB ))
(( VRAM_AVAIL_GB < 0 )) && VRAM_AVAIL_GB=0

AGX_VRAM_USED_GB=$(( AGX_NIM_VRAM_GB + AGX_OLLAMA_VRAM_GB ))
AGX_VRAM_AVAIL_GB=$(( AGX_VRAM_USEABLE - AGX_VRAM_USED_GB ))
(( AGX_VRAM_AVAIL_GB < 0 )) && AGX_VRAM_AVAIL_GB=0

NIM_CLASS="ps-value";    [[ "$NIM_MODEL"    == "none" ]] && NIM_CLASS="ps-value ps-none"
OLLAMA_CLASS="ps-value"; [[ "$OLLAMA_MODEL" == "none" ]] && OLLAMA_CLASS="ps-value ps-none"
VRAM_AVAIL_CLASS="ps-value"
(( VRAM_AVAIL_GB < 20 )) && VRAM_AVAIL_CLASS="ps-value ps-warn"

AGX_NIM_CLASS="ps-value";    [[ "$AGX_NIM_MODEL"    == "none" ]] && AGX_NIM_CLASS="ps-value ps-none"
AGX_OLLAMA_CLASS="ps-value"; [[ "$AGX_OLLAMA_MODEL" == "none" ]] && AGX_OLLAMA_CLASS="ps-value ps-none"
AGX_VRAM_AVAIL_CLASS="ps-value"
(( AGX_VRAM_AVAIL_GB < 10 )) && AGX_VRAM_AVAIL_CLASS="ps-value ps-warn"

GAR_URL="https://console.cloud.google.com/artifacts/docker/${GCP_PROJECT_ID}/${GCP_REGION}/${GAR_REPO}"
GCS_BUCKET_URL="https://console.cloud.google.com/storage/browser/${GKE_STATE_BUCKET}?project=${GCP_PROJECT_ID}"

if [ "$GKE_CLUSTER_ACTIVE" = "true" ]; then
  GKE_CLUSTER_BADGE="<a href=\"https://console.cloud.google.com/kubernetes/list/overview?project=${GCP_PROJECT_ID}\" target=\"_blank\" class=\"ps-active\">${GKE_CLUSTER_NAME}</a>"
  GKE_ZONE_HTML="<code class=\"ps-value\">${GKE_ZONE}</code>"
  GKE_NODE_TYPE_HTML='<code class="ps-value">e2-medium</code>'
  GKE_BUCKET_HTML="<a href=\"${GCS_BUCKET_URL}\" target=\"_blank\" class=\"ps-value\">${GKE_STATE_BUCKET}</a>"
  GKE_GAR_HTML="<a href=\"${GAR_URL}\" target=\"_blank\" class=\"ps-value\">${GCP_PROJECT_ID}/${GCP_REGION}/${GAR_REPO}</a>"
  if [ "$GKE_GPU_POOL_ACTIVE" = "true" ]; then
    GPU_LABEL="${GKE_GPU_TYPE:-gpu}"
    GKE_GPU_BADGE="<span class=\"ps-active\">${GPU_LABEL}</span>"
  else
    GKE_GPU_BADGE='<span class="ps-inactive">none</span>'
  fi
  if [ "$GKE_NODE_COUNT" -gt 1 ] 2>/dev/null; then
    GKE_CPU_BADGE="<span class=\"ps-active\">${GKE_NODE_COUNT} nodes</span>"
  else
    GKE_CPU_BADGE='<code class="ps-value">1 node</code>'
  fi
else
  GKE_CLUSTER_BADGE='<span class="ps-inactive">INACTIVE</span>'
  GKE_ZONE_HTML='<span class="ps-inactive">none</span>'
  GKE_NODE_TYPE_HTML='<span class="ps-inactive">none</span>'
  GKE_CPU_BADGE='<span class="ps-inactive">none</span>'
  GKE_GPU_BADGE='<span class="ps-inactive">none</span>'
  GKE_BUCKET_HTML='<span class="ps-inactive">none</span>'
  GKE_GAR_HTML='<span class="ps-inactive">none</span>'
fi

# Active/inactive badge HTML (link only on active state)
DGX_NEMO_BADGE=$([ "$DGX_NEMO_ACTIVE" = "true" ] && echo '<span class="ps-active">ACTIVE</span>' || echo '<span class="ps-inactive">INACTIVE</span>')
DGX_KFP_BADGE=$([ "$DGX_KFP_ACTIVE" = "true" ] && echo '<a href="http://localhost:8080/#/pipelines" class="ps-active">ACTIVE</a>' || echo '<span class="ps-inactive">INACTIVE</span>')
DGX_OLLAMA_BADGE=$([ "$DGX_OLLAMA_ACTIVE" = "true" ] && echo '<span class="ps-active">ACTIVE</span>' || echo '<span class="ps-inactive">INACTIVE</span>')
DGX_MINIKUBE_BADGE=$([ "$DGX_MINIKUBE_ACTIVE" = "true" ] && echo '<a href="http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/#/overview?namespace=_all" class="ps-active">ACTIVE</a>' || echo '<span class="ps-inactive">INACTIVE</span>')
DGX_MLFLOW_BADGE=$([ "$DGX_MLFLOW_ACTIVE" = "true" ] && echo '<a href="http://localhost:5000" class="ps-active">ACTIVE</a>' || echo '<span class="ps-inactive">INACTIVE</span>')
DGX_QDRANT_BADGE=$([ "$DGX_QDRANT_ACTIVE" = "true" ] && echo '<a href="http://localhost:6333/dashboard" class="ps-active">ACTIVE</a>' || echo '<span class="ps-inactive">INACTIVE</span>')

AGX_NEMO_BADGE=$([ "$AGX_NEMO_ACTIVE" = "true" ] && echo '<span class="ps-active">ACTIVE</span>' || echo '<span class="ps-inactive">INACTIVE</span>')
AGX_KFP_BADGE=$([ "$AGX_KFP_ACTIVE" = "true" ] && echo '<a href="http://localhost:8081/#/pipelines" class="ps-active">ACTIVE</a>' || echo '<span class="ps-inactive">INACTIVE</span>')
AGX_OLLAMA_BADGE=$([ "$AGX_OLLAMA_ACTIVE" = "true" ] && echo '<span class="ps-active">ACTIVE</span>' || echo '<span class="ps-inactive">INACTIVE</span>')
AGX_MINIKUBE_BADGE=$([ "$AGX_MINIKUBE_ACTIVE" = "true" ] && echo '<a href="http://localhost:8002/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/#/overview?namespace=_all" class="ps-active">ACTIVE</a>' || echo '<span class="ps-inactive">INACTIVE</span>')
AGX_MLFLOW_BADGE=$([ "$AGX_MLFLOW_ACTIVE" = "true" ] && echo '<a href="http://localhost:5001" class="ps-active">ACTIVE</a>' || echo '<span class="ps-inactive">INACTIVE</span>')
AGX_QDRANT_BADGE=$([ "$AGX_QDRANT_ACTIVE" = "true" ] && echo '<a href="http://localhost:6335/dashboard" class="ps-active">ACTIVE</a>' || echo '<span class="ps-inactive">INACTIVE</span>')

cat > "$OUTPUT" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Miramar Platform — Projects</title>
<style>
  *, *::before, *::after { box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #0d1117; color: #c9d1d9;
    margin: 0; padding: 2rem;
  }
  h1 { color: #f0f6fc; font-size: 1.5rem; margin-bottom: 0.25rem; }
  .subtitle { color: #8b949e; font-size: 0.875rem; margin-bottom: 2rem; display: flex; justify-content: space-between; align-items: baseline; }
  table { width: 100%; border-collapse: collapse; }
  th {
    text-align: left; padding: 0.6rem 1rem;
    background: #161b22; color: #8b949e;
    font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em;
    border-bottom: 1px solid #21262d;
  }
  td {
    padding: 0.65rem 1rem; border-bottom: 1px solid #21262d;
    font-size: 0.875rem; vertical-align: middle;
  }
  tr:hover td { background: #161b22; }
  a { color: #58a6ff; text-decoration: none; }
  a:hover { text-decoration: underline; }
  .badge {
    display: inline-block; padding: 0.2em 0.55em;
    border-radius: 2em; font-size: 0.75rem; font-weight: 600;
  }
  .badge-kfp          { background: #0c2d6b; color: #79c0ff; }
  .badge-kfp-finetune { background: #0c3340; color: #79d0f0; }
  .badge-kfp-ft-eval  { background: #1a1a4f; color: #a78bfa; }
  .badge-nemo     { background: #1a4731; color: #3fb950; }
  .badge-other    { background: #2d2b00; color: #d29922; }
  .badge-default  { background: #2d2b00; color: #d29922; }
  .badge-dgx      { background: #1a3a2a; color: #76d7a8; }
  .badge-agx      { background: #2a1a3a; color: #c792ea; }
  .jl-link { color: #f0883e; font-size: 0.8rem; white-space: nowrap; }
  .jl-link:hover { color: #ffa657; }
  .count { color: #8b949e; font-weight: normal; font-size: 1rem; }
  .footer { margin-top: 2rem; color: #484f58; font-size: 0.75rem; }
  .machine-section { margin-bottom: 1.25rem; }
  .machine-label {
    font-size: 0.7rem; font-weight: 600; text-transform: uppercase;
    letter-spacing: 0.07em; color: #58a6ff; margin-bottom: 0.4rem;
  }
  .platform-status {
    display: flex; gap: 1.5rem;
    padding: 1rem 1.25rem;
    background: #161b22; border: 1px solid #21262d; border-radius: 6px;
  }
  .ps-item { display: flex; flex-direction: column; gap: 0.2rem; flex: 1 1 0; min-width: 0; }
  .ps-item.ps-wide { flex: 2 1 0; }
  .ps-label { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; color: #8b949e; }
  .ps-value { font-size: 0.875rem; color: #e6edf3; background: transparent; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .ps-none { color: #484f58; }
  .ps-warn { color: #d29922; }
  .ps-link { color: #8b949e; text-decoration: none; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; }
  .ps-link:hover { color: #58a6ff; text-decoration: underline; }
  .ps-active { display: inline-block; padding: 0.2em 0.55em; border-radius: 2em; background: #1a4731; color: #3fb950; font-size: 0.75rem; font-weight: 600; text-decoration: none; }
  a.ps-active:hover { text-decoration: underline; }
  .ps-inactive { display: inline-block; padding: 0.2em 0.55em; border-radius: 2em; background: #3d1212; color: #f85149; font-size: 0.75rem; font-weight: 600; }
  .del-btn { background: none; border: none; cursor: pointer; color: #c0392b; font-size: 1rem; padding: 0.25rem 0.4rem; border-radius: 4px; line-height: 1; }
  .del-btn:hover { color: #f85149; background: #3d1212; }
  .modal-overlay { display: none; position: fixed; inset: 0; background: rgba(0,0,0,0.75); z-index: 100; align-items: center; justify-content: center; }
  .modal-overlay.open { display: flex; }
  .modal { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 1.5rem; width: 420px; max-width: 90vw; }
  .modal h2 { color: #f85149; font-size: 1rem; margin: 0 0 0.75rem; }
  .modal p  { font-size: 0.875rem; color: #8b949e; margin: 0 0 0.75rem; line-height: 1.5; }
  .modal strong { color: #e6edf3; }
  .modal input { width: 100%; padding: 0.5rem 0.75rem; background: #0d1117; border: 1px solid #30363d; border-radius: 6px; color: #c9d1d9; font-size: 0.875rem; margin-bottom: 1rem; outline: none; font-family: monospace; box-sizing: border-box; }
  .modal input:focus { border-color: #58a6ff; }
  .modal-actions { display: flex; gap: 0.5rem; justify-content: flex-end; }
  .btn-cancel { padding: 0.4rem 1rem; border-radius: 6px; background: #21262d; border: 1px solid #30363d; color: #c9d1d9; cursor: pointer; font-size: 0.875rem; }
  .btn-cancel:hover { background: #30363d; }
  .btn-delete { padding: 0.4rem 1rem; border-radius: 6px; background: #b91c1c; border: none; color: #fff; cursor: pointer; font-size: 0.875rem; font-weight: 600; }
  .btn-delete:disabled { background: #3d1212; color: #6e7681; cursor: not-allowed; }
  .btn-delete:not(:disabled):hover { background: #dc2626; }
  .btn-refresh { background: none; border: 1px solid #30363d; border-radius: 6px; color: #8b949e; cursor: pointer; font-size: 0.75rem; padding: 0.2rem 0.6rem; letter-spacing: 0.04em; }
  .btn-refresh:hover { border-color: #58a6ff; color: #58a6ff; }
  .btn-refresh:disabled { color: #484f58; border-color: #21262d; cursor: default; }
  .btn-new-project { background: #238636; border: none; border-radius: 6px; color: #fff; cursor: pointer; font-size: 0.75rem; font-weight: 600; padding: 0.25rem 0.7rem; letter-spacing: 0.04em; }
  .btn-new-project:hover { background: #2ea043; }
  .btn-new-project:disabled { background: #1a4731; color: #6e7681; cursor: not-allowed; }
  .modal-label { display: block; font-size: 0.75rem; color: #8b949e; margin-bottom: 0.3rem; text-transform: uppercase; letter-spacing: 0.04em; }
  #new-proj-modal h2 { color: #3fb950; }
  #new-proj-modal select { width: 100%; padding: 0.5rem 0.75rem; background: #0d1117; border: 1px solid #30363d; border-radius: 6px; color: #c9d1d9; font-size: 0.875rem; margin-bottom: 1rem; outline: none; box-sizing: border-box; }
  #new-proj-modal select:focus { border-color: #58a6ff; }
  .btn-create { padding: 0.4rem 1rem; border-radius: 6px; background: #238636; border: none; color: #fff; cursor: pointer; font-size: 0.875rem; font-weight: 600; }
  .btn-create:disabled { background: #1a4731; color: #6e7681; cursor: not-allowed; }
  .btn-create:not(:disabled):hover { background: #2ea043; }
</style>
</head>
<body>
<h1>Miramar Platform Projects <span class="count">(${REPO_COUNT})</span></h1>
<p class="subtitle"><span>Platform Status and Public repos in <a href="https://github.com/${ORG}">${ORG}</a> tagged <code>miramar-project</code>. (Refreshed hourly)</span><span style="display:flex;gap:0.5rem;align-items:center"><button class="btn-refresh" id="refresh-btn">&#x21BB; Refresh</button><button class="btn-new-project" id="new-proj-btn">+ New Project</button><a href="https://github.com/${ORG}/miramar-platform-gcp" class="machine-label">PLATFORM REPO</a></span></p>
<div class="machine-section">
  <div class="machine-label">DGX Spark</div>
  <div class="platform-status">
    <div class="ps-item">
      <div class="ps-label">NeMo</div>
      ${DGX_NEMO_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">KFP</div>
      ${DGX_KFP_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">Ollama</div>
      ${DGX_OLLAMA_BADGE}
    </div>
    <div class="ps-item ps-wide">
      <div class="ps-label">NIM model</div>
      <code class="${NIM_CLASS}">${NIM_MODEL}</code>
    </div>
    <div class="ps-item ps-wide">
      <div class="ps-label">Ollama model</div>
      <code class="${OLLAMA_CLASS}">${OLLAMA_MODEL}</code>
    </div>
    <div class="ps-item">
      <div class="ps-label">Minikube</div>
      ${DGX_MINIKUBE_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">MLflow</div>
      ${DGX_MLFLOW_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">Qdrant</div>
      ${DGX_QDRANT_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">VRAM Used</div>
      <code class="ps-value">${VRAM_USED_GB} GB</code>
    </div>
    <div class="ps-item">
      <div class="ps-label">VRAM Available</div>
      <code class="${VRAM_AVAIL_CLASS}">${VRAM_AVAIL_GB} GB</code>
    </div>
  </div>
</div>
<div class="machine-section">
  <div class="machine-label">AGX Orin</div>
  <div class="platform-status">
    <div class="ps-item">
      <div class="ps-label">NeMo</div>
      ${AGX_NEMO_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">KFP</div>
      ${AGX_KFP_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">Ollama</div>
      ${AGX_OLLAMA_BADGE}
    </div>
    <div class="ps-item ps-wide">
      <div class="ps-label">NIM model</div>
      <code class="${AGX_NIM_CLASS}">${AGX_NIM_MODEL}</code>
    </div>
    <div class="ps-item ps-wide">
      <div class="ps-label">Ollama model</div>
      <code class="${AGX_OLLAMA_CLASS}">${AGX_OLLAMA_MODEL}</code>
    </div>
    <div class="ps-item">
      <div class="ps-label">Minikube</div>
      ${AGX_MINIKUBE_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">MLflow</div>
      ${AGX_MLFLOW_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">Qdrant</div>
      ${AGX_QDRANT_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">VRAM Used</div>
      <code class="ps-value">${AGX_VRAM_USED_GB} GB</code>
    </div>
    <div class="ps-item">
      <div class="ps-label">VRAM Available</div>
      <code class="${AGX_VRAM_AVAIL_CLASS}">${AGX_VRAM_AVAIL_GB} GB</code>
    </div>
  </div>
</div>
<div class="machine-section">
  <div class="machine-label">GCP</div>
  <div class="platform-status">
    <div class="ps-item ps-wide">
      <div class="ps-label">GKE</div>
      ${GKE_CLUSTER_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">Zone</div>
      ${GKE_ZONE_HTML}
    </div>
    <div class="ps-item">
      <div class="ps-label">Node type</div>
      ${GKE_NODE_TYPE_HTML}
    </div>
    <div class="ps-item">
      <div class="ps-label">CPU pool</div>
      ${GKE_CPU_BADGE}
    </div>
    <div class="ps-item">
      <div class="ps-label">GPU pool</div>
      ${GKE_GPU_BADGE}
    </div>
    <div class="ps-item ps-wide">
      <div class="ps-label">State bucket</div>
      ${GKE_BUCKET_HTML}
    </div>
    <div class="ps-item ps-wide">
      <div class="ps-label">GAR</div>
      ${GKE_GAR_HTML}
    </div>
  </div>
</div>
<table>
<thead>
  <tr>
    <th>Project</th>
    <th>Type</th>
    <th>Description</th>
    <th>Host</th>
    <th>JupyterLab</th>
    <th>SHA</th>
    <th></th>
  </tr>
</thead>
<tbody>
${ROWS}
</tbody>
</table>
<p class="footer">Generated ${GENERATED_AT} &mdash; Service links require active SSH tunnels. JupyterLab: DGX port 8888 / AGX port 8887. MLflow: DGX 5000 / AGX 5001. KFP: DGX 8080 / AGX 8081. Minikube: DGX 8001 / AGX 8002. Qdrant: DGX 6333 / AGX 6335.</p>

<div class="modal-overlay" id="new-proj-modal">
  <div class="modal">
    <h2>+ New Project</h2>
    <p>Create a new Miramar project repository on GitHub and clone it to the target machine.</p>
    <label class="modal-label" for="np-name">Project name *</label>
    <input id="np-name" type="text" autocomplete="off" spellcheck="false" placeholder="my-llm-experiment">
    <label class="modal-label" for="np-type">Project type *</label>
    <select id="np-type">
      <option value="default">default &mdash; generic notebook</option>
      <option value="kfp">kfp &mdash; Kubeflow pipeline stub</option>
      <option value="kfp-finetune">kfp-finetune &mdash; KFP fine-tuning pipeline</option>
      <option value="kfp-ft-eval">kfp-ft-eval &mdash; KFP eval-first fine-tuning pipeline</option>
      <option value="nemo">nemo &mdash; NeMo training job</option>
    </select>
    <label class="modal-label" for="np-host">Host *</label>
    <select id="np-host">
      <option value="dgx">DGX Spark</option>
      <option value="agx">AGX Orin</option>
    </select>
    <label class="modal-label" for="np-desc">Description</label>
    <input id="np-desc" type="text" placeholder="Optional short description">
    <label class="modal-label" for="np-vis">Visibility</label>
    <select id="np-vis">
      <option value="public">public</option>
      <option value="private">private</option>
    </select>
    <div class="modal-actions">
      <button class="btn-cancel" id="np-cancel">Cancel</button>
      <button class="btn-create" id="np-submit" disabled>Create</button>
    </div>
  </div>
</div>

<div class="modal-overlay" id="del-modal">
  <div class="modal">
    <h2>&#x26A0; Delete project</h2>
    <p>This will permanently delete <strong id="del-name"></strong> and clean up its blog draft, local clone, and JupyterLab kernel.</p>
    <p>Type the project name to confirm:</p>
    <input id="del-confirm" type="text" autocomplete="off" spellcheck="false" placeholder="">
    <div class="modal-actions">
      <button class="btn-cancel" id="del-cancel">Cancel</button>
      <button class="btn-delete" id="del-submit" disabled>Delete</button>
    </div>
  </div>
</div>

<script>
(function() {
  var ORG = '${ORG}';
  var PAT = '${DISPATCH_TOKEN}';
  var PLATFORM_REPO = 'miramar-platform-gcp';
  var WORKFLOW = 'delete-project.yaml';
  var pending = null;

  var overlay = document.getElementById('del-modal');
  var nameEl  = document.getElementById('del-name');
  var inp     = document.getElementById('del-confirm');
  var submit  = document.getElementById('del-submit');

  function openModal(repo) {
    pending = repo;
    nameEl.textContent = repo;
    inp.value = '';
    inp.placeholder = repo;
    submit.disabled = true;
    submit.textContent = 'Delete';
    overlay.classList.add('open');
    setTimeout(function() { inp.focus(); }, 50);
  }

  function closeModal() {
    overlay.classList.remove('open');
    pending = null;
    inp.value = '';
  }

  inp.addEventListener('input', function() {
    submit.disabled = inp.value !== pending;
  });

  document.getElementById('del-cancel').addEventListener('click', closeModal);
  overlay.addEventListener('click', function(e) { if (e.target === overlay) closeModal(); });
  document.addEventListener('keydown', function(e) { if (e.key === 'Escape') closeModal(); });

  submit.addEventListener('click', function() {
    var repo = pending;
    submit.disabled = true;
    submit.textContent = 'Deleting…';
    var url = 'https://api.github.com/repos/' + ORG + '/' + PLATFORM_REPO + '/actions/workflows/' + WORKFLOW + '/dispatches';
    fetch(url, {
      method: 'POST',
      headers: {
        'Authorization': 'token ' + PAT,
        'Accept': 'application/vnd.github.v3+json',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ ref: 'main', inputs: { project_name: repo, confirm: repo } })
    }).then(function(resp) {
      if (resp.status === 204) {
        closeModal();
        alert('Delete workflow triggered for "' + repo + '".\nDashboard will refresh when it completes.');
      } else if (resp.status === 401) {
        alert('PAT rejected (401) — check that GITHUB_ORG_ADMIN_PAT has delete_repo + workflow scope and re-deploy the dashboard.');
        submit.disabled = false;
        submit.textContent = 'Delete';
      } else {
        resp.text().then(function(body) {
          alert('Error ' + resp.status + ': ' + body);
          submit.disabled = false;
          submit.textContent = 'Delete';
        });
      }
    }).catch(function(err) {
      alert('Network error: ' + err.message);
      submit.disabled = false;
      submit.textContent = 'Delete';
    });
  });

  document.querySelectorAll('.del-btn').forEach(function(btn) {
    btn.addEventListener('click', function() { openModal(btn.getAttribute('data-repo')); });
  });

  (function() {
    var npOverlay = document.getElementById('new-proj-modal');
    var npName    = document.getElementById('np-name');
    var npSubmit  = document.getElementById('np-submit');
    var SLUG_RE   = /^[a-z0-9][a-z0-9-]*\$/i;

    function npOpen() {
      npName.value = '';
      document.getElementById('np-type').value = 'default';
      document.getElementById('np-host').value = 'dgx';
      document.getElementById('np-desc').value = '';
      document.getElementById('np-vis').value  = 'public';
      npSubmit.disabled = true;
      npSubmit.textContent = 'Create';
      npOverlay.classList.add('open');
      setTimeout(function() { npName.focus(); }, 50);
    }

    function npClose() { npOverlay.classList.remove('open'); }

    npName.addEventListener('input', function() {
      npSubmit.disabled = !SLUG_RE.test(npName.value.trim());
    });

    document.getElementById('np-cancel').addEventListener('click', npClose);
    npOverlay.addEventListener('click', function(e) { if (e.target === npOverlay) npClose(); });
    document.addEventListener('keydown', function(e) { if (e.key === 'Escape') npClose(); });
    document.getElementById('new-proj-btn').addEventListener('click', npOpen);

    npSubmit.addEventListener('click', function() {
      var name = npName.value.trim();
      npSubmit.disabled = true;
      npSubmit.textContent = 'Creating…';
      var url = 'https://api.github.com/repos/' + ORG + '/' + PLATFORM_REPO + '/actions/workflows/create-project.yaml/dispatches';
      fetch(url, {
        method: 'POST',
        headers: {
          'Authorization': 'token ' + PAT,
          'Accept': 'application/vnd.github.v3+json',
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ ref: 'main', inputs: {
          project_name:    name,
          project_type:    document.getElementById('np-type').value,
          host:            document.getElementById('np-host').value,
          description:     document.getElementById('np-desc').value.trim(),
          repo_visibility: document.getElementById('np-vis').value
        }})
      }).then(function(resp) {
        if (resp.status === 204) {
          npClose();
          alert('Create Project workflow triggered for "' + name + '".\nDashboard will refresh when it completes.');
        } else if (resp.status === 401) {
          alert('PAT rejected (401) — check DASHBOARD_DISPATCH_TOKEN has Actions write on miramar-platform-gcp and re-deploy the dashboard.');
          npSubmit.disabled = false;
          npSubmit.textContent = 'Create';
        } else {
          resp.text().then(function(body) {
            alert('Error ' + resp.status + ': ' + body);
            npSubmit.disabled = false;
            npSubmit.textContent = 'Create';
          });
        }
      }).catch(function(err) {
        alert('Network error: ' + err.message);
        npSubmit.disabled = false;
        npSubmit.textContent = 'Create';
      });
    });
  })();

  (function() {
    var refreshBtn = document.getElementById('refresh-btn');
    refreshBtn.addEventListener('click', function() {
      refreshBtn.disabled = true;
      refreshBtn.textContent = 'Triggering…';
      var url = 'https://api.github.com/repos/' + ORG + '/' + PLATFORM_REPO + '/actions/workflows/deploy-dashboard.yaml/dispatches';
      fetch(url, {
        method: 'POST',
        headers: {
          'Authorization': 'token ' + PAT,
          'Accept': 'application/vnd.github.v3+json',
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({ ref: 'main' })
      }).then(function(resp) {
        if (resp.status === 204) {
          refreshBtn.textContent = 'Queued ✓';
          setTimeout(function() { refreshBtn.disabled = false; refreshBtn.textContent = '↻ Refresh'; }, 5000);
        } else {
          resp.text().then(function(body) { alert('Error ' + resp.status + ': ' + body); });
          refreshBtn.disabled = false;
          refreshBtn.textContent = '↻ Refresh';
        }
      }).catch(function(err) {
        alert('Network error: ' + err.message);
        refreshBtn.disabled = false;
        refreshBtn.textContent = '↻ Refresh';
      });
    });
  })();
})();
</script>

</body>
</html>
HTMLEOF

echo "==> Dashboard written to ${OUTPUT} (${REPO_COUNT} projects)"
