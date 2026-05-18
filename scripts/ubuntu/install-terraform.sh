#!/usr/bin/env bash
set -euo pipefail

echo "==> Updating apt and installing prerequisites..."
sudo apt-get update
sudo apt-get install -y \
  apt-transport-https \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  wget

echo "==> Adding HashiCorp Terraform APT repository..."
wget -O- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-}")"
if [[ -z "${UBUNTU_CODENAME}" ]]; then
  UBUNTU_CODENAME="$(lsb_release -cs)"
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${UBUNTU_CODENAME} main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

echo "==> Installing terraform..."
sudo apt-get update
sudo apt-get install -y terraform

echo "==> Version installed:"
terraform version

echo
echo "==> Done."
