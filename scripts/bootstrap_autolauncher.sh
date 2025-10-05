#!/usr/bin/env bash

## this file:
# - detects your IP and sets installer.yaml (ip, port=30433, insecure_http: true)
# - runs interlink-remote.sh install/start
# - enables a systemd socat bridge InterLink UDS → TCP:30433
# - asks for your BSC username and sets up SSH keys for amdlogin1.bsc.es
# - starts the plugin service on ~/.interlink/.plugin.sock

set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

APT_PKGS=(git jq curl wget python3-venv python3-pip rsync sshpass socat)
echo "==> Installing prerequisites (Ubuntu)"
apt-get update -y
apt-get install -y "${APT_PKGS[@]}"

PLUGIN_USER="${SUDO_USER:-ubuntu}"
PLUGIN_HOME="/home/${PLUGIN_USER}"
INSTALL_DIR="/opt/interlink-autolauncher-plugin"
CONF_DIR="/etc/autolauncher-plugin"
LOG_DIR="${PLUGIN_HOME}/.interlink/logs"
BIN_DIR="${PLUGIN_HOME}/.interlink/bin"
MAN_DIR="${PLUGIN_HOME}/.interlink/manifests"
SOCK_DIR="${PLUGIN_HOME}/.interlink"
PLUGIN_SOCK="${SOCK_DIR}/.plugin.sock"
INTERLINK_SOCK="${SOCK_DIR}/.interlink.sock"

mkdir -p "${INSTALL_DIR}" "${CONF_DIR}" "${LOG_DIR}" "${BIN_DIR}" "${MAN_DIR}" "${SOCK_DIR}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "==> Copying sources (preserve plugin/ package)"
rsync -a --delete "${REPO_DIR}/plugin" "${INSTALL_DIR}/"

# Default config
if [[ ! -f "${CONF_DIR}/config.yaml" ]]; then
  cat > "${CONF_DIR}/config.yaml" <<'YAML'
# Autolauncher plugin configuration
bind:
  uds: "~/.interlink/.plugin.sock"
  # http:
  #   host: "127.0.0.1"
  #   port: 8001
bsc:
  host: "amdlogin1.bsc.es"
  user: ""
autolauncher:
  remote_path: "~/autolauncher.py"
YAML
  chown -R "${PLUGIN_USER}":"${PLUGIN_USER}" "${CONF_DIR}"
  chmod 640 "${CONF_DIR}/config.yaml"
  echo "A default config was installed at ${CONF_DIR}/config.yaml — please review."
fi

echo "==> Creating Python venv and installing dependencies"
python3 -m venv "${INSTALL_DIR}/.venv"
source "${INSTALL_DIR}/.venv/bin/activate"
pip install -U pip
pip install -r "${INSTALL_DIR}/plugin/requirements.txt"
deactivate

# Systemd service for the plugin (Uvicorn on UDS)
echo "==> Installing systemd unit"
cat > /etc/systemd/system/autolauncher-plugin.service <<UNIT
[Unit]
Description=InterLink Autolauncher Plugin
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${PLUGIN_USER}
Group=${PLUGIN_USER}
Environment=HOME=${PLUGIN_HOME}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/python -m plugin.run
Restart=always
RestartSec=2
RuntimeDirectory=interlink
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

# Prepare interLink remote (UDS) and installer manifests
echo "==> Installing InterLink remote components (API server)"
mkdir -p "${BIN_DIR}" "${MAN_DIR}"
# Pre-fill edge installer YAML with socket mode
cat > "${PLUGIN_HOME}/.interlink/installer.yaml" <<YML
interlink_ip: 0.0.0.0
interlink_port: 30433
insecure_http: true
kubelet_node_name: autolauncher-edge
kubernetes_namespace: interlink
node_limits:
  cpu: "1000"
  memory: 25600
  pods: "100"
oauth:
  provider: none
YML
chown -R "${PLUGIN_USER}:${PLUGIN_USER}" "${PLUGIN_HOME}/.interlink"

# Download interLink binary and oauth2-proxy (not used when oauth disabled)
if [[ ! -x "${BIN_DIR}/interlink" ]]; then
  curl -fsSL -o "${BIN_DIR}/interlink" https://github.com/interlink-hq/interLink/releases/download/0.5.1/interlink_Linux_x86_64
  chmod +x "${BIN_DIR}/interlink"
fi

# Generate remote scripts and values via the installer (no OAuth)
sudo -u "${PLUGIN_USER}" "${BIN_DIR}/interlink" installer \
  --config "${PLUGIN_HOME}/.interlink/installer.yaml" \
  --output-dir "${MAN_DIR}"

# Ensure interLink writes to ${INTERLINK_SOCK}
sed -i "s|unix://.*/.interlink.sock|unix://${INTERLINK_SOCK}|g" "${PLUGIN_HOME}/.interlink/config/InterLinkConfig.yaml" || true

# Start interLink API (UDS)
echo "==> Starting InterLink API server (UDS)"
sudo -u "${PLUGIN_USER}" bash -lc "${MAN_DIR}/interlink-remote.sh stop || true"
sudo -u "${PLUGIN_USER}" bash -lc "${MAN_DIR}/interlink-remote.sh start"

# UDS→TCP forwarder for the chart (30433)
echo "==> Installing UDS→TCP forwarder (socat) on 30433"
cat > /etc/systemd/system/interlink-uds2tcp.service <<SOCK
[Unit]
Description=Expose interLink UNIX socket over TCP (30433)
After=network-online.target
Wants=network-online.target

[Service]
User=${PLUGIN_USER}
Environment=HOME=${PLUGIN_HOME}
Restart=always
RestartSec=2
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do [ -S ${INTERLINK_SOCK} ] && exit 0; sleep 1; done; echo "interlink.sock not found" >&2; exit 1'
ExecStart=/usr/bin/socat TCP-LISTEN:30433,reuseaddr,fork UNIX-CONNECT:${INTERLINK_SOCK}

[Install]
WantedBy=multi-user.target
SOCK

systemctl daemon-reload
systemctl enable --now interlink-uds2tcp

# Start plugin
echo "==> Enabling and starting autolauncher-plugin service"
systemctl enable --now autolauncher-plugin

echo "==> Sanity checks"
sudo -u "${PLUGIN_USER}" bash -lc "curl -sf --unix-socket ${PLUGIN_SOCK} http://unix/health >/dev/null" && echo "Plugin OK"
curl -sf --unix-socket "${INTERLINK_SOCK}" http://unix/pinglink >/dev/null && echo "InterLink OK"

echo "==> Done. Next: run the master-side bootstrap on your K8s master"
