#!/usr/bin/env bash
set -euo pipefail
NSYS_TMP="/tmp/nsys_report"
mkdir -p "$NSYS_TMP"

nsys profile \
  --trace=cuda,nvtx,osrt \
  --capture-range=nvtx \
  --force-overwrite=true \
  -o "$NSYS_TMP/profile" \
  "$@"

RUN_ID=$(cat /tmp/nsys_run_id 2>/dev/null || echo "unknown")
STAGE=$(cat /tmp/nsys_stage 2>/dev/null || echo "unknown")
PROJECT=$(cat /tmp/nsys_project 2>/dev/null || echo "${NSYS_PROJECT:-project}")
OUT_DIR="/nsight-reports/$PROJECT/$RUN_ID/$STAGE"
chmod -R 777 /nsight-reports 2>/dev/null || true
mkdir -p "$OUT_DIR" && chmod 777 "$OUT_DIR"
cp "$NSYS_TMP/profile.nsys-rep" "$OUT_DIR/profile.nsys-rep"
echo "nsys report saved: $OUT_DIR/profile.nsys-rep"
