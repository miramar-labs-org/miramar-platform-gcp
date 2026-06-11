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

# ---- Configure NVIDIA container runtime for containerd ----
# k3s uses its own containerd instance at /var/lib/rancher/k3s/agent/etc/containerd/config.toml
log "Configuring NVIDIA container runtime for k3s containerd..."
CONTAINERD_CFG=/var/lib/rancher/k3s/agent/etc/containerd/config.toml
if [[ -f "$CONTAINERD_CFG" ]]; then
  sudo nvidia-ctk runtime configure --runtime=containerd --config="$CONTAINERD_CFG"
  sudo systemctl restart k3s
  log "NVIDIA runtime configured; k3s restarted."
else
  log "containerd config not found at ${CONTAINERD_CFG} — skipping (will apply after first k3s start)."
fi

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
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || echo "${SCRIPT_DIR}/../..")"
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
log "Patching CoreDNS to resolve host.k3s.internal..."
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
export NODE_IP
envsubst < "${REPO_ROOT}/dgx/k3s/coredns-custom.yaml" | kubectl apply -f -
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=60s

log "k3s install complete."
log "Node IP: ${NODE_IP} — host.k3s.internal resolves to this address inside pods"
kubectl get nodes -o wide
