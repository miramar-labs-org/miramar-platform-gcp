#!/usr/bin/env bash
# Show status of all AGX user services.

SERVICES=(dashboard jupyterlab kubeflow-portfwd kfp-api-portfwd nsight-portfwd)

for svc in "${SERVICES[@]}"; do
    STATE=$(systemctl --user is-active "${svc}" 2>/dev/null || true)
    ENABLED=$(systemctl --user is-enabled "${svc}" 2>/dev/null || true)
    printf '  %-22s active=%-12s enabled=%s\n' "${svc}" "${STATE}" "${ENABLED}"
done

echo ""
systemctl --user status "${SERVICES[@]}" --no-pager --lines=0 2>&1 || true
