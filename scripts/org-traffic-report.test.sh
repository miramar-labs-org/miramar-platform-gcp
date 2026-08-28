#!/usr/bin/env bash
set -euo pipefail

fail=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    echo "FAIL: ${desc}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    fail=1
  else
    echo "PASS: ${desc}"
  fi
}

# Stub `gh` before sourcing, so discover_repos/fetch_repo_row never hit the network.
# shellcheck disable=SC2317  # invoked indirectly via `export -f` by the sourced script
gh() {
  case "$1 $2" in
    "api orgs/miramar-labs-org/repos")
      cat <<'JSON'
[{"name":"repo-a","private":false,"archived":false},{"name":"repo-b","private":true,"archived":false},{"name":"repo-old","private":false,"archived":true}]
JSON
      ;;
    "api repos/miramar-labs-org/repo-a/traffic/views")
      echo '{"views":[{"timestamp":"2026-08-16T00:00:00Z","count":42,"uniques":10}]}'
      ;;
    "api repos/miramar-labs-org/repo-a/traffic/clones")
      echo '{"clones":[{"timestamp":"2026-08-16T00:00:00Z","count":5,"uniques":3}]}'
      ;;
    "api repos/miramar-labs-org/repo-a")
      echo '{"stargazers_count":10,"forks_count":3,"subscribers_count":2,"watchers_count":10}'
      ;;
    "api repos/miramar-labs-org/repo-a/traffic/popular/referrers")
      echo '[{"referrer":"google.com","count":20,"uniques":12},{"referrer":"github.com","count":5,"uniques":4}]'
      ;;
    "api repos/miramar-labs-org/repo-c/traffic/views")
      # Simulates GitHub's real Traffic API lag: the most recent entry is
      # several days behind "today", not the "yesterday" REPORT_DATE guesses.
      cat <<'JSON'
{"views":[{"timestamp":"2026-08-13T00:00:00Z","count":1,"uniques":1},{"timestamp":"2026-08-14T00:00:00Z","count":0,"uniques":0},{"timestamp":"2026-08-15T00:00:00Z","count":9,"uniques":4}]}
JSON
      ;;
    "api repos/miramar-labs-org/repo-c/traffic/clones")
      cat <<'JSON'
{"clones":[{"timestamp":"2026-08-13T00:00:00Z","count":2,"uniques":1},{"timestamp":"2026-08-14T00:00:00Z","count":0,"uniques":0},{"timestamp":"2026-08-15T00:00:00Z","count":6,"uniques":2}]}
JSON
      ;;
    "api repos/miramar-labs-org/repo-d/traffic/views")
      # Today (2026-08-17, see TODAY export below) is present but still
      # in-progress/zero; the prior day is a real, complete day.
      cat <<'JSON'
{"views":[{"timestamp":"2026-08-16T00:00:00Z","count":7,"uniques":3},{"timestamp":"2026-08-17T00:00:00Z","count":0,"uniques":0}]}
JSON
      ;;
    "api repos/miramar-labs-org/repo-d/traffic/clones")
      cat <<'JSON'
{"clones":[{"timestamp":"2026-08-16T00:00:00Z","count":4,"uniques":2},{"timestamp":"2026-08-17T00:00:00Z","count":0,"uniques":0}]}
JSON
      ;;
    "api repos/miramar-labs-org/repo-e/traffic/views")
      # Brand-new/quiet repo: today is the ONLY entry available at all.
      echo '{"views":[{"timestamp":"2026-08-17T00:00:00Z","count":0,"uniques":0}]}'
      ;;
    "api repos/miramar-labs-org/repo-e/traffic/clones")
      echo '{"clones":[{"timestamp":"2026-08-17T00:00:00Z","count":0,"uniques":0}]}'
      ;;
    *)
      return 1
      ;;
  esac
}
export -f gh

export DRY_RUN="true"
export TODAY="2026-08-17"
# shellcheck source=org-traffic-report.sh disable=SC1091
source "$(dirname "$0")/org-traffic-report.sh"

repos_out="$(discover_repos)"
assert_eq "discover_repos excludes archived AND private repos" \
  "$(printf 'repo-a\tfalse')" "$repos_out"

row_out="$(fetch_repo_row "repo-a" "false")"
assert_eq "fetch_repo_row builds correct SQL tuple" \
  "2026-08-16	('2026-08-16','repo-a','public',42,10,5,3)" "$row_out"

row_c_out="$(fetch_repo_row "repo-c" "false")"
assert_eq "fetch_repo_row uses the most recent available API entry, not REPORT_DATE (GitHub's traffic API lags)" \
  "2026-08-15	('2026-08-15','repo-c','public',9,4,6,2)" "$row_c_out"

row_d_out="$(fetch_repo_row "repo-d" "false")"
assert_eq "fetch_repo_row prefers the last complete day over an in-progress today" \
  "2026-08-16	('2026-08-16','repo-d','public',7,3,4,2)" "$row_d_out"

row_e_out="$(fetch_repo_row "repo-e" "false")"
assert_eq "fetch_repo_row falls back to today when it's the only entry available" \
  "2026-08-17	('2026-08-17','repo-e','public',0,0,0,0)" "$row_e_out"

sql_out="$(build_upsert_sql "('2026-08-16','repo-a','public',42,10,5,3)
('2026-08-16','repo-b','public',7,2,0,0)")"
assert_eq "build_upsert_sql includes CREATE TABLE" \
  "1" "$(echo "$sql_out" | grep -c 'CREATE TABLE IF NOT EXISTS repo_traffic_daily')"
assert_eq "build_upsert_sql includes both value rows" \
  "yes" "$(echo "$sql_out" | grep -q "repo-a" && echo "$sql_out" | grep -q "repo-b" && echo "yes")"
assert_eq "build_upsert_sql includes ON CONFLICT upsert" \
  "1" "$(echo "$sql_out" | grep -c 'ON CONFLICT (date, repo) DO UPDATE')"
assert_eq "build_upsert_sql is a single INSERT statement (no semicolon before ON CONFLICT)" \
  "0" "$(echo "$sql_out" | sed -n '/^INSERT INTO/,/^ON CONFLICT/p' | grep -c ';')"

empty_sql="$(build_upsert_sql "")"
assert_eq "build_upsert_sql with no rows prints nothing" "" "$empty_sql"

# --- fetch_repo_stats ------------------------------------------------------
stats_row_out="$(fetch_repo_stats "repo-a")"
assert_eq "fetch_repo_stats builds a repo_stats_daily tuple (watchers = subscribers_count)" \
  "('2026-08-17','repo-a',10,3,2)" "$stats_row_out"

# --- build_stats_upsert_sql ---------------------------------------------------
stats_sql_out="$(build_stats_upsert_sql "('2026-08-17','repo-a',10,3,2)
('2026-08-17','repo-b',1,0,0)")"
assert_eq "build_stats_upsert_sql includes CREATE TABLE" \
  "1" "$(echo "$stats_sql_out" | grep -c 'CREATE TABLE IF NOT EXISTS repo_stats_daily')"
assert_eq "build_stats_upsert_sql includes ON CONFLICT upsert" \
  "1" "$(echo "$stats_sql_out" | grep -c 'ON CONFLICT (date, repo) DO UPDATE')"
assert_eq "build_stats_upsert_sql with no rows prints nothing" \
  "" "$(build_stats_upsert_sql "")"

# --- format_delta -----------------------------------------------------------
assert_eq "format_delta shows a positive gain"  "Stars: *41* (+2)" "$(format_delta Stars 41 39)"
assert_eq "format_delta shows a loss"           "Stars: *41* (-1)" "$(format_delta Stars 41 42)"
assert_eq "format_delta shows no change as dash" "Stars: *5* (—)"   "$(format_delta Stars 5 5)"
assert_eq "format_delta omits parens with no prior value" "Stars: *5*" "$(format_delta Stars 5 '')"

# --- fetch_referrers / aggregate_referrers ---------------------------------
assert_eq "fetch_referrers emits referrer/count/uniques lines" \
  "$(printf 'google.com\t20\t12\ngithub.com\t5\t4')" "$(fetch_referrers "repo-a")"
agg_out="$(printf 'google.com\t10\t6\ngithub.com\t3\t2\ngoogle.com\t5\t3\n' | aggregate_referrers)"
assert_eq "aggregate_referrers sums per referrer across repos and ranks by count" \
  "$(printf 'google.com,15,9\ngithub.com,3,2')" "$agg_out"

# --- build_slack_payload --------------------------------------------------
payload_out="$(build_slack_payload "100,40,10,5" "$(printf 'repo-a,25\nrepo-b,15')" "2026-08-16" \
  "$(printf 'Stars: *41* (+2)   Forks: *8* (+1)   Watchers: *5* (—)\n:star: New stars: *repo-a* +2')" \
  "$(printf 'google.com,30,18\nnews.ycombinator.com,8,7')")"
assert_eq "build_slack_payload is valid JSON" \
  "0" "$(echo "$payload_out" | jq empty >/dev/null 2>&1; echo $?)"
assert_eq "build_slack_payload includes views total" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'Views: \*100\*')"
assert_eq "build_slack_payload ranks the top repo first" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c '^1\. \*repo-a\* — 25$')"
assert_eq "build_slack_payload renders real newlines between ranking lines" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c '^2\. \*repo-b\*')"
assert_eq "build_slack_payload labels the section by unique visitors, not Top 10" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'Public repos by unique visitors')"
assert_eq "build_slack_payload no longer caps the section at Top 10" \
  "0" "$(echo "$payload_out" | jq -r .text | grep -c 'Top 10')"
assert_eq "build_slack_payload renders the stars/forks/watchers line" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'Stars: \*41\* (+2)')"
assert_eq "build_slack_payload renders the new-stars callout" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c ':star: New stars: \*repo-a\* +2')"
assert_eq "build_slack_payload renders the referrers section" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'Top referrers')"
assert_eq "build_slack_payload renders a referrer line with views and uniques" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'google.com — 30 views (18 unique)')"
assert_eq "build_slack_payload demotes clones to the CI/dev footnote" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'Clones that day: 10 .* mostly CI/dev')"

no_extras_payload="$(build_slack_payload "1,1,1,1" "repo-a,1" "2026-08-16")"
assert_eq "build_slack_payload omits the referrers section when there are none" \
  "0" "$(echo "$no_extras_payload" | jq -r .text | grep -c 'Top referrers')"
assert_eq "build_slack_payload omits the stars line when stats are unavailable" \
  "0" "$(echo "$no_extras_payload" | jq -r .text | grep -c 'Stars:')"

many_rows="$(for i in $(seq 1 15); do echo "repo-${i},$((30 - i))"; done)"
big_payload="$(build_slack_payload "100,40,10,5" "$many_rows" "2026-08-16")"
assert_eq "build_slack_payload renders every repo, not just the first 10" \
  "1" "$(echo "$big_payload" | jq -r .text | grep -c '^15\. \*repo-15\*')"

dry_run_out="$(DRY_RUN=true GITHUB_STEP_SUMMARY=/dev/null main 2>&1)"
assert_eq "main dry-run prints the traffic upsert SQL" \
  "1" "$(echo "$dry_run_out" | grep -c 'INSERT INTO repo_traffic_daily')"
assert_eq "main dry-run prints the stats upsert SQL" \
  "1" "$(echo "$dry_run_out" | grep -c 'INSERT INTO repo_stats_daily')"
assert_eq "main dry-run prints the Slack payload" \
  "1" "$(echo "$dry_run_out" | grep -c 'bar_chart')"
assert_eq "main dry-run Slack payload carries the referrers section" \
  "1" "$(echo "$dry_run_out" | grep -c 'Top referrers')"

exit "$fail"
