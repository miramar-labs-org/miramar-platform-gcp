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
