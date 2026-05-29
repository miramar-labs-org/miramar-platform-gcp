#!/usr/bin/env bash
set -euo pipefail

PIPELINE_VERSION="${PIPELINE_VERSION:-2.16.1}"
MLMD_SERVER_VERSION="${MLMD_SERVER_VERSION:-1.14.0}"
ORG="ghcr.io/miramar-labs-org"

MLMD_SERVER_IMAGE="${ORG}/ml_metadata_store_server:${MLMD_SERVER_VERSION}-arm64"
METADATA_WRITER_IMAGE="${ORG}/kfp-metadata-writer:${PIPELINE_VERSION}-arm64"

# Whether native arm64 KFP component images are available (built by
# 'Build KFP arm64 Images' workflow). When true, all 11 KFP deployments
# are patched; when false only the MLMD stack is patched and the upstream
# amd64 images run under QEMU emulation.
USE_NATIVE_KFP_IMAGES="${USE_NATIVE_KFP_IMAGES:-true}"

# Pre-flight: verify required arm64 images exist on GHCR.
echo "==> Checking arm64 MLMD images exist on GHCR ..."
for img in "${MLMD_SERVER_IMAGE}" "${METADATA_WRITER_IMAGE}"; do
  if ! docker manifest inspect "${img}" >/dev/null 2>&1; then
    echo "ERROR: ${img} not found." >&2
    echo "Run the 'Build KFP arm64 Images' workflow first, then retry." >&2
    exit 1
  fi
done
echo "    OK — MLMD images found."

if [ "${USE_NATIVE_KFP_IMAGES}" = "true" ]; then
  echo "==> Checking arm64 KFP component images exist on GHCR ..."
  KFP_COMPONENTS=(
    kfp-api-server
    kfp-frontend
    kfp-persistence-agent
    kfp-scheduled-workflow-controller
    kfp-cache-server
    kfp-cache-deployer
    kfp-viewer-crd-controller
    kfp-metadata-envoy
    kfp-visualization-server
    kfp-driver
    kfp-launcher
  )
  missing=0
  for comp in "${KFP_COMPONENTS[@]}"; do
    img="${ORG}/${comp}:${PIPELINE_VERSION}-arm64"
    if ! docker manifest inspect "${img}" >/dev/null 2>&1; then
      echo "  MISSING: ${img}" >&2
      missing=$((missing + 1))
    fi
  done
  if [ "${missing}" -gt 0 ]; then
    echo "ERROR: ${missing} KFP arm64 image(s) missing." >&2
    echo "Run the 'Build KFP arm64 Images' workflow first, or set USE_NATIVE_KFP_IMAGES=false to skip." >&2
    exit 1
  fi
  echo "    OK — all KFP arm64 images found."
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
# and manages the Application CRD for display purposes only — not needed for pipelines.
echo "==> Removing arm64-incompatible controller-manager ..."
kubectl delete deployment controller-manager -n kubeflow --ignore-not-found || true

# Create (or update) a GHCR imagePullSecret in the kubeflow namespace.
# Uses GITHUB_ORG_GHCR_PAT (long-lived runner env var) so pods can pull even
# after the workflow run ends and GITHUB_TOKEN has expired.
echo "==> Creating GHCR imagePullSecret in kubeflow namespace ..."
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username="${GITHUB_ACTOR:-github-actions}" \
  --docker-password="${GITHUB_ORG_GHCR_PAT}" \
  --namespace=kubeflow \
  --dry-run=client -o yaml | kubectl apply -f -

# ---------------------------------------------------------------------------
# Patch MLMD stack (always — these have no upstream arm64 images at all)
# Container names from upstream deployment specs:
#   metadata-grpc-deployment → "container"
#   metadata-writer          → "main"
# ---------------------------------------------------------------------------
echo "==> Patching MLMD deployments with arm64 images ..."
kubectl set image deployment/metadata-grpc-deployment \
  container="${MLMD_SERVER_IMAGE}" \
  -n kubeflow
kubectl set image deployment/metadata-writer \
  main="${METADATA_WRITER_IMAGE}" \
  -n kubeflow
for deploy in metadata-grpc-deployment metadata-writer; do
  kubectl patch deployment "${deploy}" -n kubeflow \
    -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}}}}'
done
echo "    ml_metadata_store_server → ${MLMD_SERVER_IMAGE}"
echo "    kfp-metadata-writer      → ${METADATA_WRITER_IMAGE}"

# ---------------------------------------------------------------------------
# Patch remaining KFP components (when native arm64 images are available)
# Deployment → container name mapping from upstream manifests:
#   ml-pipeline                  → ml-pipeline          (api-server)
#   ml-pipeline-ui               → ml-pipeline-ui       (frontend)
#   ml-pipeline-persistenceagent → ml-pipeline-persistenceagent
#   ml-pipeline-scheduledworkflow→ ml-pipeline-scheduledworkflow
#   ml-pipeline-viewer-crd       → ml-pipeline-viewer-crd
#   ml-pipeline-visualizationserver→ ml-pipeline-visualizationserver
#   cache-server                 → server
#   cache-deployer-deployment    → main
#   metadata-envoy-deployment    → container
# ---------------------------------------------------------------------------
if [ "${USE_NATIVE_KFP_IMAGES}" = "true" ]; then
  echo "==> Patching KFP component deployments with native arm64 images ..."

  # Patch ml-pipeline (api-server) separately — container name differs from deployment name
  kubectl set image deployment/ml-pipeline \
    "ml-pipeline-api-server=${ORG}/kfp-api-server:${PIPELINE_VERSION}-arm64" \
    -n kubeflow
  kubectl patch deployment ml-pipeline -n kubeflow \
    -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}}}}'
  echo "    ml-pipeline → ${ORG}/kfp-api-server:${PIPELINE_VERSION}-arm64"

  # Deployments where container name == deployment name
  for deploy in \
    ml-pipeline-ui \
    ml-pipeline-persistenceagent \
    ml-pipeline-scheduledworkflow \
    ml-pipeline-viewer-crd \
    ml-pipeline-visualizationserver; do
    case "${deploy}" in
      ml-pipeline-ui)           comp="kfp-frontend" ;;
      ml-pipeline-persistenceagent) comp="kfp-persistence-agent" ;;
      ml-pipeline-scheduledworkflow) comp="kfp-scheduled-workflow-controller" ;;
      ml-pipeline-viewer-crd)   comp="kfp-viewer-crd-controller" ;;
      ml-pipeline-visualizationserver) comp="kfp-visualization-server" ;;
    esac
    img="${ORG}/${comp}:${PIPELINE_VERSION}-arm64"
    kubectl set image "deployment/${deploy}" "${deploy}=${img}" -n kubeflow
    kubectl patch deployment "${deploy}" -n kubeflow \
      -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}}}}'
    echo "    ${deploy} → ${img}"
  done

  # Deployments where container name differs from deployment name
  kubectl set image deployment/cache-server \
    "server=${ORG}/kfp-cache-server:${PIPELINE_VERSION}-arm64" \
    -n kubeflow
  kubectl patch deployment cache-server -n kubeflow \
    -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}}}}'
  echo "    cache-server → ${ORG}/kfp-cache-server:${PIPELINE_VERSION}-arm64"

  kubectl set image deployment/cache-deployer-deployment \
    "main=${ORG}/kfp-cache-deployer:${PIPELINE_VERSION}-arm64" \
    -n kubeflow
  kubectl patch deployment cache-deployer-deployment -n kubeflow \
    -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}}}}'
  echo "    cache-deployer-deployment → ${ORG}/kfp-cache-deployer:${PIPELINE_VERSION}-arm64"

  kubectl set image deployment/metadata-envoy-deployment \
    "container=${ORG}/kfp-metadata-envoy:${PIPELINE_VERSION}-arm64" \
    -n kubeflow
  kubectl patch deployment metadata-envoy-deployment -n kubeflow \
    -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}}}}'
  echo "    metadata-envoy-deployment → ${ORG}/kfp-metadata-envoy:${PIPELINE_VERSION}-arm64"

  # Patch pipeline-install-config ConfigMap so the driver and launcher images
  # used by Argo for actual pipeline step execution are also native arm64.
  echo "==> Patching pipeline-install-config for native arm64 driver/launcher ..."
  kubectl patch configmap pipeline-install-config -n kubeflow --type merge -p \
    "{\"data\":{
      \"driverImage\":\"${ORG}/kfp-driver:${PIPELINE_VERSION}-arm64\",
      \"launcherImage\":\"${ORG}/kfp-launcher:${PIPELINE_VERSION}-arm64\"
    }}"
  echo "    driverImage  → ${ORG}/kfp-driver:${PIPELINE_VERSION}-arm64"
  echo "    launcherImage→ ${ORG}/kfp-launcher:${PIPELINE_VERSION}-arm64"
  # Restart api-server so it picks up the updated ConfigMap
  kubectl rollout restart deployment/ml-pipeline -n kubeflow
fi
