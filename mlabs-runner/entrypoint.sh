#!/bin/bash
set -euo pipefail

GITHUB_OWNER="${GITHUB_OWNER:-miramar-labs-org}"
GITHUB_REPO="${GITHUB_REPO:-}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_WORKDIR="${RUNNER_WORKDIR:-_work}"
EPHEMERAL="${EPHEMERAL:-false}"

if [[ -z "${RUNNER_TOKEN:-}" ]]; then
    if [[ -z "${GITHUB_PAT:-}" ]]; then
        echo "ERROR: Either RUNNER_TOKEN or GITHUB_PAT must be set" >&2
        exit 1
    fi

    if [[ -n "${GITHUB_REPO}" ]]; then
        REGISTRATION_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
    else
        REGISTRATION_URL="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/registration-token"
    fi

    RUNNER_TOKEN=$(curl -fsSL \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${REGISTRATION_URL}" | jq -r '.token')
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
    REMOVE_TOKEN="${RUNNER_TOKEN}"
    if [[ -n "${GITHUB_ORG_ADMIN_PAT:-}" ]]; then
        GITHUB_PAT="${GITHUB_ORG_ADMIN_PAT}"
    fi
    if [[ -n "${GITHUB_PAT:-}" ]]; then
        # Registration tokens expire after 1 hour; try to fetch a fresh removal
        # token. Requires admin:org scope — fall back to RUNNER_TOKEN if denied.
        if [[ -n "${GITHUB_REPO}" ]]; then
            REMOVE_URL="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/remove-token"
        else
            REMOVE_URL="https://api.github.com/orgs/${GITHUB_OWNER}/actions/runners/remove-token"
        fi
        FRESH_TOKEN=$(curl -sS \
            -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${GITHUB_PAT}" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "${REMOVE_URL}" 2>/dev/null | jq -r '.token // empty')
        [[ -n "${FRESH_TOKEN}" ]] && REMOVE_TOKEN="${FRESH_TOKEN}"
    fi
    ./config.sh remove --token "${REMOVE_TOKEN}" || true
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
