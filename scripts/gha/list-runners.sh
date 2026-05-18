#!/usr/bin/env bash
set -euo pipefail

GITHUB_OWNER="miramar-labs-org"

gh api /orgs/${GITHUB_OWNER}/actions/runners \
  --jq '.runners[] | {name, status, busy, labels: [.labels[].name]}'
