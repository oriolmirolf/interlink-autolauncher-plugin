#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/interlink-autolauncher-plugin"
CONF_DIR="/etc/autolauncher-plugin"
LOG_DIR="/var/log/autolauncher-plugin"

echo "==> Installing prerequisites (Ubuntu)"
sudo apt-get update -y
sudo apt-get install -y git jq curl wget python3-venv python3-pip rsync sshpass socat

echo "==> Preparing directories"
sudo mkdir -p "$INSTALL_DIR" "$CONF_DIR" "$LOG_DIR"
sudo chown -R "$USER":"$USER" "$INSTALL_DIR"
sudo chown -R root:root "$CONF_DIR" "$LOG_DIR"
sudo chmod 750 "$CONF_DIR"

echo "==> Copying sources (preserve plugin/ package)"
rsync -a --delete "$REPO_DIR/plugin" "$INSTALL_DIR/"

# Copy example config if not present
if [[ ! -f "$CONF_DIR/config.yaml" ]]; then
  sudo cp "$REPO_DIR/plugin/config.yaml.example" "$CONF_DIR/config.yaml"
  echo "A default config was installed at $CONF_DIR/config.yaml — please review."
fi

echo "==> Creating Python venv and installing dependencies"
python3 -m venv "$INSTALL_DIR/.venv"
source "$INSTALL_DIR/.venv/bin/activate"
pip install --upgrade pip
pip install -r "$INSTALL_DIR/plugin/requirements.txt"

echo "==> Installing systemd unit"
sudo cp "$REPO_DIR/systemd/autolauncher-plugin.service" /etc/systemd/system/autolauncher-plugin.service
sudo cp "$REPO_DIR/systemd/interlink-uds2tcp.service" /etc/systemd/system/interlink-uds2tcp.service
sudo systemctl daemon-reload

# --- InterLink remote components (API server + (optional) OAuth2 Proxy) ---
echo "==> Installing InterLink remote components (API server)"
mkdir -p "$HOME/.interlink"
if [[ ! -x "$HOME/.interlink/interlink-installer" ]]; then
  export VERSION=$(curl -s https://api.github.com/repos/interlink-hq/interlink/releases/latest  | jq -r .name)
  wget -O "$HOME/.interlink/interlink-installer" "https://github.com/interlink-hq/interLink/releases/download/$VERSION/interlink-installer_Linux_x86_64"
  chmod +x "$HOME/.interlink/interlink-installer"
fi

mkdir -p "$HOME/.interlink/logs" "$HOME/.interlink/bin" "$HOME/.interlink/config"
if [[ ! -f "$HOME/.interlink/installer.yaml" ]]; then
  "$HOME/.interlink/interlink-installer" --init --config "$HOME/.interlink/installer.yaml"
fi

IP_DETECTED="$(ip route get 1.1.1.1 | awk "/src/ {for(i=1;i<=NF;i++) if (\$i==\"src\") print \$(i+1)}")"
IP_DETECTED="${IP_DETECTED:-127.0.0.1}"
echo "==> Pre-filling ~/.interlink/installer.yaml with interlink_ip=${IP_DETECTED}, interlink_port=30433 and insecure_http=true"
cp -n "$HOME/.interlink/installer.yaml" "$HOME/.interlink/installer.yaml.bak" || true
awk -v ip="$IP_DETECTED" '
  BEGIN{found_ip=0; found_port=0; found_insec=0}
  /^interlink_ip:/   {print "interlink_ip: " ip; found_ip=1; next}
  /^interlink_port:/ {print "interlink_port: 30433"; found_port=1; next}
  /^insecure_http:/  {print "insecure_http: true"; found_insec=1; next}
  {print}
  END{
    if(!found_ip)   print "interlink_ip: " ip
    if(!found_port) print "interlink_port: 30433"
    if(!found_insec)print "insecure_http: true"
  }
' "$HOME/.interlink/installer.yaml" > "$HOME/.interlink/installer.yaml.tmp"
mv "$HOME/.interlink/installer.yaml.tmp" "$HOME/.interlink/installer.yaml"

read -p "Press Enter to generate manifests using ~/.interlink/installer.yaml (or Ctrl+C to edit first) " _
"$HOME/.interlink/interlink-installer" --config "$HOME/.interlink/installer.yaml" --output-dir "$HOME/.interlink/manifests/"

chmod +x "$HOME/.interlink/manifests/interlink-remote.sh"
"$HOME/.interlink/manifests/interlink-remote.sh" install || true
"$HOME/.interlink/manifests/interlink-remote.sh" start || true

# Optional: expose the InterLink UNIX socket over TCP (30433) via systemd + socat
sudo systemctl enable --now interlink-uds2tcp.service || true

# --- BSC AMD-CTE credentials and SSH key ---
echo "==> Configuring access to BSC AMD-CTE (amdlogin1.bsc.es)"
read -rp "Enter your BSC AMD-CTE username: " BSC_USER
sudo sed -i "s|^  user:.*$|  user: \"${BSC_USER}\"|" "$CONF_DIR/config.yaml"

if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
fi
echo "We will copy your SSH key to amdlogin1.bsc.es to allow passwordless login."
ssh-copy-id -i "$HOME/.ssh/id_ed25519.pub" "${BSC_USER}@amdlogin1.bsc.es" || {
  echo "ssh-copy-id failed. You can retry later manually."
}

# Optionally upload autolauncher.py (your real file) to AMD-CTE
read -rp "Upload plugin/hpc/autolauncher.py to AMD now? [y/N] " UPLOAD_AL
if [[ "${UPLOAD_AL,,}" == "y" ]]; then
  ssh "${BSC_USER}@amdlogin1.bsc.es" "mkdir -p ~/.autolauncher ~/.interlink/jobs" || true
  scp "$INSTALL_DIR/plugin/hpc/autolauncher.py" "${BSC_USER}@amdlogin1.bsc.es:~/.autolauncher/autolauncher.py"
fi

echo "==> Enabling and starting autolauncher-plugin service (UDS mode)"
sudo systemctl enable --now autolauncher-plugin

echo "==> Sanity checks"
sleep 1
curl -sf --unix-socket "$HOME/.interlink/.plugin.sock" http://unix/health && echo "Plugin health OK (UDS)" || echo "Plugin health check failed"
curl -v --unix-socket "${HOME}/.interlink/.interlink.sock"  http://unix/pinglink || true

echo "==> Done. Next: run the master-side bootstrap on your K8s master"
