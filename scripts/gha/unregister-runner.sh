#!/usr/bin/env bash
set -euo pipefail

GITHUB_OWNER="miramar-labs-org"
RUNNER_DIR="${HOME}/actions-runner"

echo "Fetching removal token..."
REMOVE_TOKEN=$(gh api --method POST \
  /orgs/${GITHUB_OWNER}/actions/runners/remove-token \
  --jq '.token')

echo "Removing runner..."
"${RUNNER_DIR}/config.sh" remove --token "${REMOVE_TOKEN}"

echo "Done."
