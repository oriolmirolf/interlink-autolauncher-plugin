#!/usr/bin/env bash
set -euo pipefail

# Basic tooling
sudo apt-get update
sudo apt-get install -y python3-venv python3-pip git curl jq sshpass unzip

# (Optional) Helm + kubectl (handy for checks; helm/kubectl mainly needed on k8-master)
if ! command -v kubectl >/dev/null 2>&1; then
  curl -fsSL https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl -o kubectl
  chmod +x kubectl && sudo mv kubectl /usr/local/bin/
fi
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Directories for interLink remote components and plugin
mkdir -p $HOME/.interlink/{logs,bin,config,manifests}
sudo mkdir -p /var/lib/interlink-autolauncher
sudo chown -R "$USER":"$USER" /var/lib/interlink-autolauncher

echo "Prereqs installed."
