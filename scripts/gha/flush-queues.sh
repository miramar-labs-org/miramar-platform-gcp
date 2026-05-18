#!/bin/bash
# Cancel all in-progress, queued, and waiting workflow runs

set -euo pipefail

REPO="${1:-miramar-labs/github-actions-hello}"

echo "Fetching active runs for $REPO..."

IDS=$(gh run list --repo "$REPO" --limit 50 --json databaseId,status | python3 -c "
import json, sys
runs = json.load(sys.stdin)
active = [str(r['databaseId']) for r in runs if r['status'] in ('in_progress', 'queued', 'waiting')]
print('\n'.join(active))
")

if [ -z "$IDS" ]; then
  echo "No active runs."
  exit 0
fi

echo "Cancelling:"
while IFS= read -r id; do
  gh run cancel "$id" --repo "$REPO" && echo "  cancelled $id"
done <<< "$IDS"
