#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/interlink-autolauncher-plugin"
CONF_DIR="/etc/autolauncher-plugin"
LOG_DIR="/var/log/autolauncher-plugin"

echo "==> Installing prerequisites (Ubuntu)"
sudo apt-get update -y
sudo apt-get install -y git jq curl wget python3-venv python3-pip rsync sshpass

echo "==> Preparing directories"
sudo mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$LOG_DIR"
sudo chown -R "$USER":"$USER" "$INSTALL_DIR"
sudo chown -R root:root "$CONF_DIR" "$LOG_DIR"
sudo chmod 750 "$CONF_DIR"

echo "==> Copying sources"
rsync -a --delete "$REPO_DIR/plugin/" "$INSTALL_DIR/"
# Copy example config if not present
if [[ ! -f "$CONF_DIR/config.yaml" ]]; then
  sudo cp "$REPO_DIR/plugin/config.yaml.example" "$CONF_DIR/config.yaml"
  echo "A default config was installed at $CONF_DIR/config.yaml — please review."
fi

echo "==> Creating Python venv and installing dependencies"
python3 -m venv "$INSTALL_DIR/.venv"
source "$INSTALL_DIR/.venv/bin/activate"
pip install --upgrade pip
pip install -r "$INSTALL_DIR/requirements.txt"

echo "==> Installing systemd unit"
sudo cp "$REPO_DIR/systemd/autolauncher-plugin.service" /etc/systemd/system/autolauncher-plugin.service
sudo systemctl daemon-reload

# --- InterLink remote components (API server + OAuth2 Proxy) ---
echo "==> Installing InterLink remote components (API server + OAuth2 Proxy)"
mkdir -p "$HOME/.interlink"
if [[ ! -x "$HOME/.interlink/interlink-installer" ]]; then
  export VERSION=$(curl -s https://api.github.com/repos/interlink-hq/interlink/releases/latest  | jq -r .name)
  wget -O "$HOME/.interlink/interlink-installer" "https://github.com/interlink-hq/interLink/releases/download/$VERSION/interlink-installer_Linux_x86_64"
  chmod +x "$HOME/.interlink/interlink-installer"
fi

mkdir -p "$HOME/.interlink/logs" "$HOME/.interlink/bin" "$HOME/.interlink/config"
if [[ ! -f "$HOME/.interlink/installer.yaml" ]]; then
  "$HOME/.interlink/interlink-installer" --init --config "$HOME/.interlink/installer.yaml"
  echo "NOTE: Edit $HOME/.interlink/installer.yaml (interlink_ip, interlink_port, kubelet_node_name, OIDC)."
fi

read -p "Press Enter to generate manifests using ~/.interlink/installer.yaml (or Ctrl+C to edit first) " _
"$HOME/.interlink/interlink-installer" --config "$HOME/.interlink/installer.yaml" --output-dir "$HOME/.interlink/manifests/"

chmod +x "$HOME/.interlink/manifests/interlink-remote.sh"
"$HOME/.interlink/manifests/interlink-remote.sh" install
"$HOME/.interlink/manifests/interlink-remote.sh" start

# --- BSC AMD-CTE credentials and SSH key ---
echo "==> Configuring access to BSC AMD-CTE (amdlogin1.bsc.es)"
read -rp "Enter your BSC AMD-CTE username: " BSC_USER
# write username into plugin config
sudo sed -i "s|^  user:.*$|  user: \"${BSC_USER}\"|" "$CONF_DIR/config.yaml"

# ensure SSH key exists and copy to BSC
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi
echo "We will copy your SSH key to amdlogin1.bsc.es to allow passwordless login."
ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" "${BSC_USER}@amdlogin1.bsc.es" || {
  echo "ssh-copy-id failed. You can retry later manually."
}

# Create remote autolauncher path and upload autolauncher.py
ssh "${BSC_USER}@amdlogin1.bsc.es" "mkdir -p ~/.autolauncher ~/.interlink/jobs" || true
scp "$INSTALL_DIR/hpc/autolauncher.py" "${BSC_USER}@amdlogin1.bsc.es:~/.autolauncher/autolauncher.py"

echo "==> Enabling and starting autolauncher-plugin service"
sudo systemctl enable --now autolauncher-plugin

echo "==> Sanity checks"
sleep 1
curl -sf http://127.0.0.1:8001/health && echo "Plugin health OK" || echo "Plugin health check failed"

echo "==> Reminder: configure InterLink to call this plugin endpoint."
echo "   You may need to edit ~/.interlink/manifests/interlink.yaml to add the plugin endpoint (http://127.0.0.1:8001) and restart the interlink service."
echo "   Then move to your Kubernetes master and run deploy/bootstrap_k8s_master.sh"
