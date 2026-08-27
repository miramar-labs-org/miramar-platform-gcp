#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-default}"
POD="${POD:-gpu-schedule-test}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"   # total time to wait for completion
IMAGE="${IMAGE:-nvidia/cuda:12.3.2-base-ubuntu22.04}"

cleanup() {
  kubectl delete pod -n "$NS" "$POD" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "==> Checking node allocatable GPUs..."
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\tallocatable GPUs="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' || true
echo

if ! kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null | grep -Eq '[1-9]'; then
  echo "ERROR: No node reports allocatable nvidia.com/gpu. GPU scheduling will not work." >&2
  exit 1
fi

echo "==> Checking NVIDIA device plugin (best effort)..."
kubectl get ds -A | grep -Ei 'nvidia.*device.*plugin' || true
kubectl get pods -A -o wide | grep -Ei 'nvidia.*device.*plugin' || true
echo

echo "==> Creating test pod that requests 1 GPU and runs nvidia-smi..."
cat <<YAML | kubectl apply -n "$NS" -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
spec:
  restartPolicy: Never
  containers:
    - name: nvidia-smi
      image: ${IMAGE}
      command: ["bash","-lc","nvidia-smi && echo 'GPU request worked'"]
      resources:
        limits:
          nvidia.com/gpu: "1"
YAML

echo "==> Waiting for pod to be scheduled..."
end_sched=$((SECONDS + 60))
while (( SECONDS < end_sched )); do
  node="$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  phase="$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "  phase=${phase:-?} node=${node:-<none>}"
  if [[ -n "${node:-}" ]]; then
    break
  fi
  sleep 2
done

node="$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
if [[ -z "${node:-}" ]]; then
  echo "ERROR: Pod never got scheduled (still Pending)." >&2
  kubectl describe pod -n "$NS" "$POD" || true
  exit 2
fi

echo "==> Waiting for pod to complete (Succeeded or Failed)..."
end=$((SECONDS + TIMEOUT_SECONDS))
phase=""
while (( SECONDS < end )); do
  phase="$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
    break
  fi
  sleep 2
done

echo
echo "---- pod status ----"
kubectl get pod -n "$NS" "$POD" -o wide || true

echo
echo "---- logs ----"
kubectl logs -n "$NS" "$POD" || true

echo
if [[ "$phase" == "Succeeded" ]]; then
  echo "✅ PASS: GPU scheduling + runtime worked (pod requested GPU and ran nvidia-smi)."
  exit 0
elif [[ "$phase" == "Failed" ]]; then
  echo "❌ FAIL: Pod failed. Events:"
  kubectl describe pod -n "$NS" "$POD" | sed -n '/Events:/,$p' || true
  exit 3
else
  echo "❌ FAIL: Timed out waiting for pod to complete (last phase: ${phase:-<unknown>})."
  echo "Describe:"
  kubectl describe pod -n "$NS" "$POD" || true
  exit 4
fi
