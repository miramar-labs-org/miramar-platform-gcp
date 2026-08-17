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

build_upsert_sql() {
  local rows="$1"
  [ -z "$rows" ] && return 0
  cat <<'SQL'
CREATE TABLE IF NOT EXISTS repo_traffic_daily (
  date             DATE NOT NULL,
  repo             TEXT NOT NULL,
  visibility       TEXT NOT NULL,
  views            INT NOT NULL,
  unique_visitors  INT NOT NULL,
  clones           INT NOT NULL,
  unique_cloners   INT NOT NULL,
  PRIMARY KEY (date, repo)
);
SQL
  echo "INSERT INTO repo_traffic_daily (date, repo, visibility, views, unique_visitors, clones, unique_cloners) VALUES"
  echo "$rows" | paste -sd, -
  cat <<'SQL'
ON CONFLICT (date, repo) DO UPDATE SET
  visibility = EXCLUDED.visibility,
  views = EXCLUDED.views,
  unique_visitors = EXCLUDED.unique_visitors,
  clones = EXCLUDED.clones,
  unique_cloners = EXCLUDED.unique_cloners;
SQL
}

build_slack_payload() {
  local totals_csv="$1" top5_csv="$2"
  local t_views t_uniq t_clones t_cloners
  IFS=',' read -r t_views t_uniq t_clones t_cloners <<<"$totals_csv"

  local top5_lines=""
  if [ -n "$top5_csv" ]; then
    top5_lines=$(echo "$top5_csv" | awk -F, '{printf "%d. *%s* — %s unique visitors\n", NR, $1, $2}')
  fi

  jq -n \
    --arg date "$REPORT_DATE" \
    --arg totals "Views: *${t_views:-0}* · Unique visitors: *${t_uniq:-0}* · Clones: *${t_clones:-0}* · Unique cloners: *${t_cloners:-0}*" \
    --arg top5 "$top5_lines" \
    '{text: (":bar_chart: *Org Repo Traffic — " + $date + "*\n" + $totals + "\n\n*Top 5 by unique visitors:*\n" + $top5)}'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  : # main() added in Task 4
fi
