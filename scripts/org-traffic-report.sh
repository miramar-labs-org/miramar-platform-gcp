#!/usr/bin/env bash
set -euo pipefail

ORG="miramar-labs-org"
REPORT_DATE="${REPORT_DATE:-$(date -u -d yesterday +%F)}"
DRY_RUN="${DRY_RUN:-false}"

log() { echo "[org-traffic-report] $*" >&2; }
warn() { echo "[org-traffic-report] WARN: $*" >&2; }

discover_repos() {
  gh api "orgs/${ORG}/repos" --paginate | jq -r \
    '.[] | select(.archived == false) | "\(.name)\t\(.private)"'
}

fetch_repo_row() {
  local repo="$1" private="$2"
  local visibility views_json clones_json
  visibility=$([ "$private" = "true" ] && echo "private" || echo "public")

  if ! views_json=$(gh api "repos/${ORG}/${repo}/traffic/views" 2>/dev/null); then
    warn "skipping ${repo}: traffic/views not accessible"
    return 0
  fi
  if ! clones_json=$(gh api "repos/${ORG}/${repo}/traffic/clones" 2>/dev/null); then
    warn "skipping ${repo}: traffic/clones not accessible"
    return 0
  fi

  local views unique_visitors clones unique_cloners
  views=$(echo "$views_json" | jq --arg d "$REPORT_DATE" \
    '[.views[]? | select(.timestamp | startswith($d))][0].count // 0')
  unique_visitors=$(echo "$views_json" | jq --arg d "$REPORT_DATE" \
    '[.views[]? | select(.timestamp | startswith($d))][0].uniques // 0')
  clones=$(echo "$clones_json" | jq --arg d "$REPORT_DATE" \
    '[.clones[]? | select(.timestamp | startswith($d))][0].count // 0')
  unique_cloners=$(echo "$clones_json" | jq --arg d "$REPORT_DATE" \
    '[.clones[]? | select(.timestamp | startswith($d))][0].uniques // 0')

  printf "('%s','%s','%s',%s,%s,%s,%s)" \
    "$REPORT_DATE" "$repo" "$visibility" "$views" "$unique_visitors" "$clones" "$unique_cloners"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  : # main() added in Task 4
fi
