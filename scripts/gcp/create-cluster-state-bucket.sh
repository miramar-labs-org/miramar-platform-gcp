#!/usr/bin/env bash
set -euo pipefail

PROJECT="miramar-platform"
LOCATION="us-west1"
BUCKET="miramar-platform-cluster-state"
SA="gh-github-deploy-github-action@miramar-cicd.iam.gserviceaccount.com"

echo "Creating gs://$BUCKET in $LOCATION (idempotent)..."
if gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT" &>/dev/null; then
  echo "Bucket already exists — skipping create."
else
  gcloud storage buckets create "gs://$BUCKET" \
    --project="$PROJECT" \
    --location="$LOCATION"
fi

echo "Granting $SA storage.admin on project $PROJECT..."
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:$SA" \
  --role=roles/storage.admin \
  --condition=None

echo "Done. gs://$BUCKET is ready and the deploy SA can now manage it."
