#!/usr/bin/env bash

set -euo pipefail

log() { echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }

# Parse arguments
UNINSTALL_DEPS=false
for arg in "$@"; do
  case "$arg" in
    --uninstall-deps)
      UNINSTALL_DEPS=true
      shift
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --uninstall-deps    Uninstall all dependencies (jq, yq, kubectl, helm, minikube, huggingface_hub)"
      echo "  --help              Show this help message"
      exit 0
      ;;
  esac
done

# Helper function to run commands with sudo if needed
maybe_sudo() {
  if [[ $EUID -ne 0 ]]; then
    sudo "$@"
  else
    "$@"
  fi
}

echo ""
log "🧹 Starting NeMo Microservices cleanup..."
echo ""

# 1. Delete Minikube cluster
log "Deleting Minikube cluster..."
if minikube delete 2>/dev/null; then
  log "✓ Minikube cluster deleted successfully"
else
  warn "Minikube cluster may not exist or already deleted"
fi

# 2. Clean up /etc/hosts entries
log "Cleaning up /etc/hosts entries..."
if grep -q "nim.test\|data-store.test\|nemo.test" /etc/hosts 2>/dev/null; then
  log "Removing NeMo-related DNS entries from /etc/hosts..."
  maybe_sudo sed -i.cleanup '/nim.test/d' /etc/hosts 2>/dev/null || true
  maybe_sudo sed -i.cleanup '/data-store.test/d' /etc/hosts 2>/dev/null || true
  maybe_sudo sed -i.cleanup '/nemo.test/d' /etc/hosts 2>/dev/null || true
  maybe_sudo sed -i.cleanup '/# Added by NeMo setup script/d' /etc/hosts 2>/dev/null || true
  maybe_sudo rm -f /etc/hosts.cleanup 2>/dev/null || true
  log "✓ DNS entries removed"
else
  log "No DNS entries found in /etc/hosts"
fi

# 3. Remove /etc/hosts backups created by setup script
log "Removing /etc/hosts backup files..."
backup_count=$(maybe_sudo find /etc -name "hosts.backup.*" 2>/dev/null | wc -l)
if [[ $backup_count -gt 0 ]]; then
  maybe_sudo find /etc -maxdepth 1 -name "hosts.backup.*" -delete 2>/dev/null || true
  log "✓ Removed $backup_count backup file(s)"
else
  log "No backup files found"
fi

# 4. Delete local helm chart files
log "Deleting local files..."
removed_items=0
if [[ -d "./nemo-microservices-helm-chart" ]]; then
  rm -rf ./nemo-microservices-helm-chart
  ((removed_items++))
fi
if ls nemo-microservices-helm-chart*.tgz 1>/dev/null 2>&1; then
  rm -rf ./nemo-microservices-helm-chart*.tgz
  ((removed_items++))
fi
if [[ $removed_items -gt 0 ]]; then
  log "✓ Removed $removed_items local file(s)/directory(ies)"
else
  log "No local files to remove"
fi

# 5. Remove temporary values files
if ls /tmp/nemo-ea-services-*.yaml 1>/dev/null 2>&1; then
  rm -f /tmp/nemo-ea-services-*.yaml
  log "✓ Removed temporary values files"
fi

# 6. Uninstall dependencies if requested
if [[ "$UNINSTALL_DEPS" == "true" ]]; then
  echo ""
  log "Uninstalling dependencies..."
  
  # Detect OS
  if [[ "$OSTYPE" == "darwin"* ]]; then
    os_type="macos"
  elif [[ -f /etc/debian_version ]]; then
    os_type="debian"
  elif [[ -f /etc/redhat-release ]]; then
    os_type="rhel"
  else
    os_type="unknown"
  fi
  
  # Uninstall huggingface_hub
  if python3 -c "import huggingface_hub" 2>/dev/null; then
    log "Uninstalling huggingface_hub..."
    pip uninstall -y huggingface_hub 2>/dev/null || warn "Failed to uninstall huggingface_hub"
  fi
  
  # Uninstall minikube
  if command -v minikube >/dev/null 2>&1; then
    log "Uninstalling minikube..."
    maybe_sudo rm -f /usr/local/bin/minikube 2>/dev/null || warn "Failed to uninstall minikube"
  fi
  
  # Uninstall helm
  if command -v helm >/dev/null 2>&1; then
    log "Uninstalling helm..."
    case "$os_type" in
      macos)
        brew uninstall helm 2>/dev/null || warn "Failed to uninstall helm"
        ;;
      debian)
        sudo snap remove helm 2>/dev/null || warn "Failed to uninstall helm"
        ;;
      *)
        maybe_sudo rm -f /usr/local/bin/helm 2>/dev/null || warn "Failed to uninstall helm"
        ;;
    esac
  fi
  
  # Uninstall kubectl
  if command -v kubectl >/dev/null 2>&1; then
    log "Uninstalling kubectl..."
    case "$os_type" in
      macos)
        brew uninstall kubectl 2>/dev/null || warn "Failed to uninstall kubectl"
        ;;
      debian)
        sudo snap remove kubectl 2>/dev/null || warn "Failed to uninstall kubectl"
        ;;
      *)
        maybe_sudo rm -f /usr/local/bin/kubectl 2>/dev/null || warn "Failed to uninstall kubectl"
        ;;
    esac
  fi
  
  # Uninstall yq
  if command -v yq >/dev/null 2>&1; then
    log "Uninstalling yq..."
    case "$os_type" in
      macos)
        brew uninstall yq 2>/dev/null || warn "Failed to uninstall yq"
        ;;
      debian)
        sudo snap remove yq 2>/dev/null || warn "Failed to uninstall yq"
        ;;
      *)
        maybe_sudo rm -f /usr/local/bin/yq 2>/dev/null || warn "Failed to uninstall yq"
        ;;
    esac
  fi
  
  # Uninstall jq
  if command -v jq >/dev/null 2>&1; then
    log "Uninstalling jq..."
    case "$os_type" in
      macos)
        brew uninstall jq 2>/dev/null || warn "Failed to uninstall jq"
        ;;
      debian)
        sudo apt-get remove -y jq 2>/dev/null || warn "Failed to uninstall jq"
        ;;
      rhel)
        sudo yum remove -y jq 2>/dev/null || warn "Failed to uninstall jq"
        ;;
    esac
  fi
  
  log "✓ Dependencies uninstalled"
  warn "Note: docker was NOT uninstalled as it may be used by other services"
fi

echo ""
log "✅ Cleanup complete! Environment is ready for fresh deployment."
echo ""
