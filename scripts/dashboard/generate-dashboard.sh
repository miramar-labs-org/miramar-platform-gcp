#!/usr/bin/env bash
# Generate a self-contained dashboard.html listing all public Miramar platform repos.
# Usage: GH_TOKEN=<token> [GH_ADMIN_TOKEN=<token>] bash generate-dashboard.sh --org <org> --output <path>
#
# GH_TOKEN      — GITHUB_TOKEN; used for org repo listing (read:public_repo)
# GH_ADMIN_TOKEN — GITHUB_ORG_ADMIN_PAT; used for per-project workflow run queries
#                  (falls back to GH_TOKEN if not set, but won't work for private runner data)
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
  type=$(echo    "$repo_json" | jq -r '.topics | if index("miramar-kfp") then "kfp" elif index("miramar-nemo") then "nemo" elif index("miramar-default") then "default" else "other" end')
  desc=$(echo    "$repo_json" | jq -r '.description // ""')
  sha=$(GH_TOKEN="$GH_TOKEN" gh api \
    "repos/${ORG}/${name}/commits?per_page=1" 2>/dev/null \
    | jq -r 'if type == "array" then (.[0].sha // "")[:7] else "" end' 2>/dev/null || echo "")

  # --- Deploy status: compare latest successful deploy vs undeploy run ---
  deploy_ts=$(GH_TOKEN="$ADMIN_TOKEN" gh api \
    "repos/${ORG}/${name}/actions/workflows/deploy-${type}.yaml/runs?status=success&per_page=1" \
    --jq '.workflow_runs[0].updated_at // empty' 2>/dev/null || true)
  undeploy_ts=$(GH_TOKEN="$ADMIN_TOKEN" gh api \
    "repos/${ORG}/${name}/actions/workflows/undeploy-${type}.yaml/runs?status=success&per_page=1" \
    --jq '.workflow_runs[0].updated_at // empty' 2>/dev/null || true)

  if [[ -n "$deploy_ts" ]] && { [[ -z "$undeploy_ts" ]] || [[ "$deploy_ts" > "$undeploy_ts" ]]; }; then
    status_html="<span class=\"badge badge-deployed\">deployed</span>"
  else
    status_html="<span class=\"badge badge-idle\">idle</span>"
  fi

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
  <td>${status_html}</td>
  <td>${host_html}</td>
  <td>${jl_html}</td>
  <td><code>${sha}</code></td>
</tr>
"
done < <(echo "$REPOS_JSON" | jq -c 'sort_by(.created_at) | reverse | .[]')

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
NEMO_VERSION=$(read_platform_var "NEMO_VERSION")
KFP_VERSION=$(read_platform_var "KFP_VERSION")
OLLAMA_VERSION=$(read_platform_var "OLLAMA_VERSION")
NIM_MODEL=$(read_platform_var "CURRENT_NIM_MODEL")
OLLAMA_MODEL=$(read_platform_var "CURRENT_OLLAMA_MODEL")
NIM_VRAM_GB=$(read_platform_var "CURRENT_NIM_VRAM_GB")
OLLAMA_VRAM_GB=$(read_platform_var "CURRENT_OLLAMA_VRAM_GB")
DGX_MINIKUBE_VERSION=$(read_platform_var "DGX_MINIKUBE_VERSION")
MLFLOW_VERSION=$(read_platform_var "MLFLOW_VERSION")
DGX_VRAM_USEABLE=$(read_org_var "DGX_VRAM_USEABLE")

AGX_OLLAMA_MODEL=$(read_platform_var "CURRENT_OLLAMA_MODEL_AGX")
AGX_OLLAMA_VRAM_GB=$(read_platform_var "CURRENT_OLLAMA_VRAM_GB_AGX")
AGX_NIM_MODEL=$(read_platform_var "CURRENT_NIM_MODEL_AGX")
AGX_NIM_VRAM_GB=$(read_platform_var "CURRENT_NIM_VRAM_GB_AGX")
AGX_MINIKUBE_VERSION=$(read_platform_var "AGX_MINIKUBE_VERSION")
MLFLOW_VERSION_AGX=$(read_platform_var "MLFLOW_VERSION_AGX")
AGX_VRAM_USEABLE=$(read_org_var "AGX_VRAM_USEABLE")

GCP_PROJECT_ID=$(read_org_var "GCP_PROJECT_ID")
GCP_REGION=$(read_org_var "GCP_REGION")
GAR_REPO=$(read_org_var "GAR_REPO")
GKE_CLUSTER_NAME=$(read_org_var "GKE_CLUSTER_NAME")

[[ -z "$NEMO_VERSION" ]]   && NEMO_VERSION="—"
[[ -z "$KFP_VERSION" ]]    && KFP_VERSION="—"
[[ -z "$OLLAMA_VERSION" ]] && OLLAMA_VERSION="—"
[[ -z "$NIM_MODEL" ]]      && NIM_MODEL="none"
[[ -z "$OLLAMA_MODEL" ]]   && OLLAMA_MODEL="none"
[[ -z "$NIM_VRAM_GB" || "$NIM_VRAM_GB" == "null" ]]       && NIM_VRAM_GB="0"
[[ -z "$OLLAMA_VRAM_GB" || "$OLLAMA_VRAM_GB" == "null" ]] && OLLAMA_VRAM_GB="0"
[[ -z "$DGX_MINIKUBE_VERSION" ]] && DGX_MINIKUBE_VERSION="—"
[[ -z "$MLFLOW_VERSION" ]]       && MLFLOW_VERSION="—"
[[ -z "$DGX_VRAM_USEABLE" || "$DGX_VRAM_USEABLE" == "null" ]] && DGX_VRAM_USEABLE="100"
[[ -z "$AGX_OLLAMA_MODEL" ]]   && AGX_OLLAMA_MODEL="none"
[[ -z "$AGX_OLLAMA_VRAM_GB" || "$AGX_OLLAMA_VRAM_GB" == "null" ]] && AGX_OLLAMA_VRAM_GB="0"
[[ -z "$AGX_VRAM_USEABLE" || "$AGX_VRAM_USEABLE" == "null" ]] && AGX_VRAM_USEABLE="40"
[[ -z "$AGX_NIM_MODEL" ]]      && AGX_NIM_MODEL="none"
[[ -z "$AGX_NIM_VRAM_GB" || "$AGX_NIM_VRAM_GB" == "null" ]] && AGX_NIM_VRAM_GB="0"
[[ -z "$AGX_MINIKUBE_VERSION" ]] && AGX_MINIKUBE_VERSION="—"
[[ -z "$MLFLOW_VERSION_AGX" ]]   && MLFLOW_VERSION_AGX="—"
[[ -z "$GCP_PROJECT_ID" ]]   && GCP_PROJECT_ID="miramar-platform"
[[ -z "$GCP_REGION" ]]       && GCP_REGION="us-central1"
[[ -z "$GAR_REPO" ]]         && GAR_REPO="apps"
[[ -z "$GKE_CLUSTER_NAME" ]] && GKE_CLUSTER_NAME="miramar-shared-gke"

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

DGX_MINIKUBE_CLASS="ps-value"; [[ "$DGX_MINIKUBE_VERSION" == "—" ]] && DGX_MINIKUBE_CLASS="ps-value ps-none"
AGX_MINIKUBE_CLASS="ps-value"; [[ "$AGX_MINIKUBE_VERSION" == "—" ]] && AGX_MINIKUBE_CLASS="ps-value ps-none"
MLFLOW_CLASS="ps-value";     [[ "$MLFLOW_VERSION"     == "—" ]] && MLFLOW_CLASS="ps-value ps-none"
MLFLOW_AGX_CLASS="ps-value"; [[ "$MLFLOW_VERSION_AGX" == "—" ]] && MLFLOW_AGX_CLASS="ps-value ps-none"
GAR_URL="https://console.cloud.google.com/artifacts/docker/${GCP_PROJECT_ID}/${GCP_REGION}/${GAR_REPO}"

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
  .subtitle { color: #8b949e; font-size: 0.875rem; margin-bottom: 2rem; }
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
  .badge-kfp      { background: #1a4731; color: #3fb950; }
  .badge-nemo     { background: #0c2d6b; color: #79c0ff; }
  .badge-other    { background: #2d2b00; color: #d29922; }
  .badge-default  { background: #2d2b00; color: #d29922; }
  .badge-deployed { background: #1a4731; color: #3fb950; }
  .badge-idle     { background: #21262d; color: #8b949e; }
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
    display: flex; flex-wrap: wrap; gap: 1.5rem;
    padding: 1rem 1.25rem;
    background: #161b22; border: 1px solid #21262d; border-radius: 6px;
  }
  .ps-item { display: flex; flex-direction: column; gap: 0.2rem; min-width: 90px; }
  .ps-item.ps-wide { min-width: 220px; }
  .ps-label { font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; color: #8b949e; }
  .ps-value { font-size: 0.875rem; color: #e6edf3; background: transparent; }
  .ps-none { color: #484f58; }
  .ps-warn { color: #d29922; }
  .ps-link { color: #8b949e; text-decoration: none; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; }
  .ps-link:hover { color: #58a6ff; text-decoration: underline; }
</style>
</head>
<body>
<h1>Miramar Platform Projects <span class="count">(${REPO_COUNT})</span></h1>
<p class="subtitle">Public repos in <a href="https://github.com/${ORG}">${ORG}</a> tagged <code>miramar-project</code>. Refreshed hourly. &mdash; <a href="https://github.com/${ORG}/miramar-platform-gcp">Platform repo</a></p>
<div class="machine-section">
  <div class="machine-label">DGX Spark</div>
  <div class="platform-status">
    <div class="ps-item">
      <div class="ps-label">NeMo</div>
      <code class="ps-value">${NEMO_VERSION}</code>
    </div>
    <div class="ps-item">
      <div class="ps-label">KFP</div>
      <code class="ps-value">${KFP_VERSION}</code>
    </div>
    <div class="ps-item">
      <div class="ps-label">Ollama</div>
      <code class="ps-value">${OLLAMA_VERSION}</code>
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
      <div class="ps-label"><a href="http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/" class="ps-link">Minikube</a></div>
      <code class="${DGX_MINIKUBE_CLASS}">${DGX_MINIKUBE_VERSION}</code>
    </div>
    <div class="ps-item">
      <div class="ps-label"><a href="http://localhost:5000" class="ps-link">MLflow</a></div>
      <code class="${MLFLOW_CLASS}">${MLFLOW_VERSION}</code>
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
      <code class="ps-value">${NEMO_VERSION}</code>
    </div>
    <div class="ps-item">
      <div class="ps-label">KFP</div>
      <code class="ps-value">${KFP_VERSION}</code>
    </div>
    <div class="ps-item">
      <div class="ps-label">Ollama</div>
      <code class="ps-value">${OLLAMA_VERSION}</code>
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
      <div class="ps-label"><a href="http://localhost:8002/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/" class="ps-link">Minikube</a></div>
      <code class="${AGX_MINIKUBE_CLASS}">${AGX_MINIKUBE_VERSION}</code>
    </div>
    <div class="ps-item">
      <div class="ps-label"><a href="http://localhost:5001" class="ps-link">MLflow</a></div>
      <code class="${MLFLOW_AGX_CLASS}">${MLFLOW_VERSION_AGX}</code>
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
      <div class="ps-label"><a href="https://console.cloud.google.com/kubernetes/list/overview?project=${GCP_PROJECT_ID}" target="_blank" class="ps-link">GKE</a></div>
      <code class="ps-value">${GKE_CLUSTER_NAME}</code>
    </div>
    <div class="ps-item ps-wide">
      <div class="ps-label"><a href="${GAR_URL}" target="_blank" class="ps-link">GAR</a></div>
      <code class="ps-value">${GCP_PROJECT_ID}/${GCP_REGION}/${GAR_REPO}</code>
    </div>
  </div>
</div>
<table>
<thead>
  <tr>
    <th>Project</th>
    <th>Type</th>
    <th>Description</th>
    <th>Status</th>
    <th>Host</th>
    <th>JupyterLab</th>
    <th>SHA</th>
  </tr>
</thead>
<tbody>
${ROWS}
</tbody>
</table>
<p class="footer">Generated ${GENERATED_AT} &mdash; Service links require active SSH tunnels. JupyterLab: DGX port 8888 / AGX port 8887. MLflow: DGX 5000 / AGX 5001. KFP: DGX 8080 / AGX 8081. Minikube: DGX 8001 / AGX 8002.</p>
</body>
</html>
HTMLEOF

echo "==> Dashboard written to ${OUTPUT} (${REPO_COUNT} projects)"
