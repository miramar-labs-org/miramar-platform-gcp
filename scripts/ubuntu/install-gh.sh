#!/usr/bin/env bash
set -euo pipefail

echo "==> Adding GitHub CLI APT repository..."
sudo install -d -m 0755 /usr/share/keyrings

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null

echo "==> Installing gh..."
sudo apt-get update
sudo apt-get install -y gh

echo "==> Version installed:"
gh --version

echo
echo "==> Done. Authenticate with:"
echo "  gh auth login"
