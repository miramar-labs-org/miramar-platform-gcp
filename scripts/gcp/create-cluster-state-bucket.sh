#!/usr/bin/env bash
set -euo pipefail

PROJECT="miramar-platform"
LOCATION="us-west1"
BUCKET="miramar-platform-cluster-state"
SA="gh-github-deploy-github-action@miramar-cicd.iam.gserviceaccount.com"

echo "Creating gs://$BUCKET in $LOCATION..."
gcloud storage buckets create "gs://$BUCKET" \
  --project="$PROJECT" \
  --location="$LOCATION"

echo "Granting $SA objectAdmin on gs://$BUCKET..."
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
  --member="serviceAccount:$SA" \
  --role=roles/storage.objectAdmin

echo "Done. gs://$BUCKET is ready for the GKE expand/restore workflows."
