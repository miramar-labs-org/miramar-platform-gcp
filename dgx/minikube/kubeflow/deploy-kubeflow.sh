#!/usr/bin/env bash
set -euo pipefail

PIPELINE_VERSION="${PIPELINE_VERSION:-2.16.1}"
MLMD_SERVER_VERSION="${MLMD_SERVER_VERSION:-1.14.0}"
ORG="ghcr.io/miramar-labs-org"

MLMD_SERVER_IMAGE="${ORG}/ml_metadata_store_server:${MLMD_SERVER_VERSION}-arm64"
METADATA_WRITER_IMAGE="${ORG}/kfp-metadata-writer:${PIPELINE_VERSION}-arm64"

# Pre-flight: verify arm64 MLMD images exist before applying kustomize.
# If missing, the deploy would apply successfully but MLMD pods would fail.
echo "==> Checking arm64 MLMD images exist on GHCR ..."
for img in "${MLMD_SERVER_IMAGE}" "${METADATA_WRITER_IMAGE}"; do
  if ! docker manifest inspect "${img}" >/dev/null 2>&1; then
    echo "ERROR: ${img} not found." >&2
    echo "Run the 'Build MLMD arm64 Images' workflow first, then retry." >&2
    exit 1
  fi
done
echo "    OK — both images found."

echo "==> Installing cluster-scoped resources (CRDs, ClusterRoles) ..."
kubectl apply -k \
  "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=${PIPELINE_VERSION}"

echo "==> Waiting for applications.app.k8s.io CRD ..."
kubectl wait --for condition=established --timeout=60s crd/applications.app.k8s.io

echo "==> Installing Kubeflow Pipelines (env/dev) into kubeflow namespace ..."
kubectl apply -k \
  "github.com/kubeflow/pipelines/manifests/kustomize/env/dev?ref=${PIPELINE_VERSION}"

# controller-manager (gcr.io/ml-pipeline/application-crd-controller) is amd64-only
# and manages the Application CRD for display purposes only — not needed for pipelines.
echo "==> Removing arm64-incompatible controller-manager ..."
kubectl delete deployment controller-manager -n kubeflow --ignore-not-found || true

# Create (or update) a GHCR imagePullSecret in the kubeflow namespace.
# GITHUB_TOKEN is a short-lived Actions token with packages:read — sufficient
# to pull from ghcr.io. The secret is recreated each deploy so the token stays fresh.
echo "==> Creating GHCR imagePullSecret in kubeflow namespace ..."
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username="${GITHUB_ACTOR:-github-actions}" \
  --docker-password="${GITHUB_TOKEN}" \
  --namespace=kubeflow \
  --dry-run=client -o yaml | kubectl apply -f -

# Patch the MLMD stack with arm64-compatible images built by 'Build MLMD arm64 Images'.
# Container names are from the upstream deployment specs:
#   metadata-grpc-deployment → container name: "container"
#   metadata-writer          → container name: "main"
echo "==> Patching MLMD deployments with arm64 images and GHCR pull secret ..."
kubectl set image deployment/metadata-grpc-deployment \
  container="${MLMD_SERVER_IMAGE}" \
  -n kubeflow
kubectl set image deployment/metadata-writer \
  main="${METADATA_WRITER_IMAGE}" \
  -n kubeflow
# Add imagePullSecrets so pods can pull from private GHCR registry
for deploy in metadata-grpc-deployment metadata-writer; do
  kubectl patch deployment "${deploy}" -n kubeflow \
    -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}}}}'
done
echo "    ml_metadata_store_server → ${MLMD_SERVER_IMAGE}"
echo "    kfp-metadata-writer      → ${METADATA_WRITER_IMAGE}"
