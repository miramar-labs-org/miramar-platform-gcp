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
    *)
      return 1
      ;;
  esac
}
export -f gh

REPORT_DATE="2026-08-16"
DRY_RUN="true"
# shellcheck source=org-traffic-report.sh
source "$(dirname "$0")/org-traffic-report.sh"

repos_out="$(discover_repos)"
assert_eq "discover_repos excludes archived repos" \
  "$(printf 'repo-a\tfalse\nrepo-b\ttrue')" "$repos_out"

row_out="$(fetch_repo_row "repo-a" "false")"
assert_eq "fetch_repo_row builds correct SQL tuple" \
  "('2026-08-16','repo-a','public',42,10,5,3)" "$row_out"

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

payload_out="$(build_slack_payload "100,40,10,5" "$(printf 'repo-a,25\nrepo-b,15')")"
assert_eq "build_slack_payload is valid JSON" \
  "0" "$(echo "$payload_out" | jq empty >/dev/null 2>&1; echo $?)"
assert_eq "build_slack_payload includes totals" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'Views:.*100')"
assert_eq "build_slack_payload includes top repo" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c 'repo-a')"
assert_eq "build_slack_payload renders real newlines between top5 lines" \
  "1" "$(echo "$payload_out" | jq -r .text | grep -c '^2\. \*repo-b\*')"

exit "$fail"
