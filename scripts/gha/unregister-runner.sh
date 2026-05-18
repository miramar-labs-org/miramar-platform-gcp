#!/usr/bin/env bash
set -euo pipefail

GITHUB_OWNER="miramar-labs-org"
NAME_FILTER="${1:-}"

if [[ -z "${GITHUB_ADMIN_PAT:-}" ]]; then
    echo "ERROR: GITHUB_ADMIN_PAT is not set (needs admin:org scope)" >&2
    exit 1
fi

gh_api() {
    curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_ADMIN_PAT}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$@"
}

echo "Fetching registered runners..."
RUNNERS_JSON=$(gh_api "https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners")

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
gh_api -X DELETE "https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/${RUNNER_ID}"
echo "Done."
