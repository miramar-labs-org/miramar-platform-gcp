#!/usr/bin/env bash
set -euo pipefail

PIPELINE_VERSION="${PIPELINE_VERSION:-2.16.1}"

# kfp-metadata-writer must be built for arm64 before deploying.
# Run the 'Build KFP arm64 Images' workflow first if this is the first deploy
# or after a version bump.
METADATA_WRITER_IMAGE="ghcr.io/miramar-labs-org/kfp-metadata-writer:${PIPELINE_VERSION}-arm64"
echo "==> Checking arm64 metadata-writer image exists ..."
if ! docker manifest inspect "${METADATA_WRITER_IMAGE}" >/dev/null 2>&1; then
  echo "ERROR: ${METADATA_WRITER_IMAGE} not found on GHCR." >&2
  echo "Run the 'Build KFP arm64 Images' workflow first." >&2
  exit 1
fi

echo "==> Installing cluster-scoped resources (CRDs, ClusterRoles) ..."
kubectl apply -k \
  "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=${PIPELINE_VERSION}"

echo "==> Waiting for applications.app.k8s.io CRD ..."
kubectl wait --for condition=established --timeout=60s crd/applications.app.k8s.io

echo "==> Installing Kubeflow Pipelines (env/dev) into kubeflow namespace ..."
kubectl apply -k \
  "github.com/kubeflow/pipelines/manifests/kustomize/env/dev?ref=${PIPELINE_VERSION}"

# controller-manager (gcr.io/ml-pipeline/application-crd-controller) is amd64-only
# and crashes on arm64. It manages the Application CRD for display purposes only —
# pipeline functionality is unaffected without it.
echo "==> Removing arm64-incompatible controller-manager ..."
kubectl delete deployment controller-manager -n kubeflow --ignore-not-found || true

# Patch the MLMD stack with arm64-compatible images.
#
#   metadata-grpc-deployment: upstream image (gcr.io/tfx-oss-public/ml_metadata_store_server)
#   is amd64-only C++ and crashes under QEMU. deployKF maintains a multi-arch build
#   at exactly the version KFP 2.x pins (1.14.0).
#
#   metadata-writer: upstream explicitly excludes arm64 from CI (kubeflow/pipelines PR#12804).
#   We build it natively on the DGX from the upstream Dockerfile (pure Python, no changes needed)
#   via the 'Build KFP arm64 Images' workflow.
echo "==> Patching MLMD deployments to arm64-compatible images ..."
kubectl set image deployment/metadata-grpc-deployment \
  container=ghcr.io/deploykf/ml_metadata_store_server:1.14.0-deploykf.0 \
  -n kubeflow
kubectl set image deployment/metadata-writer \
  main="${METADATA_WRITER_IMAGE}" \
  -n kubeflow
