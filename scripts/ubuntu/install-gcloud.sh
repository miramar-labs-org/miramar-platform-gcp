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

echo "==> Adding Google Cloud CLI APT repository..."
sudo install -d -m 0755 /usr/share/keyrings

curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg

echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null

echo "==> Installing gcloud..."
sudo apt-get update
sudo apt-get install -y google-cloud-cli

echo "==> Version installed:"
gcloud --version

echo
echo "==> Done."
echo "Next, initialize gcloud if this is an interactive machine:"
echo "  gcloud init"
echo
echo "For GitHub Actions/self-hosted runner use, prefer service-account or Workload Identity auth instead of interactive gcloud auth login."
