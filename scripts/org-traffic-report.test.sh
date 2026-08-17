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

exit "$fail"
