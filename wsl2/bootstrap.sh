#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

TMP_PATHS=()
cleanup_tmp_paths() {
  if [[ ${#TMP_PATHS[@]} -gt 0 ]]; then
    rm -rf -- "${TMP_PATHS[@]}"
  fi
}
trap cleanup_tmp_paths EXIT

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REQUIRED_COMPANIONS=(
  mount-dgx-shared.sh
  mount-dgx-shared.service
  mount-dgx-shared.timer
  setup-shared-ssh.sh
)

for companion in "${REQUIRED_COMPANIONS[@]}"; do
  [[ -f "$SCRIPT_DIR/$companion" ]] || die "Missing $SCRIPT_DIR/$companion. Run bootstrap.sh from a full checkout/copy of the wsl2 directory, not as a standalone file."
done

# Fresh Ubuntu images run unattended-upgrades on first boot and hold the dpkg
# lock for several minutes.  Wait for it to finish before touching apt.
log "Wait for apt lock (unattended-upgrades may be running)"
sudo systemctl stop unattended-upgrades 2>/dev/null || true
sudo systemctl disable unattended-upgrades 2>/dev/null || true
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  echo "waiting for apt lock..."; sleep 5
done

log "Baseline apt update"
sudo apt-get update

ARCH="$(dpkg --print-architecture)"

log "Install baseline tools (includes git + zsh + gpg)"
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl wget git gnupg lsb-release \
  unzip zip jq tree dos2unix \
  zsh

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
  htop btop nvtop \
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
  openssh-server \
  avahi-daemon \
  libnss-mdns \
  rsync \
  ethtool \
  whois \
  iperf3 \
  iftop nethogs vnstat \
  cifs-utils

log "Install neofetch"
sudo apt-get install -y --no-install-recommends neofetch

log "Write /etc/wsl.conf (systemd + default user)"
sudo tee /etc/wsl.conf >/dev/null <<EOF
[boot]
systemd = true

[automount]
# Disable WSL2's pre-systemd fstab processing. Do not mount the DGX shared
# folder from /etc/fstab: early mDNS/CIFS handling can delay boot or disrupt
# WSL Plan 9/p9io, causing AcceptAsync canceled followed by distro powerdown.
# A post-boot systemd oneshot + timer mounts the share after networking settles.
mountFsTab = false

[user]
default = ${USER}
EOF

log "Enable SSH server"
sudo systemctl enable ssh
sudo systemctl start ssh || true

log "Prepare SSH directory"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

log "Write ~/.smbcredentials (baked into template — no runtime delivery needed)"
if [[ -z "${DGX_SMB_PASSWORD:-}" ]]; then
  read -rsp "DGX Samba password (username=${USER}): " DGX_SMB_PASSWORD
  echo
fi
printf 'username=%s\npassword=%s\n' "$USER" "$DGX_SMB_PASSWORD" > "$HOME/.smbcredentials"
chmod 600 "$HOME/.smbcredentials"

log "Prepare DGX shared mount point and remove legacy CIFS fstab entry"
mkdir -p "$HOME/shared"
grep -v " $HOME/shared " /etc/fstab > /tmp/fstab.new 2>/dev/null || true
sudo cp /tmp/fstab.new /etc/fstab && rm -f /tmp/fstab.new

chown -R "${USER}:${USER}" "$HOME/.ssh"

log "Configure mDNS (.local resolution via avahi + libnss-mdns)"
sudo systemctl enable avahi-daemon
sudo systemctl start avahi-daemon || true
sudo sed -i \
  's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' \
  /etc/nsswitch.conf
sudo systemctl restart avahi-daemon || true
sudo systemctl restart systemd-resolved 2>/dev/null || true

log "Install shared-folder mount service and setup-shared-ssh.sh"
sudo install -m 755 "$SCRIPT_DIR/mount-dgx-shared.sh" /usr/local/sbin/mount-dgx-shared.sh
sudo install -m 644 "$SCRIPT_DIR/mount-dgx-shared.service" /etc/systemd/system/mount-dgx-shared.service
sudo install -m 644 "$SCRIPT_DIR/mount-dgx-shared.timer" /etc/systemd/system/mount-dgx-shared.timer
sudo tee /etc/mount-dgx-shared.conf >/dev/null <<EOF
DGX_MOUNT_USER=${USER}
DGX_CIFS_HOST=
EOF
sudo systemctl enable /etc/systemd/system/mount-dgx-shared.timer || true
sudo install -m 755 "$SCRIPT_DIR/setup-shared-ssh.sh" /usr/local/bin/setup-shared-ssh.sh

log "Write ~/.ssh/config (lab hosts, skipped if file already exists)"
SSH_CFG="$HOME/.ssh/config"
if [[ ! -s "$SSH_CFG" ]]; then
  cat > "$SSH_CFG" <<EOF
Host msi
    HostName msi.local
    User ${USER}
    IdentityFile ${HOME}/.ssh/id_ed25519
    IdentitiesOnly yes

Host orin
    HostName orin.local
    User ${USER}
    IdentityFile ${HOME}/.ssh/id_ed25519
    IdentitiesOnly yes

Host dgx spark spark-79b7
    HostName spark-79b7.local
    User ${USER}
    IdentityFile ${HOME}/.ssh/id_ed25519
    IdentitiesOnly yes

Host github.com
    HostName github.com
    User git
    IdentityFile ${HOME}/.ssh/id_ed25519
    IdentitiesOnly yes
EOF
  chmod 600 "$SSH_CFG"
fi

log "Set zsh as default shell for current user"
ZSH_BIN="$(command -v zsh)"
CURRENT_SHELL="$(getent passwd "$USER" | cut -d: -f7)"
if [[ "$CURRENT_SHELL" != "$ZSH_BIN" ]]; then
  sudo chsh -s "$ZSH_BIN" "$USER" || true
fi

log "Install Oh My Zsh (unattended)"
if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  # Oh My Zsh does not publish checksums for install.sh; downloading to a temp
  # file rather than piping directly so the script can be inspected if needed.
  # HTTPS is the only integrity guarantee available here.
  _omztmp="$(mktemp)"
  TMP_PATHS+=("$_omztmp")
  curl -fsSL -o "$_omztmp" https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$_omztmp"
fi
# Idempotent: only append if not already present
if ! grep -q 'export ZSH=' "$HOME/.zshrc" 2>/dev/null; then
  # shellcheck disable=SC2016
  printf '%s\n' 'export ZSH="$HOME/.oh-my-zsh"' >> "$HOME/.zshrc"
fi
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
if ! grep -q 'source [$]ZSH/oh-my-zsh[.]sh' "$HOME/.zshrc" 2>/dev/null; then
  # shellcheck disable=SC2016
  printf '%s\n' 'source $ZSH/oh-my-zsh.sh' >> "$HOME/.zshrc"
fi

# auto-run neofetch on zsh startup (optional)
grep -q "command -v neofetch" ~/.zshrc 2>/dev/null || cat >> ~/.zshrc <<'EOF'

# show system info
command -v neofetch >/dev/null 2>&1 && neofetch
EOF

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
    x86_64)       MF_ARCH="x86_64" ;;
    aarch64|arm64) MF_ARCH="aarch64" ;;
    *) die "Unsupported arch for Miniforge: $ARCHM" ;;
  esac

  _mf_json="$(curl -fsSL https://api.github.com/repos/conda-forge/miniforge/releases/latest)"
  _mf_asset="$(printf '%s' "$_mf_json" | jq -r --arg arch "$MF_ARCH" '
    .assets[]
    | select(.name | test("^Miniforge3-.*-Linux-" + $arch + "[.]sh$"))
    | .browser_download_url
  ' | head -n 1)"
  _mf_sha_asset="$(printf '%s' "$_mf_json" | jq -r --arg arch "$MF_ARCH" '
    .assets[]
    | select(.name | test("^Miniforge3-.*-Linux-" + $arch + "[.]sh[.]sha256$"))
    | .browser_download_url
  ' | head -n 1)"
  [[ -n "$_mf_asset" && "$_mf_asset" != "null" ]] || die "Could not find Miniforge Linux $MF_ARCH installer in latest release"
  [[ -n "$_mf_sha_asset" && "$_mf_sha_asset" != "null" ]] || die "Could not find Miniforge Linux $MF_ARCH checksum in latest release"

  _mftmp="$(mktemp)"
  TMP_PATHS+=("$_mftmp")
  curl -fsSL -o "$_mftmp" "$_mf_asset"
  _mfsha="$(curl -fsSL "$_mf_sha_asset" | awk '{print $1}')"
  echo "${_mfsha}  ${_mftmp}" | sha256sum --check || die "Miniforge checksum mismatch"
  # The Miniforge installer checks $BASH_SOURCE to detect if it's being sourced.
  # Running via 'bash tmpfile' can confuse this check. Run the file directly
  # (via its #!/usr/bin/env bash shebang) to ensure $0 and $BASH_SOURCE agree.
  chmod +x "$_mftmp"
  sudo "$_mftmp" -b -p /opt/miniforge3
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

log "Install Go"
case "$ARCH" in
  amd64) GOARCH="amd64" ;;
  arm64) GOARCH="arm64" ;;
  *) die "Unsupported arch for Go: $ARCH" ;;
esac

# Use the Go downloads JSON API -- single call gives both version and SHA256.
# The .sha256 URL endpoint does not exist on go.dev and returns an HTML page.
_go_json="$(curl -fsSL 'https://go.dev/dl/?mode=json')"
GOVER="$(printf '%s' "$_go_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)[0]["version"])')"
GOFILE="${GOVER}.linux-${GOARCH}.tar.gz"
_gosha="$(printf '%s' "$_go_json" | python3 -c \
  "import sys,json; d=json.load(sys.stdin)[0]['files']; \
   f=next(x for x in d if x['filename']=='${GOFILE}'); print(f['sha256'])")"
[[ "${#_gosha}" -eq 64 ]] || die "Go checksum fetch failed: ${_gosha:0:80}"
if [[ -x /usr/local/go/bin/go ]] && [[ "$(/usr/local/go/bin/go version | awk '{print $3}')" == "$GOVER" ]]; then
  log "Go already installed ($GOVER); skipping"
else
  _gotmp="$(mktemp)"
  TMP_PATHS+=("$_gotmp")
  curl -fsSL -o "$_gotmp" "https://go.dev/dl/${GOFILE}"
  echo "${_gosha}  ${_gotmp}" | sha256sum --check || die "Go checksum mismatch"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$_gotmp"
fi

sudo tee /etc/profile.d/go.sh >/dev/null <<'EOF'
export PATH="$PATH:/usr/local/go/bin"
EOF

log "Install Docker Engine (official Docker repo)"
sudo install -m 0755 -d /etc/apt/keyrings
sudo rm -f /etc/apt/keyrings/docker.gpg
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

UBUNTU_CODENAME="$(
  # shellcheck source=/dev/null
  . /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}"
)"
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.gpg
EOF

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# systemd must be enabled (wsl.conf). service start may fail until after wsl --shutdown.
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
TMP_PATHS+=("$_ktmp")
curl -fsSLo "$_ktmp" "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl"
_ksha="$(curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/${KARCH}/kubectl.sha256")"
echo "${_ksha}  ${_ktmp}" | sha256sum --check || die "kubectl checksum mismatch"
sudo install -o root -g root -m 0755 "$_ktmp" /usr/local/bin/kubectl

log "Install minikube"
ARCHM="$(uname -m)"
case "$ARCHM" in
  x86_64)       MK_BIN="minikube-linux-amd64" ;;
  aarch64|arm64) MK_BIN="minikube-linux-arm64" ;;
  *) die "Unsupported arch for minikube: $ARCHM" ;;
esac

_mktmp="$(mktemp)"
TMP_PATHS+=("$_mktmp")
curl -fsSL -o "$_mktmp" \
  "https://github.com/kubernetes/minikube/releases/latest/download/${MK_BIN}"
_mksha="$(curl -fsSL \
  "https://github.com/kubernetes/minikube/releases/latest/download/${MK_BIN}.sha256" \
  | awk '{print $1}')"
echo "${_mksha}  ${_mktmp}" | sha256sum --check || die "minikube checksum mismatch"
sudo install "$_mktmp" /usr/local/bin/minikube

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
  TMP_PATHS+=("$tmpdir")
  curl -fsSL -o "$tmpdir/helm.tgz" \
    "https://get.helm.sh/helm-${HELM_VER}-linux-${HARCH}.tar.gz"
  _helmsha="$(curl -fsSL \
    "https://get.helm.sh/helm-${HELM_VER}-linux-${HARCH}.tar.gz.sha256sum" \
    | awk '{print $1}')"
  echo "${_helmsha}  $tmpdir/helm.tgz" | sha256sum --check || die "Helm checksum mismatch"
  tar -C "$tmpdir" -xzf "$tmpdir/helm.tgz"
  sudo install -o root -g root -m 0755 "$tmpdir/linux-${HARCH}/helm" /usr/local/bin/helm
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

log "Install NVIDIA Container Toolkit (only if nvidia-smi exists in WSL)"
if command -v nvidia-smi >/dev/null 2>&1 || command -v nvidia-smi.exe >/dev/null 2>&1; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

  sudo apt-get update
  sudo apt-get install -y --no-install-recommends nvidia-container-toolkit

  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker || true
else
  log "Skipping NVIDIA Container Toolkit (nvidia-smi not found)"
fi

log "Cleanup"
sudo apt-get autoremove -y
sudo apt-get clean

log "DONE"
echo "Close ALL WSL terminals, then run:  wsl --shutdown  (in PowerShell)"
echo "Re-open Ubuntu and run:"
echo "  neofetch"
echo "  git --version"
echo "  docker version"
echo "  kubectl version --client"
echo "  minikube version"
echo "  go version"

echo "  systemctl status ssh          # verify sshd is enabled"
echo "Note: Docker may not fully start until after you run wsl --shutdown (systemd)."
echo "Note: If docker group membership was added, you may need to restart WSL for it to apply."
echo "Powerlevel10k installed. Run 'p10k configure' once after opening zsh."
echo ""
echo "IMPORTANT — one-time template steps (do these before provisioning any distros):"
echo "  1. Export this distro: wsl --export <name> C:\\wsl-templates\\ubuntu-22.04-configured-template.tar"
printf '%s\n' "     Or run: .\\rebuild-template.ps1 -SmbPassword <password>  (if template already exists)"
echo "  2. Run the Setup Shared SSH Store workflow (wires Orin via CIFS)"
echo ""
echo "Per-distro steps (credentials are baked into the template — no runtime secret delivery):"
echo "  3. Run WSL2 Provision workflow (distro_name + ssh_port)"
echo "  4. Run WSL2 Verify SSH Topology workflow"
echo "See wsl2/post-bootstrap.md for manual fallback steps."
