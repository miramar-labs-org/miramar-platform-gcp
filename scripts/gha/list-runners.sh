#!/usr/bin/env bash
set -euo pipefail

GITHUB_OWNER="miramar-labs-org"

if [[ -z "${GITHUB_ADMIN_PAT:-}" ]]; then
    echo "ERROR: GITHUB_ADMIN_PAT is not set (needs admin:org scope)" >&2
    exit 1
fi

curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_ADMIN_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners" \
  | jq -r '.runners[] | "\(.id)  \(.name)  \(.status)  \(.busy | if . then "busy" else "idle" end)  \([.labels[].name] | join(","))"'
