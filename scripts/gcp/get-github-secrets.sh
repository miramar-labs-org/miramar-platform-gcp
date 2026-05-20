#!/usr/bin/env bash
set -euo pipefail

PROJECT="miramar-platform"
WIF_POOL="github-actions"
WIF_PROVIDER="github"
SA="gh-gke-cluster-ops@${PROJECT}.iam.gserviceaccount.com"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')

WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"

echo ""
echo "GitHub secret values for miramar-platform-gcp:"
echo ""
echo "  WIF_PROVIDER"
echo "  ${WIF_PROVIDER_RESOURCE}"
echo ""
echo "  GCP_SERVICE_ACCOUNT"
echo "  ${SA}"
echo ""
echo "Set them at: https://github.com/miramar-labs-org/miramar-platform-gcp/settings/secrets/actions"
echo ""
