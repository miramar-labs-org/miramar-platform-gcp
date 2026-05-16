#!/usr/bin/env zsh
set -euo pipefail

gcloud container clusters delete miramar-shared-gke \
  --project miramar-platform \
  --zone us-west1-a \
  --quiet
