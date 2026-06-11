#!/usr/bin/env bash
set -euo pipefail

# Installs k3s on the host and configures it for GPU workloads:
#   - Disables Traefik (replaced by nginx-ingress) and local-storage (use explicit hostPath PVs)
#   - Configures NVIDIA container runtime for containerd
#   - Copies kubeconfig to ~/.kube/config
#   - Waits for node ready
#   - Patches CoreDNS ConfigMap to resolve host.k3s.internal → node IP
#   - Applies NVIDIA device plugin DaemonSet (pinned v0.18.0, arm64)
#   - Deploys nginx-ingress controller (matches existing NeMo/NIM ingress YAML)
#
# Idempotent: safe to re-run. Skips install if k3s binary already present.

log() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }

# ---- Install k3s ----
if [[ -x /usr/local/bin/k3s ]]; then
  log "k3s already installed: $(k3s --version | head -1)"
else
  log "Installing k3s (disable Traefik + local-storage)..."
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik --disable=local-storage" sh -
  log "k3s installed: $(k3s --version | head -1)"
fi

# ---- Install helm ----
if command -v helm &>/dev/null; then
  log "helm already installed: $(helm version --short)"
else
  log "Installing helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  log "helm installed: $(helm version --short)"
fi

# ---- Configure NVIDIA container runtime for containerd ----
# nvidia-ctk v1.19+ writes to /etc/containerd/conf.d/99-nvidia.toml (ignores --config flag).
# k3s reads this at startup and merges it into its generated config.toml automatically.
log "Configuring NVIDIA container runtime..."
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart k3s
log "NVIDIA runtime configured; k3s restarted."

# ---- Kubeconfig ----
log "Setting up kubeconfig..."
mkdir -p "${HOME}/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"
export KUBECONFIG="${HOME}/.kube/config"

# ---- Wait for node ready ----
log "Waiting for node to become Ready..."
kubectl wait node --all --for=condition=Ready --timeout=120s
kubectl get nodes -o wide

# ---- NVIDIA device plugin (v0.18.0, GB10 / Spark fix) ----
log "Applying NVIDIA device plugin v0.18.0..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# REPO_ROOT can be pre-set by the caller (e.g. bootstrap-k3s.yaml SSHes files to /tmp).
REPO_ROOT="${REPO_ROOT:-$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}/../..")}"
kubectl apply -f "${REPO_ROOT}/dgx/k3s/nvidia-device-plugin.yaml"

# ---- Label node for GPU scheduling ----
log "Labeling node for NVIDIA GPU scheduling..."
kubectl label node "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" \
  feature.node.kubernetes.io/pci-10de.present=true --overwrite

# ---- nginx-ingress controller ----
# Use baremetal NodePort manifest — right choice for k3s single-node (no cloud LB).
# Pinned to v1.10.1 (stable arm64 image exists at this tag).
NGINX_INGRESS_VERSION="v1.10.1"
NGINX_INGRESS_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${NGINX_INGRESS_VERSION}/deploy/static/provider/baremetal/deploy.yaml"
log "Deploying nginx-ingress controller ${NGINX_INGRESS_VERSION} (baremetal NodePort)..."
kubectl apply -f "${NGINX_INGRESS_URL}"
log "Waiting for nginx-ingress controller to be ready (up to 3m)..."
kubectl rollout status deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=180s || log "nginx-ingress not yet ready — may still be pulling image"

# ---- CoreDNS patch: host.k3s.internal → node IP ----
# k3s CoreDNS already uses a 'hosts' plugin for NodeHosts — adding a second hosts
# block via ConfigMap extension crashes CoreDNS. Instead, append to NodeHosts directly.
log "Patching CoreDNS to resolve host.k3s.internal..."
NODE_IP=$(python3 -c "
import subprocess, json
out = subprocess.check_output(['kubectl','get','node','-o','json']).decode()
addrs = json.loads(out)['items'][0]['status']['addresses']
print(next(a['address'] for a in addrs if a['type']=='InternalIP' and '.' in a['address']))
")
CURRENT=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.NodeHosts}')
PATCHED=$(printf '%s\n' "$CURRENT" | grep -v 'host\.k3s\.internal'; printf '%s host.k3s.internal\n' "$NODE_IP")
PATCHED_JSON=$(printf '%s' "$PATCHED" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
kubectl patch configmap coredns -n kube-system --type merge \
  -p "{\"data\":{\"NodeHosts\":${PATCHED_JSON}}}"
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=60s

# ---- Kubernetes Dashboard ----
K8S_DASHBOARD_VERSION="v2.7.0"
K8S_DASHBOARD_URL="https://raw.githubusercontent.com/kubernetes/dashboard/${K8S_DASHBOARD_VERSION}/aio/deploy/recommended.yaml"
log "Deploying Kubernetes Dashboard ${K8S_DASHBOARD_VERSION}..."
kubectl apply -f "${K8S_DASHBOARD_URL}"
# Grant cluster-admin to both the dashboard SA (for skip-login) and an explicit admin-user
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubernetes-dashboard-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: kubernetes-dashboard
    namespace: kubernetes-dashboard
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: admin-user
    namespace: kubernetes-dashboard
EOF
# Enable skip-login so the dashboard can be accessed without a token
kubectl -n kubernetes-dashboard patch deployment kubernetes-dashboard --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-skip-login"}]'
log "Dashboard deployed at port 8001 (skip-login enabled)."
log "URL: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"

log "k3s install complete."
log "Node IP: ${NODE_IP} — host.k3s.internal resolves to this address inside pods"
kubectl get nodes -o wide
