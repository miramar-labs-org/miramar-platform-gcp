#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# === Debug Settings ===
# Show exit codes and command context for all failures
trap 'echo "Error on line $LINENO: Command failed with exit code $?" >&2' ERR
# Print each command before execution
PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
#set -x

# === Config ===
NAMESPACE="default"
REQUIRED_DISK_GB=200
REQUIRED_GPUS=1
NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
HF_TOKEN="${HF_TOKEN:-}"
ADDITIONAL_VALUES_FILES=()
HELM_CHART_URL=""
HELM_CHART_VERSION=""
FORCE_MODE=false
INSTALL_DEPS=false
CHECK_DEPS_ONLY=false
VERBOSE_MODE=false
ENABLE_SAFE_SYNTHESIZER=false
ENABLE_AUDITOR=false

# Prevent "unbound variable" when referenced before populated
helm_args=()

# === Utility ===
# NOTE: Use %b (not %s) so embedded \n sequences render as real newlines.
log() { printf "\033[1;32m[INFO]\033[0m %b\n" "$*"; }
warn() { printf "\033[1;33m[WARN]\033[0m %b\n" "$*"; }
err() { printf "\033[1;31m[ERROR]\033[0m %b\n" "$*" >&2; }
suggest_fix() { printf "\033[1;36m[SUGGESTION]\033[0m %b\n" "$*"; }
die() {
  show_help
  err "$*"
  echo
  exit 1
}

# Toggle xtrace around noisy assignments so verbose mode doesn't show $'...\n...' blobs
_xtrace_push() { __XTRACE_WAS_ON=0; case "$-" in *x*) __XTRACE_WAS_ON=1; set +x ;; esac; }
_xtrace_pop()  { (( ${__XTRACE_WAS_ON:-0} )) && set -x; unset __XTRACE_WAS_ON; }

# Filter out known harmless Kubernetes warnings
filter_k8s_warnings() {
  grep -v 'unrecognized format.*int32' |
  grep -v 'unrecognized format.*int64' |
  grep -v 'spec.SessionAffinity is ignored for headless services' |
  grep -v 'duplicate port name.*http'
}

# Detect OS (Debian/Ubuntu only)
detect_os() {
  if [[ -f /etc/debian_version ]]; then
    echo "debian"
  else
    echo "unknown"
  fi
}

is_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]]
}

# Preflight check if user has sudo access
check_sudo_access() {
  if is_root; then
    log "Running as root, no sudo required."
    return 0
  fi

  log "Checking sudo access"

  if ! command -v sudo >/dev/null; then
    die "sudo is not available but required for modifying system host file to enable DNS resolution."
  fi

  log "Testing sudo access..."
  if sudo -n true 2>/dev/null; then
    log "Passwordless sudo access confirmed."
  elif sudo -v 2>/dev/null; then
    log "Sudo access confirmed (password required)."
  else
    die "sudo access test failed. User does not have sudo privileges, sudo is misconfigured, or no password is set for passwordless sudo."
  fi
  log "sudo access verified successfully."
}

# Run a command with sudo if not root
maybe_sudo() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

# Prompt user for confirmation (y/n)
confirm_action() {
  local message="$1"
  local default="${2:-n}" # Default to 'n' for safety

  if [[ "$FORCE_MODE" == "true" ]]; then
    log "Force mode enabled - automatically confirming: $message"
    return 0
  fi

  local prompt=""
  if [[ "$default" == "y" ]]; then
    prompt="$message [Y/n]: "
  else
    prompt="$message [y/N]: "
  fi

  while true; do
    local response=""
    read -r -p "$prompt" response
    case "${response:-$default}" in
      [yY] | [yY][eE][sS]) return 0 ;;
      [nN] | [nN][oO])     return 1 ;;
      *) echo "Please answer 'y' or 'n'." ;;
    esac
  done
}

show_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Setup and deploy NeMo microservices on Minikube.

Options:
  --helm-chart-url URL         Direct URL to helm chart tgz file (mutually exclusive with --helm-chart-version)
  --helm-chart-version V       Version number available in the chart repo index (mutually exclusive with --helm-chart-url)
                               If neither flag is specified, defaults to latest available version
  --values-file FILE           Path to a values file (can be specified multiple times)
  --enable-safe-synthesizer    Enable Safe Synthesizer (Early Access service)
  --enable-auditor             Enable Auditor (Early Access service)
  --check-deps                 Check dependencies and show installation status, then exit
  --install-deps               Automatically install missing dependencies (requires confirmation)
  --verbose                    Enable verbose output for debugging
  --force                      Skip all confirmation prompts for destructive actions (use with caution)
  --help                       Show this help message

Environment Variables:
  NVIDIA_API_KEY         NVIDIA API key for registry and API access
                         Get from: https://build.nvidia.com/
                         Can be set in environment or will be prompted if not set
  HF_TOKEN               HuggingFace token to download models for customization
                         Get from: https://huggingface.co/settings/tokens
                         Can be set in environment or will be prompted if not set

Requirements:
  - NVIDIA Container Toolkit v1.16.2 or higher
  - NVIDIA GPU Driver 560.35.03 or higher
  - At least $REQUIRED_GPUS A100 80GB, H100 80GB, GB10, RTX 6000, or RTX 5880 GPUs
  - At least $REQUIRED_DISK_GB GB free disk space
  - minikube v1.33.0 or higher
  - Docker v27.0.0 or higher
  - kubectl
  - helm
  - huggingface_hub (Python library)
  - jq
EOF
}

# === Argument Parsing ===
require_value() {
  local opt="$1"
  local val="${2:-}"
  [[ -n "$val" && "${val:0:1}" != "-" ]] || die "Missing value for $opt"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --helm-chart-url)
        require_value "$1" "${2:-}"
        HELM_CHART_URL="$2"
        shift 2
        ;;
      --helm-chart-version)
        require_value "$1" "${2:-}"
        HELM_CHART_VERSION="$2"
        shift 2
        ;;
      --values-file)
        require_value "$1" "${2:-}"
        ADDITIONAL_VALUES_FILES+=("$2")
        shift 2
        ;;
      --enable-safe-synthesizer)
        ENABLE_SAFE_SYNTHESIZER=true
        shift
        ;;
      --enable-auditor)
        ENABLE_AUDITOR=true
        shift
        ;;
      --check-deps)
        CHECK_DEPS_ONLY=true
        shift
        ;;
      --install-deps)
        INSTALL_DEPS=true
        shift
        ;;
      --verbose)
        VERBOSE_MODE=true
        set -x
        shift
        ;;
      --force)
        FORCE_MODE=true
        shift
        ;;
      --help)
        show_help
        exit 0
        ;;
      *)
        err "Unknown argument: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

# Validate arguments
validate_args() {
  if [[ -n "$HELM_CHART_URL" && -n "$HELM_CHART_VERSION" ]]; then
    die "Cannot specify both --helm-chart-url and --helm-chart-version. Use only one."
  fi

  if [[ -z "$HELM_CHART_URL" && -z "$HELM_CHART_VERSION" ]]; then
    log "No chart source specified, defaulting to latest available chart version from repo..."
    HELM_CHART_VERSION="latest"
  fi

  if [[ "$ENABLE_SAFE_SYNTHESIZER" == "true" || "$ENABLE_AUDITOR" == "true" ]]; then
    local ea_values_file="/tmp/nemo-ea-services-$$.yaml"
    log "Early Access services requested, creating values file..."

    cat > "$ea_values_file" <<EOF
tags:
EOF

    if [[ "$ENABLE_SAFE_SYNTHESIZER" == "true" ]]; then
      echo "  safe-synthesizer: true" >> "$ea_values_file"
      log "  • Safe Synthesizer: enabled"
    fi
    if [[ "$ENABLE_AUDITOR" == "true" ]]; then
      echo "  auditor: true" >> "$ea_values_file"
      log "  • Auditor: enabled"
    fi

    ADDITIONAL_VALUES_FILES+=("$ea_values_file")
  fi

  if [[ ${#ADDITIONAL_VALUES_FILES[@]} -gt 0 ]]; then
    log "Using ${#ADDITIONAL_VALUES_FILES[@]} values file(s) for deployment configuration."
  else
    log "No custom values files specified. Using chart defaults for minikube deployment."
  fi

  if [[ "$FORCE_MODE" == "true" ]]; then
    log "Force mode enabled - all confirmation prompts will be skipped"
  fi
  if [[ "$VERBOSE_MODE" == "true" ]]; then
    log "Verbose mode enabled - detailed command output will be shown"
  fi
}

# === Diagnostic Functions ===
collect_pod_diagnostics() {
  local pod=$1
  local namespace=$2
  local err_dir=$3
  local pod_dir="$err_dir/$pod"

  mkdir -p "$pod_dir"

  log "Collecting logs for pod $pod..."
  kubectl logs --all-containers "$pod" -n "$namespace" >"$pod_dir/logs.txt" 2>&1 || true
  kubectl logs --all-containers "$pod" -n "$namespace" --previous >"$pod_dir/logs.previous.txt" 2>&1 || true

  log "Collecting pod description for $pod..."
  kubectl describe pod "$pod" -n "$namespace" >"$pod_dir/describe.txt" 2>&1 || true

  log "Collecting events for pod $pod..."
  kubectl get events --field-selector involvedObject.name="$pod" -n "$namespace" >"$pod_dir/events.txt" 2>&1 || true

  if kubectl describe pod "$pod" -n "$namespace" | grep -q "ImagePullBackOff\|ErrImagePull"; then
    log "Detected image pull issues for pod $pod"
    kubectl describe pod "$pod" -n "$namespace" | grep -A 10 "ImagePullBackOff\|ErrImagePull" >"$pod_dir/image_pull_issues.txt" 2>&1 || true
  fi

  log "Collecting container status for pod $pod..."
  kubectl get pod "$pod" -n "$namespace" -o json | jq '.status.containerStatuses' >"$pod_dir/container_status.json" 2>&1 || true
}

check_image_pull_secrets() {
  local namespace=$1
  log "Verifying image pull secrets..."

  if ! kubectl get secret nvcrimagepullsecret -n "$namespace" &>/dev/null; then
    err "Image pull secret 'nvcrimagepullsecret' not found in namespace $namespace"
    return 1
  fi

  if ! kubectl get secret nvcrimagepullsecret -n "$namespace" -o json | jq -e '.data[".dockerconfigjson"]' &>/dev/null; then
    err "Image pull secret 'nvcrimagepullsecret' is not properly configured"
    return 1
  fi

  log "Image pull secrets verified successfully"
  return 0
}

# === Dependency Management ===
check_dependency() {
  local cmd=$1
  local name=$2

  if command -v "$cmd" >/dev/null 2>&1; then
    echo "✓ $name"
    return 0
  else
    echo "✗ $name (missing)"
    return 1
  fi
}

show_install_instructions() {
  local os_type
  os_type="$(detect_os)"
  local dep="$1"

  if [[ "$os_type" != "debian" ]]; then
    echo "    Unsupported OS (this script supports Debian/Ubuntu only)"
    return 0
  fi

  case "$dep" in
    jq) echo "    sudo apt update && sudo apt install -y jq" ;;
    kubectl) echo "    sudo snap install kubectl --classic" ;;
    helm) echo "    sudo snap install helm --classic" ;;
    minikube) echo "    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm -f minikube-linux-amd64" ;;
    docker) echo "    curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker \$USER" ;;
    huggingface_hub) echo "    pip install --upgrade huggingface_hub" ;;
    *) echo "    Unknown dependency: $dep" ;;
  esac
}

install_dependency() {
  local dep="$1"
  local os_type
  os_type="$(detect_os)"

  if [[ "$os_type" != "debian" ]]; then
    err "Cannot auto-install '$dep' on this OS (Debian/Ubuntu only)"
    return 1
  fi

  log "Installing $dep..."

  case "$dep" in
    jq)
      sudo apt update
      sudo apt install -y jq
      ;;
    kubectl)
      sudo snap install kubectl --classic
      ;;
    helm)
      sudo snap install helm --classic
      ;;
    minikube)
      curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
      sudo install minikube-linux-amd64 /usr/local/bin/minikube
      rm -f minikube-linux-amd64
      ;;
    docker)
      curl -fsSL https://get.docker.com | sudo sh
      sudo usermod -aG docker "$USER"
      log "Docker installed. You may need to log out and back in for group changes to take effect"
      ;;
    huggingface_hub)
      pip install --upgrade huggingface_hub
      ;;
    *)
      err "Unknown dependency: $dep"
      return 1
      ;;
  esac
}

check_and_install_dependencies() {
  local missing_deps=()
  local os_type
  os_type="$(detect_os)"

  log "Checking dependencies..."
  echo ""

  check_dependency "jq" "jq" || missing_deps+=("jq")
  check_dependency "kubectl" "kubectl" || missing_deps+=("kubectl")
  check_dependency "helm" "helm" || missing_deps+=("helm")
  check_dependency "minikube" "minikube" || missing_deps+=("minikube")
  check_dependency "docker" "docker" || missing_deps+=("docker")

  if python3 -c "import huggingface_hub" 2>/dev/null; then
    echo "✓ huggingface_hub (Python library)"
  else
    echo "✗ huggingface_hub (missing)"
    missing_deps+=("huggingface_hub")
  fi

  echo ""

  if [[ "$CHECK_DEPS_ONLY" == "true" ]]; then
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
      log "✓ All dependencies are installed!"
      exit 0
    else
      warn "Missing ${#missing_deps[@]} dependencies"
      echo ""
      echo "To install missing dependencies on $os_type:"
      echo ""
      for dep in "${missing_deps[@]}"; do
        echo "  $dep:"
        show_install_instructions "$dep"
        echo ""
      done
      echo "Or run this script with --install-deps to install automatically."
      exit 1
    fi
  fi

  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    if [[ "$INSTALL_DEPS" == "true" ]]; then
      warn "Missing ${#missing_deps[@]} dependencies: ${missing_deps[*]}"

      if [[ "$FORCE_MODE" != "true" ]]; then
        if ! confirm_action "Install missing dependencies automatically?"; then
          err "Cannot proceed without required dependencies"
          echo ""
          echo "To install manually:"
          for dep in "${missing_deps[@]}"; do
            echo "  $dep:"
            show_install_instructions "$dep"
            echo ""
          done
          exit 1
        fi
      else
        log "Force mode enabled - installing dependencies without confirmation"
      fi

      for dep in "${missing_deps[@]}"; do
        if ! install_dependency "$dep"; then
          err "Failed to install $dep"
          suggest_fix "Please install $dep manually and try again"
          exit 1
        fi
      done

      log "All dependencies installed successfully!"
      export PATH="$HOME/.local/bin:/snap/bin:$PATH"
      log "Updated PATH to include newly installed tools"
    else
      err "Missing required dependencies: ${missing_deps[*]}"
      echo ""
      suggest_fix "Run with --check-deps to see installation instructions"
      suggest_fix "Or run with --install-deps to install automatically"
      exit 1
    fi
  else
    log "✓ All dependencies are installed"
  fi
}

# === Phase 0: Preflight Checks ===
check_prereqs() {
  log "Checking system requirements..."

  command -v jq >/dev/null || die "jq is required but not found"

  if command -v nvidia-ctk >/dev/null 2>&1; then
    local nvidia_ctk_version
    nvidia_ctk_version="$(nvidia-ctk --version 2>/dev/null | head -n1 | awk '{print $6}')"
    if [[ "$nvidia_ctk_version" == "0.0.0" ]]; then
      die "nvidia-ctk is installed but version check failed. Please ensure it's properly installed."
    fi
    if [[ "$(printf '%s\n' "1.16.2" "$nvidia_ctk_version" | sort -V | head -n1)" != "1.16.2" ]]; then
      warn "NVIDIA Container Toolkit v1.16.2 or higher is recommended. Found: $nvidia_ctk_version"
    fi
    log "NVIDIA Container Toolkit version: $nvidia_ctk_version"
  else
    die "nvidia-ctk is not installed. Please install it first."
  fi

  local nvidia_driver_version
  nvidia_driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)"
  if [[ "$(printf '%s\n' "560.35.03" "$nvidia_driver_version" | sort -V | head -n1)" != "560.35.03" ]]; then
    die "NVIDIA GPU Driver 560.35.03 or higher is required. Found: $nvidia_driver_version"
  fi

  local valid_gpus=0
  while IFS= read -r gpu; do
    log "Checking GPU: $gpu"
    if [[ "$gpu" == *"A100"*"80GB"* ]] || \
       [[ "$gpu" == *"H100"* ]] || \
       [[ "$gpu" == *"6000"* ]] || \
       [[ "$gpu" == *"5880"* ]] || \
       [[ "$gpu" == *"GB10"* ]] || \
       [[ "$gpu" == *"H200"* ]]; then
      log "Found valid GPU: $gpu"
      valid_gpus=$((valid_gpus + 1))
    fi
  done < <(nvidia-smi --query-gpu=name --format=csv,noheader)

  log "Total valid GPUs found: $valid_gpus"
  if ((valid_gpus < REQUIRED_GPUS)); then
    warn "At least $REQUIRED_GPUS A100 80GB, H100 80GB, RTX 6000, or RTX 5880 GPUs are required."
    warn "We could not confirm that you have the correct set of GPUs."
    warn "Found: $valid_gpus"
  fi

  local filesystem_type
  filesystem_type="$(df -T / | awk 'NR==2 {print $2}')"
  if [[ "$filesystem_type" != "ext4" ]]; then
    warn "Warning: Filesystem type is $filesystem_type. EXT4 is recommended for proper file locking support."
  fi

  local free_space_gb
  free_space_gb="$(df / | awk 'NR==2 {print int($4 / 1024 / 1024)}')"
  if ((free_space_gb < REQUIRED_DISK_GB)); then
    warn "Warning: Your root filesystem does not have enough free disk space."
    warn "Required: ${REQUIRED_DISK_GB} GB"
    df -kP
  fi

  command -v minikube >/dev/null || die 'minikube is required to be in $PATH but not found'
  command -v docker >/dev/null || die 'docker executable is required to be in $PATH but not found'

  local minikube_version
  minikube_version="$(minikube version --short 2>/dev/null | cut -d'v' -f2)"
  if [[ "$(printf '%s\n' "1.33.0" "$minikube_version" | sort -V | head -n1)" != "1.33.0" ]]; then
    die "minikube v1.33.0 or higher is required. Found: $minikube_version"
  fi

  local docker_version
  docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if [[ "$(printf '%s\n' "27.0.0" "$docker_version" | sort -V | head -n1)" != "27.0.0" ]]; then
    die "Docker v27.0.0 or higher is required. Found: $docker_version"
  fi

  docker ps >/dev/null 2>&1 || die "User does not have permission to run docker commands. Ensure 'docker ps' works."

  command -v kubectl >/dev/null || die "kubectl is required but not found"
  local kubectl_version
  kubectl_version="$(kubectl version --client -o json | jq -r '.clientVersion.gitVersion' | sed 's/^v//')"
  [[ -n "$kubectl_version" ]] || die "Could not determine kubectl version"

  command -v helm >/dev/null || die "helm is required but not found"
  local helm_version
  helm_version="$(helm version --template='{{.Version}}' | sed 's/^v//')"
  [[ -n "$helm_version" ]] || die "Could not determine helm version"

  if ! python3 -c "import huggingface_hub" 2>/dev/null; then
    err "huggingface_hub Python library is required but not found"
    suggest_fix "Install with: pip install --upgrade huggingface_hub"
    suggest_fix "Or run with: ./$(basename "$0") --install-deps"
    exit 1
  fi

  log "All prerequisites are met."
}

# === Phase 1: Minikube Setup ===
start_minikube() {
  log "Checking Minikube status..."
  if minikube status &>/dev/null; then
    log "Minikube is already running. Checking for existing NMP deployment..."

    if helm list -n "$NAMESPACE" | grep -q "nemo"; then
      log "Found existing 'nemo' helm release. Performing complete cleanup..."

      if confirm_action "Remove existing 'nemo' helm release?"; then
        log "Removing existing 'nemo' helm release..."
      else
        die "Existing 'nemo' helm release found and must be removed before continuing."
      fi

      log "Cleaning up NIM services..."
      kubectl delete nimservice --all -n "$NAMESPACE" --ignore-not-found=true || warn "Failed to delete some NIM services"

      log "Cleaning up NIM caches..."
      kubectl delete nimcache --all -n "$NAMESPACE" --ignore-not-found=true || warn "Failed to delete some NIM caches"

      log "Cleaning up model deployment configmaps..."
      kubectl delete configmap -n "$NAMESPACE" -l "app.nvidia.com/config-type=modelDeployment" --ignore-not-found=true || warn "Failed to delete some model deployment configmaps"

      log "Cleaning up CRDs..."
      kubectl get crd -o name | grep "nvidia.com" | xargs -I {} kubectl delete {} --ignore-not-found=true || warn "Failed to delete some CRDs"

      sleep 5

      log "Uninstalling existing 'nemo' helm release..."
      helm uninstall nemo -n "$NAMESPACE" || warn "Failed to uninstall existing nemo release, but continuing..."

      sleep 10
    else
      log "No existing 'nemo' helm release found. Continuing with existing minikube cluster."
    fi

    addon_enabled() {
      local a="$1"
      minikube addons list 2>/dev/null | awk -v addon="$a" '$1==addon {print $2}' | grep -qi '^enabled$'
    }
    ensure_addon() {
      local a="$1"
      if addon_enabled "$a"; then
        log "$a addon already enabled."
      else
        log "Enabling $a addon..."
        minikube addons enable "$a"
      fi
    }

    ensure_addon ingress
    ensure_addon dashboard
    ensure_addon metrics-server

    if ! kubectl get node minikube -o jsonpath='{.metadata.labels.feature\.node\.kubernetes\.io/pci-10de\.present}' | grep -q "true"; then
      log "Labeling minikube node with NVIDIA GPU label..."
      kubectl label node minikube feature.node.kubernetes.io/pci-10de.present=true --overwrite
    else
      log "GPU label already set on minikube node."
    fi

    log "Using existing minikube cluster."
    return 0
  fi

  log "Starting Minikube with GPU support..."

  local extra_args=()
  if is_root; then
    extra_args+=(--force)
    log "Running as root, adding --force flag to minikube command"
  fi

  minikube start \
    --driver=docker \
    --container-runtime=docker \
    --cpus=no-limit \
    --memory=no-limit \
    --gpus=all \
    "${extra_args[@]}"

  log "Pinning nvidia-device-plugin addon to spark-dgx compatible version..."
  minikube addons disable nvidia-device-plugin
  minikube addons enable nvidia-device-plugin \
    --images="NvidiaDevicePlugin=nvidia/k8s-device-plugin:v0.18.0" \
    --registries="NvidiaDevicePlugin=nvcr.io"

  log "Enabling ingress addon..."
  minikube addons enable ingress

  log "Enabling dashboard addon..."
  minikube addons enable dashboard

  log "Enabling metrics-server addon..."
  minikube addons enable metrics-server

  log "Labeling minikube node with NVIDIA GPU label..."
  kubectl label node minikube feature.node.kubernetes.io/pci-10de.present=true --overwrite
}

# === Phase 2: API Key Setup ===
setup_api_keys() {
  log "Setting up authentication..."
  echo ""

  if [[ -z "$NVIDIA_API_KEY" ]]; then
    read -r -s -p "Enter your NVIDIA API Key (from build.nvidia.com): " NVIDIA_API_KEY
    echo
    [[ -n "$NVIDIA_API_KEY" ]] || { err "NVIDIA API key is required"; exit 1; }
  fi

  if [[ -z "$HF_TOKEN" ]]; then
    read -r -s -p "Enter your HuggingFace token (from huggingface.co): " HF_TOKEN
    echo
    [[ -n "$HF_TOKEN" ]] || { err "HuggingFace token is required"; exit 1; }
  fi

  export NVIDIA_API_KEY HF_TOKEN

  echo ""
  log "Creating Kubernetes secrets..."

  kubectl delete secret nvcrimagepullsecret -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete secret ngc-api -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete secret nvidia-api -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true
  kubectl delete secret hf-token -n "$NAMESPACE" --ignore-not-found=true 2>/dev/null || true

  kubectl create secret docker-registry nvcrimagepullsecret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NVIDIA_API_KEY" || {
      err "Failed to create NGC image pull secret"
      suggest_fix "Verify your NVIDIA API key is correct and has NGC access"
      exit 1
    }

  kubectl create secret generic ngc-api \
    --from-literal=NGC_API_KEY="$NVIDIA_API_KEY" || {
      err "Failed to create NGC API secret"
      exit 1
    }

  kubectl create secret generic nvidia-api \
    --from-literal=NVIDIA_API_KEY="$NVIDIA_API_KEY" || {
      err "Failed to create NVIDIA API secret"
      exit 1
    }

  kubectl create secret generic hf-token \
    --from-literal=HF_TOKEN="$HF_TOKEN" || {
      err "Failed to create HuggingFace token secret"
      exit 1
    }

  log "✓ All authentication secrets created successfully"
}

# === Phase 3: Deploy Helm Chart ===
download_helm_chart() {
  helm_args=()
  for values_file in "${ADDITIONAL_VALUES_FILES[@]}"; do
    [[ -f "$values_file" ]] || die "Values file not found: $values_file"
    helm_args+=("-f" "$values_file")
  done

  if [[ -n "$HELM_CHART_VERSION" ]]; then
    log "Setting up NeMo microservices Helm repository for version $HELM_CHART_VERSION..."

    if [[ -z "$NVIDIA_API_KEY" ]]; then
      err "NVIDIA_API_KEY not set when configuring helm repository"
      suggest_fix "Export NVIDIA_API_KEY before running: export NVIDIA_API_KEY='nvapi-xxx'"
      exit 1
    fi

    log "Authenticating with NGC helm repository..."
    helm repo add nmp https://helm.ngc.nvidia.com/nvidia/nemo-microservices \
      --username='$oauthtoken' \
      --password="$NVIDIA_API_KEY" \
      --force-update || die "Failed to add helm repository"

    log "Updating helm repository..."
    helm repo update || die "Failed to update helm repository"

    log "Helm repository setup complete. Chart version $HELM_CHART_VERSION will be installed directly from the repository."
  else
    log "Downloading NeMo microservices Helm chart from direct URL..."
    log "Note: You will be prompted for confirmation before removing any existing chart files."

    if [[ -d "nemo-microservices-helm-chart" ]]; then
      log "Found existing chart directory 'nemo-microservices-helm-chart'."
      if confirm_action "Remove existing chart directory to ensure fresh download?"; then
        rm -rf nemo-microservices-helm-chart
        log "Chart directory removed successfully."
      else
        log "Skipping chart directory cleanup. Using existing directory."
      fi
    fi

    if ls nemo-microservices-helm-chart-*.tgz 1>/dev/null 2>&1; then
      log "Found existing chart tgz file(s):"
      ls -la | grep nemo-microservices-helm-chart || true
      if confirm_action "Remove existing chart tgz files to ensure fresh download?"; then
        rm -rf nemo-microservices-helm-chart-*.tgz
        log "Chart tgz files removed successfully."
      else
        log "Skipping chart tgz file cleanup. Using existing files."
      fi
    fi

    if [[ ! -d "nemo-microservices-helm-chart" ]] && ! ls nemo-microservices-helm-chart-*.tgz 1>/dev/null 2>&1; then
      log "Downloading fresh NeMo microservices Helm chart..."
      helm fetch --untar "$HELM_CHART_URL" \
        --username='$oauthtoken' \
        --password="$NVIDIA_API_KEY"
    else
      die "Cannot proceed with --helm-chart-url when existing chart files are present. Please either allow cleanup or remove them manually."
    fi
  fi
}

install_nemo_microservices() {
  log "Installing NeMo microservices Helm chart..."

  local volcano_version="v1.9.0"
  log "Installing Volcano scheduler version: $volcano_version"
  kubectl apply -f "https://raw.githubusercontent.com/volcano-sh/volcano/${volcano_version}/installer/volcano-development.yaml" 2>&1 | filter_k8s_warnings

  sleep 15

  if [[ -n "$HELM_CHART_VERSION" ]]; then
    if [[ "$HELM_CHART_VERSION" == "latest" ]]; then
      log "Installing latest available NeMo microservices version from helm repository..."
      helm install nemo nmp/nemo-microservices-helm-chart --namespace "$NAMESPACE" \
        "${helm_args[@]}" \
        --timeout 30m 2>&1 | filter_k8s_warnings
    else
      log "Installing NeMo microservices version $HELM_CHART_VERSION from helm repository..."
      helm install nemo nmp/nemo-microservices-helm-chart --namespace "$NAMESPACE" \
        --version "$HELM_CHART_VERSION" \
        "${helm_args[@]}" \
        --timeout 30m 2>&1 | filter_k8s_warnings
    fi
  else
    log "Installing NeMo microservices from local chart file..."
    helm install nemo nemo-microservices-helm-chart --namespace "$NAMESPACE" \
      "${helm_args[@]}" \
      --timeout 30m 2>&1 | filter_k8s_warnings
  fi

  sleep 20
}

wait_for_pods() {
  log "Waiting for pods to initialize (up to 30 minutes)..."
  log "You may see some CrashLoops initially - that's normal and they'll recover."
  log "Showing progress every 30 seconds..."
  echo ""

  local old_err_trap
  old_err_trap=$(trap -p ERR)
  trap 'echo "Interrupted by user. Exiting."; exit 1;' SIGINT

  local start_time end_time last_status_time
  start_time=$(date +%s)
  end_time=$((start_time + 1800))   # 30 minutes
  last_status_time=$start_time

  while true; do
    local pod_statuses

    _xtrace_push
    pod_statuses="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null || true)"
    _xtrace_pop

    if [[ -z "$pod_statuses" ]]; then
      warn "Failed to get pod statuses from kubectl (empty output). Retrying..."
      sleep 5
      continue
    fi

    local current_time
    current_time=$(date +%s)
    if (( current_time - last_status_time >= 30 )); then
      local elapsed elapsed_min
      elapsed=$((current_time - start_time))
      elapsed_min=$((elapsed / 60))

      local total_pods=0 running=0 completed=0 pending=0 init=0 container_creating=0 crash_loop=0
      while IFS='=' read -r k v; do
        case "$k" in
          total) total_pods="$v" ;;
          running) running="$v" ;;
          completed) completed="$v" ;;
          pending) pending="$v" ;;
          init) init="$v" ;;
          creating) container_creating="$v" ;;
          crashloop) crash_loop="$v" ;;
        esac
      done < <(
        printf '%s\n' "$pod_statuses" | awk '
          BEGIN { t=r=c=p=i=cc=cl=0 }
          NF {
            t++
            st=$3
            if (st=="Running") r++
            else if (st=="Completed") c++
            else if (st=="Pending") p++
            else if (index(st,"Init:")==1) i++
            else if (st=="ContainerCreating") cc++
            else if (st ~ /CrashLoop/) cl++
          }
          END {
            printf "total=%d\nrunning=%d\ncompleted=%d\npending=%d\ninit=%d\ncreating=%d\ncrashloop=%d\n", t,r,c,p,i,cc,cl
          }
        '
      )

      echo ""
      log "⏱️  Status after ${elapsed_min} min"
      echo "  Pods: total=${total_pods}  running=${running}  completed=${completed}"
      if (( pending || init || container_creating || crash_loop )); then
        echo "  Other: pending=${pending}  init=${init}  creating=${container_creating}  crashloop=${crash_loop}"
      fi

      local not_ready
      not_ready="$(printf '%s\n' "$pod_statuses" | awk '$3!="Running" && $3!="Completed" {print $1, $3}' | head -n 3 || true)"
      if [[ -n "$not_ready" ]]; then
        echo "  Sample not ready:"
        printf '%s\n' "$not_ready" | awk '{printf "    • %s: %s\n", $1, $2}'
      fi
      echo ""

      last_status_time=$current_time
    fi

    local image_pull_errors
    image_pull_errors="$(printf '%s\n' "$pod_statuses" | grep -E "ImagePullBackOff|ErrImagePull" || true)"
    if [[ -n "$image_pull_errors" ]]; then
      err "Detected ImagePull errors!"
      printf '%s\n' "$image_pull_errors" >&2
      warn "Gathering diagnostics for pods with ImagePull errors..."
      local error_pods
      mapfile -t error_pods < <(printf '%s\n' "$image_pull_errors" | awk '{print $1}')
      local err_dir="nemo-errors-$(date +%s)"
      mkdir -p "$err_dir" || warn "Could not create error directory: $err_dir"
      for pod in "${error_pods[@]}"; do
        collect_pod_diagnostics "$pod" "$NAMESPACE" "$err_dir"
      done
      eval "$old_err_trap"
      trap - SIGINT
      echo ""
      err "Exiting due to ImagePull errors"
      echo ""
      suggest_fix "This usually indicates an authentication issue with NGC registry"
      suggest_fix "Verify your NVIDIA API key is correct:"
      echo "  curl -H \"Authorization: Bearer \$NVIDIA_API_KEY\" https://api.ngc.nvidia.com/v2/org"
      echo ""
      suggest_fix "If authentication fails, regenerate your key at build.nvidia.com"
      suggest_fix "Then run: ./$(basename "$0") --force to skip confirmations"
      echo ""
      suggest_fix "Diagnostics collected to: $err_dir"
      exit 1
    fi

    if ! printf '%s\n' "$pod_statuses" | grep -v "Completed" | grep -qE "0/|Pending|CrashLoop|Error"; then
      log "All necessary pods are ready or succeeded."
      break
    fi

    current_time=$(date +%s)
    if (( current_time >= end_time )); then
      warn "Timeout waiting for pods to stabilize. Gathering diagnostics..."
      check_pod_health
      eval "$old_err_trap"
      trap - SIGINT
      die "Timeout waiting for pods to stabilize after 30 minutes. Diagnostics collected (if possible)."
    fi

    sleep 10
  done

  eval "$old_err_trap"
  trap - SIGINT
  log "Pods have stabilized."
}

# === Phase 4: Pod Health Verification ===
check_pod_health() {
  log "Checking pod health and collecting errors if needed..."
  local err_dir="nemo-errors-$(date +%s)"
  mkdir -p "$err_dir" || warn "Could not create error directory: $err_dir"

  local secrets_ok=0
  check_image_pull_secrets "$NAMESPACE" || secrets_ok=$?
  if [[ $secrets_ok -ne 0 ]]; then
    warn "Image pull secret issues detected. Pods might fail to start."
  fi

  local all_pods=()
  _xtrace_push
  if ! mapfile -t all_pods < <(kubectl get pods -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name); then
    _xtrace_pop
    warn "Failed to get pod list from kubectl."
  else
    _xtrace_pop
  fi

  local unhealthy_pods=()
  local pending_pods=()

  for pod in "${all_pods[@]}"; do
    local pod_status=""
    if ! pod_status="$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"; then
      warn "Failed to get status for pod: $pod"
      unhealthy_pods+=("$pod")
      continue
    fi

    if [[ "$pod_status" != "Running" && "$pod_status" != "Succeeded" && -n "$pod_status" ]]; then
      if [[ "$pod_status" == "Pending" ]]; then
        pending_pods+=("$pod")
      else
        warn "Pod $pod is in unexpected state: $pod_status"
        unhealthy_pods+=("$pod")
      fi
    fi
  done

  if ((${#pending_pods[@]} > 0)); then
    warn "Detected ${#pending_pods[@]} pending pods. Checking if they eventually run..."
    for pod in "${pending_pods[@]}"; do
      timeout 60 bash -c "while kubectl get pod $pod -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Pending; do sleep 5; done" || {
        warn "Pod $pod remained in Pending state."
        unhealthy_pods+=("$pod")
      }
    done
  fi

  if ((${#unhealthy_pods[@]} > 0)); then
    warn "Detected ${#unhealthy_pods[@]} unhealthy pods. Gathering diagnostics..."
    local unique_unhealthy=()
    mapfile -t unique_unhealthy < <(printf "%s\n" "${unhealthy_pods[@]}" | sort -u)

    for pod in "${unique_unhealthy[@]}"; do
      collect_pod_diagnostics "$pod" "$NAMESPACE" "$err_dir"
    done

    log "Collecting cluster-wide events..."
    kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' >"$err_dir/cluster_events.txt" 2>/dev/null || warn "Failed to get cluster events."

    warn "Diagnostics written to $err_dir (if possible)"
    return 1
  fi

  log "All pods are healthy (Running or Succeeded)."
  return 0
}

# === Phase 5: DNS Configuration ===
configure_dns() {
  log "Configuring DNS for ingress..."
  local minikube_ip
  minikube_ip="$(minikube ip)"

  log "Using Minikube IP: $minikube_ip"

  log "Creating backup of /etc/hosts..."
  maybe_sudo cp /etc/hosts "/etc/hosts.backup.$(date +%Y%m%d%H%M%S)"

  if grep -q "$minikube_ip.*nim.test" /etc/hosts && \
     grep -q "$minikube_ip.*data-store.test" /etc/hosts && \
     grep -q "$minikube_ip.*nemo.test" /etc/hosts; then
    log "DNS entries already correctly configured, skipping..."
    return 0
  fi

  if grep -q "nim.test\|data-store.test\|nemo.test" /etc/hosts; then
    warn "Existing entries found in /etc/hosts. Updating with current Minikube IP..."
    maybe_sudo sed -i.bak "/nemo.test/d" /etc/hosts
    maybe_sudo sed -i.bak "/nim.test/d" /etc/hosts
    maybe_sudo sed -i.bak "/data-store.test/d" /etc/hosts
  fi

  {
    echo "# Added by NeMo setup script"
    echo "$minikube_ip nim.test"
    echo "$minikube_ip data-store.test"
    echo "$minikube_ip nemo.test"
  } | maybe_sudo tee -a /etc/hosts >/dev/null

  log "✓ DNS configured successfully"
  log "  • nim.test → $minikube_ip"
  log "  • data-store.test → $minikube_ip"
  log "  • nemo.test → $minikube_ip"
}

# === Main Entrypoint ===
main() {
  parse_args "$@"
  validate_args

  check_and_install_dependencies

  check_prereqs
  check_sudo_access
  download_helm_chart
  start_minikube
  sleep 10
  setup_api_keys
  install_nemo_microservices
  wait_for_pods
  check_pod_health || die "Base cluster is not healthy after waiting. Investigate and re-run."
  configure_dns

  # Correct bash function call syntax (no parentheses/commas)
  # Load deploy_nim() from external file
  source "$(dirname "${BASH_SOURCE[0]}")/../deploy_nim.sh"

  deploy_nim "meta" "llama-3.1-8b-instruct-dgx-spark" "1.0.0-variant"
  #wait_for_nim "meta" "llama-3.1-8b-instruct-dgx-spark"
  #verify_nim_endpoint

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "🎉 Setup Complete! NeMo Microservices Platform is ready!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local minikube_ip
  minikube_ip="$(minikube ip)"

  log "📍 Your endpoints:"
  echo "  • NIM Gateway:   http://nim.test"
  echo "  • Data Store:    http://data-store.test"
  echo "  • Platform APIs: http://nemo.test (all /v1/* endpoints)"
  echo ""
  log "📚 Quick tests:"
  echo "  • List models:        curl http://nim.test/v1/models"
  echo "  • Data Store health:  curl http://data-store.test/v1/health"
  echo "  • List namespaces:    curl http://nemo.test/v1/namespaces"
  echo "  • Customization API:  curl http://nemo.test/v1/customization/jobs"
  echo ""
  log "💡 Useful commands:"
  echo "  • View all pods:        kubectl get pods -n default"
  echo "  • Check service status: kubectl get svc -n default"
  echo "  • View logs:            kubectl logs <pod-name> -n default"
  echo "  • Clean up:             ./destroy-nmp-deployment.sh"
  echo ""
  log "📖 Documentation: https://docs.nvidia.com/nemo/microservices/"
  echo ""
}

main "$@"
