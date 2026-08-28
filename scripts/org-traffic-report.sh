#!/usr/bin/env bash
set -euo pipefail

ORG="miramar-labs-org"
DRY_RUN="${DRY_RUN:-false}"
TODAY="${TODAY:-$(date -u +%F)}"

log() { echo "[org-traffic-report] $*" >&2; }
warn() { echo "[org-traffic-report] WARN: $*" >&2; }

discover_repos() {
  # Public repos only — private-repo traffic is intentionally never collected.
  gh api "orgs/${ORG}/repos" --paginate | jq -r \
    '.[] | select(.archived == false and .private == false) | "\(.name)\t\(.private)"'
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

# --- Stars / forks / watchers -----------------------------------------------
# Point-in-time repo metadata (no processing lag), snapshotted under TODAY so a
# day-over-day delta can be computed from repo_stats_daily.
# NOTE: GitHub's `watchers_count` is a legacy alias for `stargazers_count`; the
# real "watching" count is `subscribers_count`.
fetch_repo_stats() {
  local repo="$1" json stars forks watchers
  if ! json=$(gh api "repos/${ORG}/${repo}" 2>/dev/null); then
    warn "skipping ${repo}: repo metadata not accessible"
    return 0
  fi
  stars=$(echo "$json" | jq '.stargazers_count // 0')
  forks=$(echo "$json" | jq '.forks_count // 0')
  watchers=$(echo "$json" | jq '.subscribers_count // 0')
  printf "('%s','%s',%s,%s,%s)" "$TODAY" "$repo" "$stars" "$forks" "$watchers"
}

build_stats_upsert_sql() {
  local rows="$1"
  [ -z "$rows" ] && return 0
  cat <<'SQL'
CREATE TABLE IF NOT EXISTS repo_stats_daily (
  date      DATE NOT NULL,
  repo      TEXT NOT NULL,
  stars     INT NOT NULL,
  forks     INT NOT NULL,
  watchers  INT NOT NULL,
  PRIMARY KEY (date, repo)
);
SQL
  echo "INSERT INTO repo_stats_daily (date, repo, stars, forks, watchers) VALUES"
  echo "$rows" | paste -sd, -
  cat <<'SQL'
ON CONFLICT (date, repo) DO UPDATE SET
  stars = EXCLUDED.stars,
  forks = EXCLUDED.forks,
  watchers = EXCLUDED.watchers;
SQL
}

format_delta() {
  # $1 label, $2 current value, $3 previous value ("" when unknown)
  local label="$1" cur="$2" prev="${3:-}" d sign
  if [ -z "$prev" ]; then
    printf '%s: *%s*' "$label" "$cur"
    return
  fi
  d=$((cur - prev))
  if [ "$d" -gt 0 ]; then sign="+$d"
  elif [ "$d" -lt 0 ]; then sign="$d"
  else sign="—"; fi
  printf '%s: *%s* (%s)' "$label" "$cur" "$sign"
}

# --- Referrers -------------------------------------------------------------
# GitHub's popular/referrers endpoint is a trailing-14-day aggregate (NOT
# per-day), so this section carries different time semantics from views/clones.
fetch_referrers() {
  local repo="$1" json
  json=$(gh api "repos/${ORG}/${repo}/traffic/popular/referrers" 2>/dev/null) || return 0
  echo "$json" | jq -r '.[]? | "\(.referrer)\t\(.count)\t\(.uniques)"'
}

aggregate_referrers() {
  # stdin: "referrer\tcount\tuniques" lines from every repo
  # stdout: top 5 "referrer,count,uniques" summed across repos, by count desc
  awk -F'\t' '
    { count[$1] += $2; uniq[$1] += $3 }
    END { for (r in count) printf "%s,%d,%d\n", r, count[r], uniq[r] }
  ' | sort -t, -k2,2 -rn | head -5
}

build_slack_payload() {
  local totals_csv="$1" rankings_csv="$2" report_date="$3" stats_line="${4:-}" referrers_csv="${5:-}"
  local t_views t_uniq t_clones t_cloners
  IFS=',' read -r t_views t_uniq t_clones t_cloners <<<"$totals_csv"

  local ranking_lines=""
  if [ -n "$rankings_csv" ]; then
    ranking_lines=$(echo "$rankings_csv" | awk -F, '{printf "%d. *%s* — %s\n", NR, $1, $2}')
  fi

  local referrer_lines=""
  if [ -n "$referrers_csv" ]; then
    referrer_lines=$(echo "$referrers_csv" | awk -F, '{printf "%d. %s — %s views (%s unique)\n", NR, $1, $2, $3}')
  fi

  {
    printf ':bar_chart: *Org Repo Traffic — %s*\n\n' "$report_date"
    printf '*Interest*\n'
    printf 'Unique visitors (that day): *%s*  ·  Views: *%s*\n' "${t_uniq:-0}" "${t_views:-0}"
    [ -n "$stats_line" ] && printf '%s\n' "$stats_line"
    printf '\n*Public repos by unique visitors (that day):*\n%s\n' "$ranking_lines"
    if [ -n "$referrer_lines" ]; then
      printf '\n*Top referrers (GitHub 14-day rolling window):*\n%s\n' "$referrer_lines"
    fi
    printf '\n_Clones that day: %s · %s unique cloners — mostly CI/dev, not external interest_\n' \
      "${t_clones:-0}" "${t_cloners:-0}"
  } | jq -Rs '{text: .}'
}

main() {
  local rows="" dates="" stats_rows="" all_referrers=""
  local line date_part row_part repo private strow ref

  while IFS=$'\t' read -r repo private; do
    line=$(fetch_repo_row "$repo" "$private") || true
    if [ -n "$line" ]; then
      IFS=$'\t' read -r date_part row_part <<<"$line"
      rows="${rows}${rows:+$'\n'}${row_part}"
      dates="${dates}${dates:+$'\n'}${date_part}"
    fi

    strow=$(fetch_repo_stats "$repo") || true
    [ -n "$strow" ] && stats_rows="${stats_rows}${stats_rows:+$'\n'}${strow}"

    ref=$(fetch_referrers "$repo") || true
    [ -n "$ref" ] && all_referrers="${all_referrers}${all_referrers:+$'\n'}${ref}"
  done < <(discover_repos)

  if [ -z "$rows" ]; then
    warn "no traffic rows collected; nothing to upsert"
    return 0
  fi

  # Repos can lag by different amounts; report on whichever date most repos
  # actually have data for.
  local effective_date
  effective_date=$(echo "$dates" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')

  local sql stats_sql
  sql=$(build_upsert_sql "$rows")
  stats_sql=$(build_stats_upsert_sql "$stats_rows")

  if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN — would run traffic SQL:"
    echo "$sql"
    log "DRY RUN — would run stats SQL:"
    echo "$stats_sql"
  else
    echo "$sql" | psql "$ORG_TRAFFIC_DATABASE_URL" -v ON_ERROR_STOP=1
    [ -n "$stats_sql" ] && echo "$stats_sql" | psql "$ORG_TRAFFIC_DATABASE_URL" -v ON_ERROR_STOP=1
  fi

  # visibility filter guards against historical private rows predating the
  # public-only change; going forward discover_repos only yields public repos.
  local totals_query="SELECT COALESCE(SUM(views),0)||','||COALESCE(SUM(unique_visitors),0)||','||COALESCE(SUM(clones),0)||','||COALESCE(SUM(unique_cloners),0) FROM repo_traffic_daily WHERE date = '${effective_date}' AND visibility = 'public';"
  local rankings_query="SELECT repo||','||unique_visitors FROM repo_traffic_daily WHERE date = '${effective_date}' AND visibility = 'public' ORDER BY unique_visitors DESC, repo;"

  # Day-over-day stars/forks/watchers. The previous-day query uses HAVING so it
  # returns zero rows (empty string) on the very first run instead of a 0,0,0
  # row that would make every count look like a same-day gain.
  local cur_stats_query="SELECT COALESCE(SUM(stars),0)||','||COALESCE(SUM(forks),0)||','||COALESCE(SUM(watchers),0) FROM repo_stats_daily WHERE date = (SELECT MAX(date) FROM repo_stats_daily);"
  local prev_stats_query="SELECT COALESCE(SUM(stars),0)||','||COALESCE(SUM(forks),0)||','||COALESCE(SUM(watchers),0) FROM repo_stats_daily WHERE date = (SELECT MAX(date) FROM repo_stats_daily WHERE date < (SELECT MAX(date) FROM repo_stats_daily)) HAVING COUNT(*) > 0;"
  local star_gainers_query="WITH latest AS (SELECT MAX(date) AS d FROM repo_stats_daily), prev AS (SELECT MAX(date) AS d FROM repo_stats_daily WHERE date < (SELECT d FROM latest)) SELECT string_agg('*'||c.repo||'* +'||(c.stars - p.stars), ', ' ORDER BY (c.stars - p.stars) DESC) FROM repo_stats_daily c JOIN repo_stats_daily p ON p.repo = c.repo AND p.date = (SELECT d FROM prev) WHERE c.date = (SELECT d FROM latest) AND c.stars > p.stars;"

  local totals rankings cur_stats prev_stats star_gainers
  if [ "$DRY_RUN" = "true" ]; then
    # Representative values so the dry-run Slack preview shows the full shape.
    totals="12,7,43,15"
    rankings=$'repo-a,4\nrepo-b,2'
    cur_stats="41,8,5"
    prev_stats="39,7,5"
    star_gainers='*repo-a* +2'
  else
    totals=$(psql "$ORG_TRAFFIC_DATABASE_URL" -t -A -c "$totals_query")
    rankings=$(psql "$ORG_TRAFFIC_DATABASE_URL" -t -A -c "$rankings_query")
    cur_stats=$(psql "$ORG_TRAFFIC_DATABASE_URL" -t -A -c "$cur_stats_query")
    prev_stats=$(psql "$ORG_TRAFFIC_DATABASE_URL" -t -A -c "$prev_stats_query")
    star_gainers=$(psql "$ORG_TRAFFIC_DATABASE_URL" -t -A -c "$star_gainers_query")
  fi

  local stats_line="" top_referrers=""
  if [ -n "$cur_stats" ]; then
    local cs cf cw ps pf pw
    IFS=',' read -r cs cf cw <<<"$cur_stats"
    IFS=',' read -r ps pf pw <<<"${prev_stats:-}"
    stats_line="$(format_delta Stars "$cs" "$ps")   $(format_delta Forks "$cf" "$pf")   $(format_delta Watchers "$cw" "$pw")"
    [ -n "$star_gainers" ] && stats_line="${stats_line}"$'\n'":star: New stars: ${star_gainers}"
  fi
  [ -n "$all_referrers" ] && top_referrers=$(echo "$all_referrers" | aggregate_referrers)

  local payload
  payload=$(build_slack_payload "$totals" "$rankings" "$effective_date" "$stats_line" "$top_referrers")

  if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN — would post this Slack payload:"
    echo "$payload"
  else
    curl -sf -X POST -H 'Content-Type: application/json' -d "$payload" "$SLACK_WEBHOOK_URL" >/dev/null
  fi

  {
    echo "## Org Traffic Report — ${effective_date}"
    echo "Traffic rows upserted: $(echo "$rows" | wc -l)"
    echo "Stats rows upserted: $([ -n "$stats_rows" ] && echo "$stats_rows" | wc -l || echo 0)"
    echo "Distinct referrers aggregated: $([ -n "$all_referrers" ] && echo "$all_referrers" | cut -f1 | sort -u | wc -l || echo 0)"
  } >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
