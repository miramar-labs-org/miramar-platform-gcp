#!/usr/bin/env bash
# One-time script: delete the legacy miramar-cicd and miramar-platform projects.
# GCP schedules project deletion with a 30-day undelete window.
# Run this once, then test miramar-platform-create workflow to reprovision.
set -euo pipefail

PROJECTS=(miramar-cicd miramar-platform)

echo "================================================================"
echo "  WARNING: This will schedule deletion of these GCP projects:"
for p in "${PROJECTS[@]}"; do
  echo "    - $p"
done
echo ""
echo "  All resources (GKE, AR, WIF, SAs, GCS) will be destroyed."
echo "  You have 30 days to undelete via: gcloud projects undelete <id>"
echo "================================================================"
echo ""

# Show current state of each project before deleting.
for p in "${PROJECTS[@]}"; do
  if gcloud projects describe "$p" &>/dev/null; then
    echo "--- $p ---"
    gcloud projects describe "$p" --format="value(name,projectId,lifecycleState)"
  else
    echo "--- $p --- (not found / already deleted)"
  fi
done

echo ""
read -r -p "Type 'delete' to confirm: " CONFIRM
if [ "$CONFIRM" != "delete" ]; then
  echo "Aborted."
  exit 1
fi

echo ""
for p in "${PROJECTS[@]}"; do
  if gcloud projects describe "$p" &>/dev/null; then
    echo "Deleting $p..."
    gcloud projects delete "$p" --quiet
    echo "  $p scheduled for deletion."
  else
    echo "  $p not found — skipping."
  fi
done

echo ""
echo "Done. Both projects are scheduled for deletion."
echo "Undelete within 30 days: gcloud projects undelete <project-id>"
echo ""
echo "Next: run the 'Miramar Platform Create' GitHub Actions workflow"
echo "to provision the new single-project stack."
