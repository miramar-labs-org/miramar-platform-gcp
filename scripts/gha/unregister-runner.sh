#!/usr/bin/env bash
set -euo pipefail

GITHUB_OWNER="miramar-labs-org"
NAME_FILTER="${1:-}"

# Uses your interactive gh login (needs admin:org: gh auth refresh -s admin:org).
gh_api() { gh api "$@"; }

echo "Fetching registered runners..."
RUNNERS_JSON=$(gh_api "orgs/${GITHUB_OWNER}/actions/runners")

RUNNERS=$(echo "${RUNNERS_JSON}" | jq -r '.runners[] | "\(.id)  \(.name)  (\(.status))"')

if [[ -z "${RUNNERS}" ]]; then
  echo "No runners registered."
  exit 0
fi

echo "${RUNNERS}"
echo ""

if [[ -n "${NAME_FILTER}" ]]; then
  RUNNER_ID=$(echo "${RUNNERS_JSON}" | jq -r ".runners[] | select(.name == \"${NAME_FILTER}\") | .id")
  if [[ -z "${RUNNER_ID}" ]]; then
    echo "ERROR: no runner named '${NAME_FILTER}'" >&2
    exit 1
  fi
else
  echo -n "Enter runner ID to remove: "
  read -r RUNNER_ID
fi

echo "Removing runner ID ${RUNNER_ID}..."
gh_api -X DELETE "orgs/${GITHUB_OWNER}/actions/runners/${RUNNER_ID}"
echo "Done."
