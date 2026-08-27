#!/usr/bin/env bash
set -euo pipefail

# Gracefully stop every DGX service, in dependency order, then power off the host.
# Run this directly on the DGX (spark-79b7.local) as the service-owning user.
#
# Order:
#   1. Pre-flight warnings (in-flight GHA jobs, running KFP/Argo workflows, active GPU procs)
#   2. mlabs-runner            (deregisters from GitHub before anything else stops)
#   3. user portfwd/UI services, reverse dependency order -- same list as uninstall.sh
#   4. k3s                     (system service -- cleanly terminates all pods: NeMo, MinIO,
#                                Qdrant, Postgres, KFP, NIM, any project workloads, etc.)
#   5. ollama                  (system service, if active)
#   6. sudo shutdown -h now
#
# Usage:
#   ./shutdown.sh            interactive: shows warnings, asks to type SHUTDOWN to confirm
#   ./shutdown.sh --dry-run  show what would happen; stops nothing, does not power off
#   ./shutdown.sh --yes      skip the typed confirmation (pre-flight warnings still print)

DRY_RUN=false
SKIP_CONFIRM=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --yes|-y)  SKIP_CONFIRM=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        echo "  + $*"
        "$@"
    fi
}

echo "=== Pre-flight checks ==="

if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_PROCS=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null || true)
    if [[ -n "$GPU_PROCS" ]]; then
        echo "WARNING: active GPU compute processes (shutting down will kill these):"
        echo "$GPU_PROCS" | sed 's/^/  /'
    else
        echo "No active GPU compute processes."
    fi
fi

if command -v kubectl >/dev/null 2>&1; then
    RUNNING_WF=$(kubectl get workflows.argoproj.io -A --field-selector status.phase=Running --no-headers 2>/dev/null || true)
    if [[ -n "$RUNNING_WF" ]]; then
        echo "WARNING: KFP/Argo workflows still running (a mid-pipeline stop loses that run's progress):"
        echo "$RUNNING_WF" | sed 's/^/  /'
    else
        echo "No running KFP/Argo workflows."
    fi
fi

if systemctl --user is-active --quiet mlabs-runner 2>/dev/null; then
    echo "mlabs-runner is active. If a workflow is currently executing on this runner,"
    echo "stopping it now will interrupt that job. Check org runner status from your laptop:"
    echo "  gh api orgs/miramar-labs-org/actions/runners --jq '.runners[] | select(.name==\"spark-79b7\")'"
fi

echo ""
echo "=== This will stop, in order ==="
echo "  1. mlabs-runner        (deregisters from GitHub)"
echo "  2. openwebui-portfwd, nsight-portfwd, postgres-portfwd, qdrant-portfwd,"
echo "     nemo-portfwd, kfp-api-portfwd, kubeflow-portfwd, mlflow-portfwd,"
echo "     jupyterlab, dashboard   (port-forward / UI user services)"
echo "  3. k3s                 (system service -- terminates all pods)"
echo "  4. ollama               (system service, if active)"
echo "  5. sudo shutdown -h now"
echo ""

if ! $SKIP_CONFIRM && ! $DRY_RUN; then
    read -r -p "Type SHUTDOWN to proceed: " CONFIRM
    [[ "$CONFIRM" == "SHUTDOWN" ]] || { echo "Aborted."; exit 1; }
fi

# Cache sudo credentials up front so the k3s/ollama/shutdown steps below don't stall
# mid-sequence waiting on a password prompt.
$DRY_RUN || sudo -v

echo ""
echo "=== Stopping user services ==="
run systemctl --user stop mlabs-runner

# Reverse dependency order -- same list as uninstall.sh, minus mlabs-runner (stopped above first
# so the runner deregisters before its dependencies, e.g. kubectl/helm reachability, go away).
USER_SERVICES=(openwebui-portfwd nsight-portfwd postgres-portfwd qdrant-portfwd nemo-portfwd kfp-api-portfwd kubeflow-portfwd mlflow-portfwd jupyterlab dashboard)
for svc in "${USER_SERVICES[@]}"; do
    run systemctl --user stop "${svc}"
done

echo ""
echo "=== Stopping k3s ==="
run sudo systemctl stop k3s

echo ""
echo "=== Stopping ollama ==="
if systemctl is-active --quiet ollama 2>/dev/null; then
    run sudo systemctl stop ollama
else
    echo "ollama not active, skipping."
fi

echo ""
if $DRY_RUN; then
    echo "Dry run complete -- nothing was stopped, host was not powered off."
else
    echo "All services stopped. Powering off in 5 seconds (Ctrl-C to abort)..."
    sleep 5
    sudo shutdown -h now
fi
