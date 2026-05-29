#!/usr/bin/env bash
# Generate a self-contained dashboard.html listing all public Miramar platform repos.
# Usage: GH_TOKEN=<token> bash generate-dashboard.sh --org <org> --output <path>
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

mkdir -p "$(dirname "$OUTPUT")"

echo "==> Fetching public repos for ${ORG} ..."
REPOS_JSON=$(GH_TOKEN="$GH_TOKEN" gh api --paginate \
  "orgs/${ORG}/repos?type=public&per_page=100" \
  --jq '[.[] | select(.topics != null and (.topics | index("miramar-project") != null))]')

REPO_COUNT=$(echo "$REPOS_JSON" | jq 'length')
echo "    Found ${REPO_COUNT} repos tagged miramar-project"

# Build HTML rows from JSON
ROWS=$(echo "$REPOS_JSON" | jq -r '
  sort_by(.created_at) | reverse | .[] |
  . as $r |
  ($r.topics // [] | if index("miramar-kfp") then "kfp" elif index("miramar-nemo") then "nemo" else "other" end) as $type |
  ($r.created_at | split("T")[0]) as $created |
  ($r.pushed_at  | split("T")[0]) as $pushed |
  ($r.description // "") as $desc |
  "<tr>",
  "  <td><a href=\"\($r.html_url)\" target=\"_blank\">\($r.name)</a></td>",
  "  <td><span class=\"badge badge-\($type)\">\($type)</span></td>",
  "  <td>\($desc)</td>",
  "  <td>\($created)</td>",
  "  <td>\($pushed)</td>",
  "</tr>"
')

GENERATED_AT=$(date -u '+%Y-%m-%d %H:%M UTC')

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
  .badge-kfp   { background: #1a4731; color: #3fb950; }
  .badge-nemo  { background: #0c2d6b; color: #79c0ff; }
  .badge-other { background: #2d2b00; color: #d29922; }
  .count { color: #8b949e; font-weight: normal; font-size: 1rem; }
  .footer { margin-top: 2rem; color: #484f58; font-size: 0.75rem; }
</style>
</head>
<body>
<h1>Miramar Platform Projects <span class="count">(${REPO_COUNT})</span></h1>
<p class="subtitle">Public repos in <a href="https://github.com/${ORG}">${ORG}</a> tagged <code>miramar-project</code>. Refreshed hourly.</p>
<table>
<thead>
  <tr>
    <th>Project</th>
    <th>Type</th>
    <th>Description</th>
    <th>Created</th>
    <th>Last push</th>
  </tr>
</thead>
<tbody>
${ROWS}
</tbody>
</table>
<p class="footer">Generated ${GENERATED_AT}</p>
</body>
</html>
HTMLEOF

echo "==> Dashboard written to ${OUTPUT} (${REPO_COUNT} projects)"
