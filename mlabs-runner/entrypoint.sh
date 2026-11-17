#!/bin/bash
set -euo pipefail

GITHUB_OWNER="${GITHUB_OWNER:-miramar-labs-org}"
GITHUB_REPO="${GITHUB_REPO:-}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"
EPHEMERAL="${EPHEMERAL:-false}"

# The host (scripts/gha/launch-runner.sh) mints a single-use registration token; no
# GitHub credential that outlives registration is ever passed into this container.
if [[ -z "${RUNNER_TOKEN:-}" ]]; then
  echo "ERROR: RUNNER_TOKEN must be set" >&2
  exit 1
fi

if [[ -n "${GITHUB_REPO}" ]]; then
  GITHUB_URL="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"
else
  GITHUB_URL="https://github.com/${GITHUB_OWNER}"
fi

EXTRA_FLAGS=""
[[ "${EPHEMERAL}" == "true" ]] && EXTRA_FLAGS="--ephemeral"

cleanup() {
  echo "Deregistering runner..."
  # Works while the registration token is fresh (1 h). After that this fails and the
  # stale entry is replaced by the next launch (launch-runner.sh deletes it + --replace).
  ./config.sh remove --token "${RUNNER_TOKEN}" || true
}
trap cleanup SIGTERM SIGINT SIGQUIT

./config.sh \
  --unattended \
  --url "${GITHUB_URL}" \
  --token "${RUNNER_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --runnergroup "${RUNNER_GROUP}" \
  --work "${RUNNER_WORKDIR}" \
  --replace \
  ${EXTRA_FLAGS}

./run.sh &
wait $!
