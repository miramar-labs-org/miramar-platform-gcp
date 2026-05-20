#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --bucket <name> [options]"
  echo ""
  echo "Options:"
  echo "  --bucket      Bucket name, without gs:// prefix (required)"
  echo "  --project     GCP project ID (default: miramar-platform)"
  echo "  --location    GCS location (default: us-central1)"
  echo "  --grant-sa    Service account to grant storage.admin on the project (optional)"
  exit 1
}

BUCKET=""
PROJECT="miramar-platform"
LOCATION="us-central1"
GRANT_SA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)   BUCKET="$2";   shift 2 ;;
    --project)  PROJECT="$2";  shift 2 ;;
    --location) LOCATION="$2"; shift 2 ;;
    --grant-sa) GRANT_SA="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$BUCKET" ]]; then
  echo "ERROR: --bucket is required" >&2
  usage
fi

echo "Creating gs://$BUCKET in $LOCATION (idempotent)..."
if gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT" &>/dev/null; then
  echo "Bucket already exists — skipping create."
else
  gcloud storage buckets create "gs://$BUCKET" \
    --project="$PROJECT" \
    --location="$LOCATION"
  echo "Created gs://$BUCKET"
fi

if [[ -n "$GRANT_SA" ]]; then
  echo "Granting serviceAccount:$GRANT_SA storage.admin on project $PROJECT..."
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$GRANT_SA" \
    --role=roles/storage.admin \
    --condition=None
fi

echo "Done. gs://$BUCKET is ready."
