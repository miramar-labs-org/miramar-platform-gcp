#!/bin/bash
# Source this file, then call runner_app_token to print a 1-hour installation token
# for the miramar-runner-registrar GitHub App (Organization: Self-hosted runners RW only).
#
# Replaces GITHUB_ORG_ADMIN_PAT for runner registration (Nov 2026 incident). Runs on the
# host only; the key and this token are not put in the runner container env, which
# receives just the registration token. (Jobs can still reach host files via the
# docker.sock mount; see docs/runners.md.)
#
# Requires (from ~/.config/systemd/user/mlabs-runner.env or the shell):
#   RUNNER_APP_CLIENT_ID  — the App's Client ID (Iv23...)
#   RUNNER_APP_KEY_FILE   — path to the App private key (.pem, chmod 600)

_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

runner_app_token() {
  local owner="${1:-miramar-labs-org}"
  if [[ -z "${RUNNER_APP_CLIENT_ID:-}" || ! -r "${RUNNER_APP_KEY_FILE:-}" ]]; then
    echo "ERROR: RUNNER_APP_CLIENT_ID / RUNNER_APP_KEY_FILE not set or key unreadable" >&2
    return 1
  fi
  local now header payload sig jwt inst
  now=$(date +%s)
  header=$(printf '{"alg":"RS256","typ":"JWT"}' | _b64url)
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' \
    $((now - 60)) $((now + 540)) "${RUNNER_APP_CLIENT_ID}" | _b64url)
  sig=$(printf '%s.%s' "${header}" "${payload}" \
    | openssl dgst -sha256 -sign "${RUNNER_APP_KEY_FILE}" -binary | _b64url)
  jwt="${header}.${payload}.${sig}"

  inst=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${jwt}" \
    "https://api.github.com/orgs/${owner}/installation" | jq -r '.id')
  curl -fsSL -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${jwt}" \
    "https://api.github.com/app/installations/${inst}/access_tokens" | jq -r '.token'
}
