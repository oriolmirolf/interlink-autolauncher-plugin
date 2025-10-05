#!/usr/bin/env bash

## this file:
# - detects your IP and sets installer.yaml (ip, port=30433, insecure_http: true)
# - runs interlink-remote.sh install/start
# - enables a systemd socat bridge InterLink UDS → TCP:30433
# - asks for your BSC username and sets up SSH keys for amdlogin1.bsc.es
# - starts the plugin service on ~/.interlink/.plugin.sock

set -euo pipefail

echo "==> Installing prerequisites (Ubuntu)"
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y git jq curl wget python3-venv python3-pip rsync sshpass socat
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/interlink-autolauncher-plugin"
CONF_DIR="/etc/autolauncher-plugin"
LOG_DIR="/var/log/autolauncher-plugin"
PLUGIN_USER=${SUDO_USER:-$USER}

echo "==> Preparing directories"
sudo mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$LOG_DIR"
sudo chown -R "${PLUGIN_USER}:${PLUGIN_USER}" "$CONF_DIR"
sudo chmod 755 "$CONF_DIR"

echo "==> Copying sources (preserve plugin/ package)"
# keep plugin/ layout so imports work
sudo rsync -a --delete "$REPO_DIR/plugin" "$INSTALL_DIR/"

if [[ ! -f "$CONF_DIR/config.yaml" ]]; then
  echo "A default config was installed at $CONF_DIR/config.yaml — please review."
  sudo cp "$REPO_DIR/plugin/config.yaml.example" "$CONF_DIR/config.yaml"
  sudo chown "${PLUGIN_USER}:${PLUGIN_USER}" "$CONF_DIR/config.yaml"
  sudo chmod 644 "$CONF_DIR/config.yaml"
fi

echo "==> Creating Python venv and installing dependencies"
sudo python3 -m venv "$INSTALL_DIR/.venv"
# shellcheck disable=SC1091
source "$INSTALL_DIR/.venv/bin/activate"
pip install --upgrade pip
pip install -r "$INSTALL_DIR/plugin/requirements.txt"

echo "==> Installing systemd unit"
sudo cp "$REPO_DIR/systemd/autolauncher-plugin.service" /etc/systemd/system/autolauncher-plugin.service
sudo sed -i "s/^User=.*/User=${PLUGIN_USER}/" /etc/systemd/system/autolauncher-plugin.service
sudo systemctl daemon-reload

# ===========================
# InterLink remote components
# ===========================
echo "==> Installing InterLink remote components (API server)"
mkdir -p "$HOME/.interlink" "$HOME/.interlink/logs" "$HOME/.interlink/bin" "$HOME/.interlink/config"

IP_DET="${IP_DET:-$(hostname -I | awk "{print \$1}")}"
echo "==> Pre-filling ~/.interlink/installer.yaml with interlink_ip=${IP_DET}, interlink_port=30433 and insecure_http=true"

# Fetch installer binary if missing
if [[ ! -x "$HOME/.interlink/interlink-installer" ]]; then
  VERSION=$(curl -s https://api.github.com/repos/interlink-hq/interlink/releases/latest | jq -r .name)
  curl -fsSL -o "$HOME/.interlink/interlink-installer" "https://github.com/interlink-hq/interLink/releases/download/$VERSION/interlink-installer_Linux_x86_64"
  chmod +x "$HOME/.interlink/interlink-installer"
fi

cat > "$HOME/.interlink/installer.yaml" <<YAML
interlink_ip: ${IP_DET}
interlink_port: 30433
interlink_version: $(curl -s https://api.github.com/repos/interlink-hq/interlink/releases/latest | jq -r .name)
kubelet_node_name: autolauncher-edge
kubernetes_namespace: interlink
node_limits:
  cpu: "1000"
  memory: 25600
  pods: "100"
insecure_http: true
oauth:
  provider: ""
YAML

read -r -p "Press Enter to generate manifests using ~/.interlink/installer.yaml (or Ctrl+C to edit first) " _ans || true
"$HOME/.interlink/interlink-installer" --config "$HOME/.interlink/installer.yaml" --output-dir "$HOME/.interlink/manifests/"

echo "=== Installation script for remote interLink APIs stored at: $HOME/.interlink/manifests/interlink-remote.sh ==="
echo
echo "  Running install/start locally ..."
chmod +x "$HOME/.interlink/manifests/interlink-remote.sh"
"$HOME/.interlink/manifests/interlink-remote.sh" install || true
"$HOME/.interlink/manifests/interlink-remote.sh" start || true

echo "=== Configured to reach sidecar service on unix://$HOME/.interlink/.plugin.sock. ==="

# Optional UDS->TCP bridge only if 30433 not already listening
if ! ss -lnt | awk '{print $4}' | grep -q ':30433$'; then
  sudo cp "$REPO_DIR/systemd/interlink-uds2tcp.service" /etc/systemd/system/interlink-uds2tcp.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now interlink-uds2tcp.service || true
else
  echo "==> Port 30433 already in use; skipping uds→tcp bridge."
fi

# ======================
# BSC AMD-CTE SSH setup
# ======================
echo "==> Configuring access to BSC AMD-CTE (amdlogin1.bsc.es)"
read -r -p "Enter your BSC AMD-CTE username: " BSC_USER
# Generate key if missing and copy
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi
ssh-copy-id "${BSC_USER}@amdlogin1.bsc.es" || true

# Upload autolauncher.py optionally
if [[ -f "$INSTALL_DIR/plugin/hpc/autolauncher.py" ]]; then
  read -r -p "Upload plugin/hpc/autolauncher.py to AMD now? [y/N] " UPLOAD_AL
  if [[ "${UPLOAD_AL,,}" == "y" ]]; then
    ssh "${BSC_USER}@amdlogin1.bsc.es" "mkdir -p ~/.autolauncher ~/.interlink/jobs" || true
    scp "$INSTALL_DIR/plugin/hpc/autolauncher.py" "${BSC_USER}@amdlogin1.bsc.es:~/.autolauncher/autolauncher.py"
  fi
fi

echo "==> Enabling and starting autolauncher-plugin service (UDS mode)"
sudo systemctl enable --now autolauncher-plugin

echo "==> Sanity checks"
curl -sf --unix-socket "$HOME/.interlink/.plugin.sock" http://unix/health || { echo "Plugin health check failed"; exit 1; }

# InterLink health may briefly error if services still settling. Print status:
curl -v --unix-socket "$HOME/.interlink/.interlink.sock" http://unix/pinglink || true

echo "==> Done. Next: run the master-side bootstrap on your K8s master"
