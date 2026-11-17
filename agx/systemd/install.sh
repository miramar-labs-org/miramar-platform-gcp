#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Service unit files live in dgx/systemd/ — AGX uses the same service definitions on the same host ports.
# The SSH tunnel from the laptop uses offset local ports to avoid conflicts with the DGX tunnel.
DGX_SYSTEMD="$(cd "${SCRIPT_DIR}/../../dgx/systemd" && pwd)"
DEST="$HOME/.config/systemd/user"
# k3s is managed by its own systemd service (k3s.service, installed by install-k3s.sh).
# Port-forward services declare After=k3s.service so they start in the right order.
# AGX runs the same eleven services as DGX; unit files are shared from dgx/systemd/.
SERVICES=(mlabs-runner dashboard jupyterlab mlflow-portfwd kubeflow-portfwd kfp-api-portfwd nemo-portfwd qdrant-portfwd postgres-portfwd nsight-portfwd openwebui-portfwd)

mkdir -p "$DEST"

# Enable linger so user services start on boot without requiring an interactive login
loginctl enable-linger "$(id -un)"

# Create the runner env file if it doesn't exist. Host-side only — none of these reach
# the runner container (scripts/gha/launch-runner.sh):
#   RUNNER_APP_CLIENT_ID / RUNNER_APP_KEY_FILE — miramar-runner-registrar App (mints the
#     single-use registration token)
#   GITHUB_ORG_GHCR_PAT — read:packages, host `docker login` to pull mlabs-runner
RUNNER_ENV="${DEST}/mlabs-runner.env"
if [[ ! -f "${RUNNER_ENV}" ]]; then
  printf 'RUNNER_APP_CLIENT_ID=%s\nRUNNER_APP_KEY_FILE=%s\nGITHUB_ORG_GHCR_PAT=%s\n' \
    "${RUNNER_APP_CLIENT_ID:-}" \
    "${RUNNER_APP_KEY_FILE:-$HOME/.config/mlabs-runner/registrar.pem}" \
    "${GITHUB_ORG_GHCR_PAT:-}" >"${RUNNER_ENV}"
  chmod 600 "${RUNNER_ENV}"
  echo "Created ${RUNNER_ENV} (fill in RUNNER_APP_CLIENT_ID if not seeded from current environment)"
else
  echo "${RUNNER_ENV} already exists — skipping"
fi

for svc in "${SERVICES[@]}"; do
  echo "Installing ${svc}.service..."
  cp "${DGX_SYSTEMD}/${svc}.service" "${DEST}/${svc}.service"
done

systemctl --user daemon-reload

for svc in "${SERVICES[@]}"; do
  systemctl --user enable "${svc}"
  # Port-forward services may fail when their backend isn't deployed yet — that's fine;
  # they're Restart=on-failure and will come up once the stack is deployed.
  if [[ "${svc}" == *-portfwd ]]; then
    systemctl --user restart "${svc}" || true
  else
    systemctl --user restart "${svc}"
  fi
  printf '  %-22s %s\n' "${svc}" "$(systemctl --user is-active ${svc})"
done
