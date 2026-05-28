#!/usr/bin/env bash
set -euo pipefail

PIPELINE_VERSION="${PIPELINE_VERSION:-2.16.1}"

echo "==> Installing cluster-scoped resources (CRDs, ClusterRoles) ..."
kubectl apply -k \
  "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=${PIPELINE_VERSION}"

echo "==> Waiting for applications.app.k8s.io CRD ..."
kubectl wait --for condition=established --timeout=60s crd/applications.app.k8s.io

echo "==> Installing Kubeflow Pipelines (env/dev) into kubeflow namespace ..."
kubectl apply -k \
  "github.com/kubeflow/pipelines/manifests/kustomize/env/dev?ref=${PIPELINE_VERSION}"

# Three components are not arm64-compatible and are removed post-apply:
#
#   controller-manager  gcr.io/ml-pipeline/application-crd-controller — manages
#                       the Application CRD (display only, not needed for pipelines)
#
#   metadata-grpc-deployment  gcr.io/tfx-oss-public/ml_metadata_store_server — C++
#                             binary that crashes under QEMU on arm64
#
#   metadata-writer     ghcr.io/kubeflow/kfp-metadata-writer — persistent
#                       ImagePullBackOff on arm64 DGX despite existing on GHCR
#
# Removing the MLMD stack (metadata-grpc + metadata-writer) means artifact lineage
# metadata won't be tracked, but pipeline execution is unaffected.
echo "==> Removing arm64-incompatible deployments (controller-manager, MLMD stack) ..."
kubectl delete deployment controller-manager metadata-grpc-deployment metadata-writer \
  -n kubeflow --ignore-not-found || true
