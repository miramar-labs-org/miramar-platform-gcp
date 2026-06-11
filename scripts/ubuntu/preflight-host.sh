#!/usr/bin/env bash
# Preflight checks before running platform install/upgrade workflows.
# Run directly on the target host (not from inside a runner container).
# Exits 0 if all required checks pass; 1 if any FAIL-level check fails.
#
# Usage:
#   ./preflight-host.sh [--label <runner-label>]
#
# --label   GitHub Actions runner label to verify (e.g. agx, dgx).
#           If omitted, just checks that mlabs-runner is running.

RUNNER_LABEL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) RUNNER_LABEL="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0

_pass() { printf "  ${GREEN}✓${NC} %s\n" "$1";                                               PASS=$((PASS + 1)); }
_fail() { printf "  ${RED}✗${NC} %s  ${RED}← %s${NC}\n" "$1" "${2:-fix required}";          FAIL=$((FAIL + 1)); }
_warn() { printf "  ${YELLOW}⚠${NC} %s  ${YELLOW}← %s${NC}\n" "$1" "${2:-advisory}";        WARN=$((WARN + 1)); }
_info() { printf "  ${CYAN}→${NC} %s\n" "$1"; }
section() { printf "\n${BOLD}%s${NC}\n" "$1"; }

# ── 1. OS & Hardware ──────────────────────────────────────────────────────────
section "1. OS & Hardware"

ARCH=$(uname -m)
_info "Architecture: $ARCH"

MODEL=$([[ -f /proc/device-tree/model ]] && tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
[[ -n "$MODEL" ]] && _info "Device: $MODEL"

[[ -f /etc/nv_tegra_release ]] && _info "JetPack: $(head -1 /etc/nv_tegra_release)"

OS=$(lsb_release -d 2>/dev/null | cut -f2-)
if echo "$OS" | grep -q "Ubuntu"; then
    _pass "OS: $OS"
else
    _warn "OS is '$OS' (expected Ubuntu)" "workflows are tested on Ubuntu 22.04+"
fi

MEM_GB=$(awk '/MemTotal/ { printf "%.0f", $2/1024/1024 }' /proc/meminfo)
if [[ $MEM_GB -ge 60 ]]; then
    _pass "RAM: ${MEM_GB} GB"
else
    _warn "RAM: ${MEM_GB} GB" "large model workloads need 64+ GB"
fi

# ── 2. Disk Space ─────────────────────────────────────────────────────────────
section "2. Disk Space"

FREE_GB=$(df -BG "$HOME" | awk 'NR==2 { gsub(/G/,"",$4); print $4 }')
if [[ $FREE_GB -ge 500 ]]; then
    _pass "Free disk in ~: ${FREE_GB} GB (≥500 GB)"
elif [[ $FREE_GB -ge 100 ]]; then
    _warn "Free disk in ~: ${FREE_GB} GB — installable, but full model workloads need ~500 GB" "consider freeing space before running pipelines"
else
    _fail "Free disk in ~: ${FREE_GB} GB" "need ≥100 GB to install — NeMo + model cache alone exceeds 500 GB"
fi

INODE_PCT=$(df -i "$HOME" | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')
if [[ $INODE_PCT -lt 80 ]]; then
    _pass "Inode usage: ${INODE_PCT}%"
else
    _fail "Inode usage: ${INODE_PCT}% (k3s is inode-heavy)" "clean up small files in $HOME"
fi

# ── 3. Network ────────────────────────────────────────────────────────────────
section "3. Network"

HOST=$(hostname)
[[ -n "$HOST" ]] && _pass "Hostname: $HOST" || _fail "Hostname not set" "sudo hostnamectl set-hostname <name>"

IP=$(hostname -I | awk '{print $1}')
[[ -n "$IP" ]] && _pass "IP address: $IP" || _fail "No IP address assigned" "check network configuration"

if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    _pass "SSH daemon: active"
else
    _fail "SSH daemon not running" "sudo systemctl enable --now ssh"
fi

if systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    _pass "Avahi (mDNS): active"
else
    _warn "Avahi (mDNS) not running" "sudo systemctl enable --now avahi-daemon"
fi

if curl -fsSL --max-time 5 https://example.com -o /dev/null 2>/dev/null; then
    _pass "Internet connectivity: OK"
else
    _fail "No internet access" "workflows need internet to pull helm charts, k3s, and container images"
fi

# ── 4. System Software ────────────────────────────────────────────────────────
section "4. System Software"

for cmd in curl git jq python3; do
    command -v "$cmd" &>/dev/null \
        && _pass "$cmd: $(command -v "$cmd")" \
        || _fail "$cmd not installed" "sudo apt-get install -y $cmd"
done

command -v docker &>/dev/null \
    && _pass "docker: $(command -v docker)" \
    || _fail "docker not installed" "https://docs.docker.com/engine/install/ubuntu/"

docker ps &>/dev/null 2>&1 \
    && _pass "Docker daemon: accessible without sudo" \
    || _fail "Docker daemon not accessible" "sudo usermod -aG docker \$USER && newgrp docker  OR  sudo systemctl start docker"

# ── 5. NVIDIA / GPU ───────────────────────────────────────────────────────────
section "5. NVIDIA / GPU"

if command -v nvidia-smi &>/dev/null; then
    GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    _pass "nvidia-smi: GPU = ${GPU:-present}"
else
    _fail "nvidia-smi not found" "check NVIDIA driver / JetPack installation"
fi

if command -v nvidia-ctk &>/dev/null; then
    _pass "nvidia-ctk: $(nvidia-ctk --version 2>&1 | head -1)"
else
    _fail "NVIDIA Container Toolkit not installed" "https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
fi

if docker run --rm --gpus all --entrypoint nvidia-smi \
    nvcr.io/nvidia/cuda:12.6.3-base-ubuntu22.04 \
    --query-gpu=name --format=csv,noheader &>/dev/null 2>&1; then
    _pass "GPU accessible from containers (--gpus all)"
else
    _fail "GPU not accessible from Docker containers" "nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
fi

# ── 6. Kernel Limits ─────────────────────────────────────────────────────────
section "6. Kernel Limits"

INOTIFY_INST=$(cat /proc/sys/fs/inotify/max_user_instances)
INOTIFY_WATCH=$(cat /proc/sys/fs/inotify/max_user_watches)

if [[ $INOTIFY_INST -ge 1024 ]]; then
    _pass "inotify max_user_instances: $INOTIFY_INST"
else
    _fail "inotify max_user_instances: $INOTIFY_INST (need ≥1024)" \
        "echo 'fs.inotify.max_user_instances=1024' | sudo tee -a /etc/sysctl.d/99-k3s.conf && sudo sysctl --system"
fi

if [[ $INOTIFY_WATCH -ge 1048576 ]]; then
    _pass "inotify max_user_watches: $INOTIFY_WATCH"
else
    _fail "inotify max_user_watches: $INOTIFY_WATCH (need ≥1048576)" \
        "echo 'fs.inotify.max_user_watches=1048576' | sudo tee -a /etc/sysctl.d/99-k3s.conf && sudo sysctl --system"
fi

# ── 7. k3s State ─────────────────────────────────────────────────────────────
section "7. k3s State"

command -v systemctl &>/dev/null && systemctl --version &>/dev/null \
    && _pass "systemd: available" \
    || _fail "systemd not available" "k3s requires systemd"

if sudo -n true &>/dev/null 2>&1; then
    _pass "sudo: passwordless access"
elif sudo -v &>/dev/null 2>&1; then
    _warn "sudo: requires password" "bootstrap workflow SSHes in and runs sudo — passwordless sudo is required"
else
    _fail "sudo: not available" "add $USER to sudoers"
fi

if command -v k3s &>/dev/null; then
    K3S_VER=$(k3s --version | head -1)
    if systemctl is-active --quiet k3s 2>/dev/null; then
        _info "k3s already installed and running ($K3S_VER) — this is an UPGRADE, not a fresh install"
        _pass "k3s: running ($K3S_VER)"
    else
        _warn "k3s binary found but service not active ($K3S_VER)" \
            "sudo systemctl start k3s  OR  run bootstrap workflow for fresh install"
    fi
else
    _pass "k3s: not installed (clean state — ready for fresh install)"
fi

# ── 8. GitHub Actions Runner ─────────────────────────────────────────────────
section "8. GitHub Actions Runner"

RUNNER_CONTAINER=$(docker ps --filter "name=mlabs-runner" --format "{{.Names}}" 2>/dev/null | head -1)
if [[ -n "$RUNNER_CONTAINER" ]]; then
    _pass "mlabs-runner container: $RUNNER_CONTAINER"
else
    _fail "mlabs-runner container not running" \
        "run scripts/gha/launch-runner.sh (needs GITHUB_ORG_GHCR_PAT + GITHUB_ORG_ADMIN_PAT)"
fi

if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    if [[ -n "$RUNNER_LABEL" ]]; then
        MATCHED=$(gh api orgs/miramar-labs-org/actions/runners 2>/dev/null \
            | python3 -c "
import sys, json
runners = json.load(sys.stdin)['runners']
matched = [r for r in runners if any(l['name']=='${RUNNER_LABEL}' for l in r['labels'])]
print(matched[0]['name']+'  status='+matched[0]['status'] if matched else '')
" 2>/dev/null || true)
        if [[ -n "$MATCHED" ]]; then
            _pass "Runner with label '${RUNNER_LABEL}': $MATCHED"
        else
            _fail "No runner with label '${RUNNER_LABEL}' found in GitHub org" \
                "start mlabs-runner with --labels ${RUNNER_LABEL}"
        fi
    else
        _info "Pass --label <label> to verify a specific runner label (e.g. agx, dgx)"
    fi
else
    _warn "gh CLI not authenticated — cannot verify runner registration" \
        "gh auth login  OR  check GitHub org runners manually"
fi

# ── 9. Credentials ───────────────────────────────────────────────────────────
section "9. Credentials & Environment"

for var in GITHUB_ORG_GHCR_PAT GITHUB_ORG_ADMIN_PAT; do
    [[ -n "${!var:-}" ]] \
        && _pass "$var: set" \
        || _fail "$var: not set in environment" "add to ~/.zshrc: export $var=<token>"
done

[[ -n "${HF_TOKEN:-}" ]] \
    && _pass "HF_TOKEN: set" \
    || _warn "HF_TOKEN: not set" "required for gated HuggingFace models — add to ~/.zshrc: export HF_TOKEN=hf_..."

_info "Org secrets (HOST_SSH_KEY, NVIDIA_API_KEY, MIRAMAR_ORG_ADMIN_PAT, MIRAMAR_ORG_GHCR_PAT) cannot be verified from the host — confirm in GitHub org settings"

# ── 10. SSH ───────────────────────────────────────────────────────────────────
section "10. SSH"

AUTH_KEYS="$HOME/.ssh/authorized_keys"
if [[ -s "$AUTH_KEYS" ]]; then
    _pass "~/.ssh/authorized_keys: $(wc -l < "$AUTH_KEYS") key(s) present"
else
    _fail "~/.ssh/authorized_keys missing or empty" \
        "add the HOST_SSH_KEY public key so workflows can SSH in"
fi

[[ "$(stat -c %a "$HOME/.ssh" 2>/dev/null)" == "700" ]] \
    && _pass "~/.ssh permissions: 700" \
    || _warn "~/.ssh permissions are not 700" "chmod 700 ~/.ssh"

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BOLD}Summary${NC}\n"
printf "  ${GREEN}✓${NC} Passed : %d\n" "$PASS"
printf "  ${YELLOW}⚠${NC} Warned : %d\n" "$WARN"
printf "  ${RED}✗${NC} Failed : %d\n" "$FAIL"
printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    printf "${GREEN}${BOLD}Host is ready for the platform bootstrap workflow.${NC}\n\n"
    exit 0
elif [[ $FAIL -eq 0 ]]; then
    printf "${YELLOW}${BOLD}Host passes all required checks. Review warnings before proceeding.${NC}\n\n"
    exit 0
else
    printf "${RED}${BOLD}Resolve the %d failed check(s) above before running the bootstrap workflow.${NC}\n\n" "$FAIL"
    exit 1
fi
