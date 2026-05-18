#!/usr/bin/env zsh
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

echo "==> Installing Google Cloud CLI APT repository..."
sudo install -d -m 0755 /usr/share/keyrings

curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null

echo "==> Installing HashiCorp Terraform APT repository..."
wget -O- https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

UBUNTU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-}")"
if [[ -z "${UBUNTU_CODENAME}" ]]; then
  UBUNTU_CODENAME="$(lsb_release -cs)"
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${UBUNTU_CODENAME} main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

echo "==> Installing gcloud and terraform..."
sudo apt-get update
sudo apt-get install -y google-cloud-cli terraform

echo "==> Versions installed:"
gcloud --version
echo
terraform version

echo
echo "==> Done."
echo "Next, initialize gcloud if this is an interactive machine:"
echo "  gcloud init"
echo
echo "For GitHub Actions/self-hosted runner use, prefer service-account or Workload Identity auth instead of interactive gcloud auth login."
