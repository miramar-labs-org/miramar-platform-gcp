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

# Three components cannot run on arm64 DGX and are removed post-apply:
#
#   controller-manager        gcr.io/ml-pipeline/application-crd-controller
#                             amd64-only binary; manages the Application CRD for
#                             display purposes only — unneeded for pipeline execution.
#
#   metadata-grpc-deployment  gcr.io/tfx-oss-public/ml_metadata_store_server
#                             amd64-only C++ binary; crashes under QEMU. A deployKF
#                             arm64 community build exists (v1.14.0-deploykf.0) but
#                             the Python client (ml-metadata==1.17.0) has no arm64
#                             PyPI wheel, blocking kfp-metadata-writer too.
#
#   metadata-writer           ghcr.io/kubeflow/kfp-metadata-writer
#                             Upstream explicitly excludes arm64 from CI. Depends on
#                             ml-metadata==1.17.0 which has no aarch64 wheel on PyPI
#                             and no sdist — building from source requires Bazel.
#
# Impact: artifact lineage metadata (MLMD) is not tracked. The full pipeline
# execution stack (API server, UI, scheduler, SeaweedFS, MySQL, Argo) runs normally.
echo "==> Removing arm64-incompatible deployments (controller-manager, MLMD stack) ..."
kubectl delete deployment controller-manager metadata-grpc-deployment metadata-writer \
  -n kubeflow --ignore-not-found || true
