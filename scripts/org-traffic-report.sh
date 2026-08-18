#!/usr/bin/env bash
set -euo pipefail

ORG="miramar-labs-org"
DRY_RUN="${DRY_RUN:-false}"
TODAY="${TODAY:-$(date -u +%F)}"

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

  # GitHub's Traffic API has an unpredictable multi-day processing lag, so
  # "yesterday" is often absent from the response. Use the most recent entry
  # actually present instead of searching for a fixed date — but prefer the
  # last COMPLETE day over today's still-accumulating (often zero) entry,
  # falling back to today only if it's the only entry available.
  local latest_date
  latest_date=$(echo "$views_json" | jq -r --arg today "$TODAY" '
    (.views // []) | sort_by(.timestamp) as $sorted
    | ($sorted | map(select(.timestamp[0:10] != $today))) as $complete
    | (if ($complete | length) > 0 then $complete else $sorted end)
    | last | .timestamp[0:10] // empty
  ')
  if [ -z "$latest_date" ]; then
    warn "skipping ${repo}: no traffic/views data available"
    return 0
  fi

  local views unique_visitors clones unique_cloners
  views=$(echo "$views_json" | jq --arg d "$latest_date" \
    '[.views[]? | select(.timestamp | startswith($d))][0].count // 0')
  unique_visitors=$(echo "$views_json" | jq --arg d "$latest_date" \
    '[.views[]? | select(.timestamp | startswith($d))][0].uniques // 0')
  clones=$(echo "$clones_json" | jq --arg d "$latest_date" \
    '[.clones[]? | select(.timestamp | startswith($d))][0].count // 0')
  unique_cloners=$(echo "$clones_json" | jq --arg d "$latest_date" \
    '[.clones[]? | select(.timestamp | startswith($d))][0].uniques // 0')

  printf "%s\t('%s','%s','%s',%s,%s,%s,%s)" \
    "$latest_date" "$latest_date" "$repo" "$visibility" "$views" "$unique_visitors" "$clones" "$unique_cloners"
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
  local totals_csv="$1" top10_csv="$2" report_date="$3"
  local t_views t_uniq t_clones t_cloners
  IFS=',' read -r t_views t_uniq t_clones t_cloners <<<"$totals_csv"

  local top10_lines=""
  if [ -n "$top10_csv" ]; then
    top10_lines=$(echo "$top10_csv" | awk -F, '{printf "%d. *%s* — %s unique visitors\n", NR, $1, $2}')
  fi

  jq -n \
    --arg date "$report_date" \
    --arg totals "Views: *${t_views:-0}* · Unique visitors: *${t_uniq:-0}* · Clones: *${t_clones:-0}* · Unique cloners: *${t_cloners:-0}*" \
    --arg top10 "$top10_lines" \
    '{text: (":bar_chart: *Org Repo Traffic — " + $date + "*\n" + $totals + "\n\n*Top 10 by unique visitors:*\n" + $top10)}'
}

main() {
  local rows="" dates="" line date_part row_part repo private

  while IFS=$'\t' read -r repo private; do
    line=$(fetch_repo_row "$repo" "$private") || true
    if [ -n "$line" ]; then
      IFS=$'\t' read -r date_part row_part <<<"$line"
      rows="${rows}${rows:+$'\n'}${row_part}"
      dates="${dates}${dates:+$'\n'}${date_part}"
    fi
  done < <(discover_repos)

  if [ -z "$rows" ]; then
    warn "no traffic rows collected; nothing to upsert"
    return 0
  fi

  # Repos can lag by different amounts; report on whichever date most repos
  # actually have data for.
  local effective_date
  effective_date=$(echo "$dates" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')

  local sql
  sql=$(build_upsert_sql "$rows")

  if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN — would run this SQL:"
    echo "$sql"
  else
    echo "$sql" | psql "$ORG_TRAFFIC_DATABASE_URL" -v ON_ERROR_STOP=1
  fi

  local totals_query="SELECT COALESCE(SUM(views),0)||','||COALESCE(SUM(unique_visitors),0)||','||COALESCE(SUM(clones),0)||','||COALESCE(SUM(unique_cloners),0) FROM repo_traffic_daily WHERE date = '${effective_date}';"
  local top10_query="SELECT repo||','||unique_visitors FROM repo_traffic_daily WHERE date = '${effective_date}' ORDER BY unique_visitors DESC LIMIT 10;"

  local totals top10
  if [ "$DRY_RUN" = "true" ]; then
    totals="0,0,0,0"
    top10=""
  else
    totals=$(psql "$ORG_TRAFFIC_DATABASE_URL" -t -A -c "$totals_query")
    top10=$(psql "$ORG_TRAFFIC_DATABASE_URL" -t -A -c "$top10_query")
  fi

  local payload
  payload=$(build_slack_payload "$totals" "$top10" "$effective_date")

  if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN — would post this Slack payload:"
    echo "$payload"
  else
    curl -sf -X POST -H 'Content-Type: application/json' -d "$payload" "$SLACK_WEBHOOK_URL" >/dev/null
  fi

  {
    echo "## Org Traffic Report — ${effective_date}"
    echo "Rows upserted: $(echo "$rows" | wc -l)"
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
