#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

log "Baseline apt update"
sudo apt-get update

ARCH="$(dpkg --print-architecture)"

log "Install baseline tools (includes git + zsh + gpg + fzf + tmux)"
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl wget git gnupg lsb-release \
  unzip zip jq tree dos2unix \
  zsh fzf tmux

log "Install git-lfs (optional but common)"
sudo apt-get install -y --no-install-recommends git-lfs
git lfs install --skip-repo || true

log "Install C++ toolchain + dev tooling"
sudo apt-get install -y --no-install-recommends \
  build-essential \
  clang clang-format clang-tidy llvm lldb gdb \
  cmake ninja-build make pkg-config \
  ccache mold \
  valgrind \
  cppcheck bear \
  lcov gcovr \
  doxygen graphviz

log "Install system + network diagnostics"
sudo apt-get install -y --no-install-recommends \
  htop btop \
  procps psmisc lsof \
  sysstat dstat iotop \
  ncdu \
  lm-sensors \
  usbutils pciutils \
  strace ltrace \
  iproute2 iputils-ping \
  net-tools \
  dnsutils \
  traceroute mtr-tiny \
  tcpdump \
  nmap \
  socat netcat-openbsd \
  openssh-client \
  rsync \
  ethtool \
  whois \
  iperf3 \
  fastfetch \
  iftop nethogs vnstat zstd

log "Installing local dev tools"
sudo apt-get update
sudo apt-get install -y \
  shellcheck \
  yamllint 

curl -sSLo /tmp/hadolint \
  https://github.com/hadolint/hadolint/releases/download/v2.12.0/hadolint-Linux-x86_64

chmod +x /tmp/hadolint
sudo mv /tmp/hadolint /usr/local/bin/hadolint

curl -sSLo /tmp/shfmt \
  https://github.com/mvdan/sh/releases/download/v3.10.0/shfmt_v3.10.0_linux_amd64

chmod +x /tmp/shfmt
sudo mv /tmp/shfmt /usr/local/bin/shfmt

log "Install K8s utils"
sudo snap install k9s
sudo apt install -y kubectx
echo "alias k=kubectl" >> ~/.zshrc
echo "alias kctx=kubectx" >> ~/.zshrc
echo "alias kns=kubens" >> ~/.zshrc
echo 'source <(kubectl completion zsh)' >> ~/.zshrc
echo 'compdef k=kubectl' >> ~/.zshrc

log "Install tmux plugins"
if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
  git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
fi

log "Set zsh as default shell for current user"
if [[ "${SHELL:-}" != "$(command -v zsh)" ]]; then
  sudo chsh -s "$(command -v zsh)" "$USER" || true
fi

log "Install Oh My Zsh (unattended)"
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  # Download to a temp file so the script can be inspected before execution.
  # Oh My Zsh does not publish checksums for install.sh; HTTPS is the only
  # available integrity guarantee here.
  _omztmp="$(mktemp)"
  curl -fsSL -o "$_omztmp" https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$_omztmp"
  rm -f "$_omztmp"
fi
# Idempotent: only append if not already present
grep -q 'export ZSH=' "$HOME/.zshrc" 2>/dev/null \
  || echo 'export ZSH="$HOME/.oh-my-zsh"' >> "$HOME/.zshrc"
grep -q '^plugins=' "$HOME/.zshrc" 2>/dev/null \
  || echo 'plugins=(git)' >> "$HOME/.zshrc"

log "Install Powerlevel10k (Oh My Zsh theme)"
P10K_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
if [[ ! -d "$P10K_DIR" ]]; then
  git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
fi

log "Enable Powerlevel10k theme in ~/.zshrc (idempotent)"
if grep -q '^ZSH_THEME=' "$HOME/.zshrc" 2>/dev/null; then
  sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$HOME/.zshrc"
else
  echo 'ZSH_THEME="powerlevel10k/powerlevel10k"' >> "$HOME/.zshrc"
fi
grep -q 'source \$ZSH/oh-my-zsh.sh' "$HOME/.zshrc" 2>/dev/null \
  || echo 'source $ZSH/oh-my-zsh.sh' >> "$HOME/.zshrc"

log "Install pyenv build dependencies"
sudo apt-get install -y --no-install-recommends \
  make libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
  libffi-dev liblzma-dev

log "Install pyenv binaries to /opt/pyenv (root-owned)"
if [[ ! -d /opt/pyenv ]]; then
  sudo git clone https://github.com/pyenv/pyenv.git /opt/pyenv
  sudo chown -R root:root /opt/pyenv
  sudo chmod -R 755 /opt/pyenv
fi

log "Install pyenv-virtualenv plugin (root-owned, under /opt/pyenv/plugins)"
if [[ ! -d /opt/pyenv/plugins/pyenv-virtualenv ]]; then
  sudo install -d -m 0755 /opt/pyenv/plugins
  sudo git clone https://github.com/pyenv/pyenv-virtualenv.git /opt/pyenv/plugins/pyenv-virtualenv
  sudo chown -R root:root /opt/pyenv/plugins/pyenv-virtualenv
  sudo chmod -R 755 /opt/pyenv/plugins/pyenv-virtualenv
fi

log "Configure pyenv system-wide: executable in /opt/pyenv, data in ~/.pyenv (fixes permissions)"
sudo tee /etc/profile.d/pyenv.sh >/dev/null <<'EOF'
# pyenv executable lives in /opt/pyenv, but user data stays in ~/.pyenv (writable per-user)
export PYENV_ROOT="$HOME/.pyenv"
export PATH="/opt/pyenv/bin:$PATH"
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init -)"
  eval "$(pyenv virtualenv-init -)"
fi
EOF

mkdir -p "$HOME/.pyenv"

grep -q "profile.d/pyenv.sh" ~/.zshrc 2>/dev/null || cat >> ~/.zshrc <<'EOF'

# system-wide pyenv
if [ -f /etc/profile.d/pyenv.sh ]; then
  source /etc/profile.d/pyenv.sh
fi
EOF

log "Install Miniforge3 to /opt/miniforge3"
if [[ ! -d /opt/miniforge3 ]]; then
  ARCHM="$(uname -m)"
  case "$ARCHM" in
    x86_64)        MF_ARCH="x86_64" ;;
    aarch64|arm64) MF_ARCH="aarch64" ;;
    *) die "Unsupported arch for Miniforge: $ARCHM" ;;
  esac

  _mftmp="$(mktemp)"
  curl -fsSL -o "$_mftmp" \
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${MF_ARCH}.sh"
  _mfsha="$(curl -fsSL \
    "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${MF_ARCH}.sh.sha256" \
    | awk '{print $1}')"
  echo "${_mfsha}  ${_mftmp}" | sha256sum --check || die "Miniforge checksum mismatch"
  sudo bash "$_mftmp" -b -p /opt/miniforge3
  rm -f "$_mftmp"
fi

sudo tee /etc/profile.d/miniforge.sh >/dev/null <<'EOF'
export PATH="/opt/miniforge3/bin:$PATH"
EOF

grep -q "profile.d/miniforge.sh" ~/.zshrc 2>/dev/null || cat >> ~/.zshrc <<'EOF'

# system-wide miniforge
if [ -f /etc/profile.d/miniforge.sh ]; then
  source /etc/profile.d/miniforge.sh
fi
EOF

log "Install Java (OpenJDK 17)"
sudo apt-get install -y --no-install-recommends openjdk-17-jdk

log "Install Go"
case "$ARCH" in
  amd64) GOARCH="amd64" ;;
  arm64) GOARCH="arm64" ;;
  *) die "Unsupported arch for Go: $ARCH" ;;
esac

GOVER="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n 1 | tr -d '\r\n')"
_gotmp="$(mktemp)"
curl -fsSL -o "$_gotmp" "https://go.dev/dl/${GOVER}.linux-${GOARCH}.tar.gz"
_gosha="$(curl -fsSL "https://go.dev/dl/${GOVER}.linux-${GOARCH}.tar.gz.sha256")"
echo "${_gosha}  ${_gotmp}" | sha256sum --check || die "Go checksum mismatch"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf "$_gotmp"
rm -f "$_gotmp"

sudo tee /etc/profile.d/go.sh >/dev/null <<'EOF'
export PATH="$PATH:/usr/local/go/bin"
EOF

log "Install Docker Engine (official Docker repo)"
sudo install -m 0755 -d /etc/apt/keyrings

# Clean up older Docker apt definitions so Signed-By does not conflict on reruns.
sudo rm -f \
  /etc/apt/sources.list.d/docker.list \
  /etc/apt/sources.list.d/docker-ce.list \
  /etc/apt/sources.list.d/docker.sources
sudo find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) \
  -exec grep -l 'download.docker.com/linux/ubuntu' {} + 2>/dev/null | \
  xargs -r sudo rm -f
sudo sed -i '/download\.docker\.com\/linux\/ubuntu/d' /etc/apt/sources.list 2>/dev/null || true

sudo rm -f /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.gpg
EOF

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo systemctl enable docker || true
sudo systemctl start docker || true

sudo usermod -aG docker "$USER" || true

log "Install kubectl"
case "$ARCH" in
  amd64) KARCH="amd64" ;;
  arm64) KARCH="arm64" ;;
  *) die "Unsupported arch for kubectl: $ARCH" ;;
esac

KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt | head -n 1 | tr -d '\r\n')"
_ktmp="$(mktemp)"
curl -fsSLo "$_ktmp" "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl"
_ksha="$(curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl.sha256")"
echo "${_ksha}  ${_ktmp}" | sha256sum --check || die "kubectl checksum mismatch"
sudo install -o root -g root -m 0755 "$_ktmp" /usr/local/bin/kubectl
rm -f "$_ktmp"

log "Install Helm"
case "$ARCH" in
  amd64) HARCH="amd64" ;;
  arm64) HARCH="arm64" ;;
  *) die "Unsupported arch for Helm: $ARCH" ;;
esac

HELM_VER="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)"

_install_helm() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  curl -fsSL -o "$tmpdir/helm.tgz" \
    "https://get.helm.sh/helm-${HELM_VER}-linux-${HARCH}.tar.gz"
  _helmsha="$(curl -fsSL \
    "https://get.helm.sh/helm-${HELM_VER}-linux-${HARCH}.tar.gz.sha256sum" \
    | awk '{print $1}')"
  echo "${_helmsha}  $tmpdir/helm.tgz" | sha256sum --check || die "Helm checksum mismatch"
  tar -C "$tmpdir" -xzf "$tmpdir/helm.tgz"
  sudo install -o root -g root -m 0755 "$tmpdir/linux-${HARCH}/helm" /usr/local/bin/helm
  rm -rf "$tmpdir"
}

if command -v helm >/dev/null 2>&1; then
  CUR_VER="$(helm version --short 2>/dev/null | awk '{print $1}' | cut -d+ -f1 || true)"
  if [[ "$CUR_VER" == "$HELM_VER" ]]; then
    log "Helm already installed ($CUR_VER); skipping"
  else
    _install_helm
  fi
else
  _install_helm
fi

helm version --short

log "Build latest nvtop"
_nvtop_src="$(mktemp -d)"
git clone https://github.com/Syllo/nvtop.git "$_nvtop_src"
pushd "$_nvtop_src"
git checkout 3.3.2
mkdir -p build && cd build
cmake ..
make -j"$(nproc)"
sudo make install
popd
rm -rf "$_nvtop_src"

log "Cleanup"
sudo apt-get autoremove -y
sudo apt-get clean

log "DONE"
echo "Re-open your shell and run:"
echo "  git --version"
echo "  docker version"
echo "  kubectl version --client"
echo "  go version"
echo "  java -version"
echo "  fzf --version"
echo "  tmux -V"
echo "Note: If docker group membership was added, you may need to log out/in or reboot for it to apply."
echo "Powerlevel10k installed. Run 'p10k configure' once after opening zsh."
