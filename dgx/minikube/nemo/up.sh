#!/usr/bin/env bash
set -euo pipefail

TIMEOUT="180s"

# Wait for all pods matching a selector in a namespace to be Ready
wait_pods_ready() {
  local ns="$1"
  local selector="$2"
  local timeout="${3:-$TIMEOUT}"

  echo "==> Waiting for pods in namespace '$ns' selector '$selector' to be Ready (timeout $timeout)..."

  # Ensure at least one pod exists (helps catch wrong ns/selector)
  if ! kubectl -n "$ns" get pods -l "$selector" --no-headers 2>/dev/null | grep -q .; then
    echo "ERROR: No pods found in namespace '$ns' with selector '$selector'"
    kubectl -n "$ns" get pods -o wide || true
    return 1
  fi

  kubectl -n "$ns" wait --for=condition=Ready pod -l "$selector" --timeout="$timeout"

  echo "==> Ready: $ns / $selector"
}

# is minikube running?
state="$(minikube status --format='{{.Host}}' 2>/dev/null || true)"

if [[ "$state" != "Running" ]]; then
  minikube start
fi

NS="kubernetes-dashboard"

echo "Waiting for Kubernetes node to be Ready..."
# Wait for the (single) minikube node to report Ready
kubectl wait --for=condition=Ready node/minikube --timeout="$TIMEOUT" \
  || kubectl wait --for=condition=Ready node -l kubernetes.io/hostname=minikube --timeout="$TIMEOUT"

echo "Ensuring dashboard addon is enabled..."
minikube addons enable dashboard >/dev/null 2>&1 || true

echo "Waiting for dashboard deployment to exist..."
deadline=$((SECONDS+180))
until kubectl -n "$NS" get deploy kubernetes-dashboard >/dev/null 2>&1; do
  (( SECONDS < deadline )) || { echo "ERROR: dashboard deployment not found after 180s"; exit 1; }
  sleep 2
done

echo "Waiting for dashboard rollout + pods Ready..."
kubectl -n "$NS" rollout status deploy/kubernetes-dashboard --timeout="$TIMEOUT"
kubectl -n "$NS" wait --for=condition=Ready pod -l k8s-app=kubernetes-dashboard --timeout="$TIMEOUT"

echo "Dashboard is up."

echo "==> Waiting for MLflow/MinIO pods..."
wait_pods_ready "mlflow-system" "app=mlflow" "300s"
wait_pods_ready "mlflow-system" "app=minio" "300s"

pushd systemd
source restart-services.sh
popd 

# If you also deploy Postgres/MinIO via the chart and want to wait for them too,
# uncomment/add selectors that match your install:
# wait_pods_ready "mlflow-system" "app.kubernetes.io/name=postgresql" "300s"
# wait_pods_ready "mlflow-system" "app.kubernetes.io/name=minio" "300s"


