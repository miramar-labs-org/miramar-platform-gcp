#!/usr/bin/env bash
set -euo pipefail

GITHUB_OWNER="miramar-labs-org"

# Uses your interactive gh login (needs admin:org: gh auth refresh -s admin:org).
gh api "orgs/${GITHUB_OWNER}/actions/runners" \
  | jq -r '.runners[] | "\(.id)  \(.name)  \(.status)  \(.busy | if . then "busy" else "idle" end)  \([.labels[].name] | join(","))"'
