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
assert_eq "discover_repos excludes archived repos" \
  "$(printf 'repo-a\tfalse\nrepo-b\ttrue')" "$repos_out"

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
('2026-08-16','repo-b','private',7,2,0,0)")"
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

payload_out="$(build_slack_payload "100,40,10,5" "$(printf 'repo-a,25\nrepo-b,15')" "2026-08-16")"
assert_eq "build_slack_payload is valid JSON" \
  "0" "$(echo "$payload_out" | jq empty >/dev/null 2>&1; echo $?)"
assert_eq "build_slack_payload includes totals" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'Views:.*100')"
assert_eq "build_slack_payload includes top repo" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'repo-a')"
assert_eq "build_slack_payload renders real newlines between top10 lines" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c '^2\. \*repo-b\*')"
assert_eq "build_slack_payload labels the section Top 10" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'Top 10 by unique visitors')"

dry_run_out="$(DRY_RUN=true GITHUB_STEP_SUMMARY=/dev/null main 2>&1)"
assert_eq "main dry-run prints the upsert SQL" \
  "1" "$(echo "$dry_run_out" | grep -c 'INSERT INTO repo_traffic_daily')"
assert_eq "main dry-run prints the Slack payload" \
  "1" "$(echo "$dry_run_out" | grep -c 'bar_chart')"

exit "$fail"
