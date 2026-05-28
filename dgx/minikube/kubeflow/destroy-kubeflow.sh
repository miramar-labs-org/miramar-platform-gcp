#!/usr/bin/env bash
set -euo pipefail

PIPELINE_VERSION="${PIPELINE_VERSION:-2.5.0}"
DELETE_NS="${DELETE_NS:-true}"

echo "==> Removing Kubeflow Pipelines namespace resources ..."
kubectl delete -k \
  "github.com/kubeflow/pipelines/manifests/kustomize/env/dev?ref=${PIPELINE_VERSION}" \
  --ignore-not-found || true

echo "==> Removing cluster-scoped resources (CRDs, ClusterRoles) ..."
kubectl delete -k \
  "github.com/kubeflow/pipelines/manifests/kustomize/cluster-scoped-resources?ref=${PIPELINE_VERSION}" \
  --ignore-not-found || true

if [[ "${DELETE_NS}" == "true" ]]; then
  echo "==> Deleting kubeflow namespace ..."
  kubectl delete namespace kubeflow --ignore-not-found || true
fi
