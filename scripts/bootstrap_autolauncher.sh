#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then echo "Run with sudo." >&2; exit 1; fi

APT_PKGS=(git jq curl wget python3-venv python3-pip rsync sshpass socat)
apt-get update -y && apt-get install -y "${APT_PKGS[@]}"

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
rsync -a --delete "${REPO_DIR}/plugin" "${INSTALL_DIR}/"

# --- Ask for AMD-CTE credentials (copies SSH key, uploads autolauncher.py) ---
read -rp "BSC AMD-CTE username: " BSC_USER
read -rs -p "Password for ${BSC_USER}@amdlogin1.bsc.es: " BSC_Pass; echo
read -rp "Remote GPFS jobs base dir [/gpfs/projects/bsc70/<your_group>/interlink/jobs]: " HPC_BASE
HPC_BASE="${HPC_BASE:-/gpfs/projects/bsc70/<your_group>/interlink/jobs}"
read -rp "Use apptainer instead of singularity? [y/N]: " USE_APPT
if [[ "${USE_APPT,,}" == "y" ]]; then SING_BIN="apptainer"; MOD_INIT="module load rocm apptainer"; else SING_BIN="singularity"; MOD_INIT="module load rocm singularity"; fi

sudo -u "${PLUGIN_USER}" bash -lc '[[ -f ~/.ssh/id_rsa ]] || ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa'
sudo -u "${PLUGIN_USER}" sshpass -p "${BSC_Pass}" \
  ssh-copy-id -i "/home/${PLUGIN_USER}/.ssh/id_rsa.pub" \
  -o StrictHostKeyChecking=accept-new \
  "${BSC_USER}@amdlogin1.bsc.es"

# Upload patched autolauncher (optional but recommended)
sudo -u "${PLUGIN_USER}" ssh -o StrictHostKeyChecking=accept-new \
  "${BSC_USER}@amdlogin1.bsc.es" 'mkdir -p ~/.autolauncher'
sudo -u "${PLUGIN_USER}" scp -o StrictHostKeyChecking=accept-new \
  "${INSTALL_DIR}/plugin/hpc/autolauncher.py" \
  "${BSC_USER}@amdlogin1.bsc.es:~/.autolauncher/autolauncher.py" || true

# --- Install Python deps in venv ---
python3 -m venv "${INSTALL_DIR}/.venv"
source "${INSTALL_DIR}/.venv/bin/activate"
pip install -U pip
pip install -r "${INSTALL_DIR}/plugin/requirements.txt"
deactivate

# --- Config file with correct keys ---
cat > "${CONF_DIR}/config.yaml" <<YAML
plugin:
  uds: "~/.interlink/.plugin.sock"
  state_path: "~/.interlink/autolauncher-plugin-state.json"

hpc:
  login_host: "amdlogin1.bsc.es"
  user: "${BSC_USER}"
  cluster: "amd"
  autolauncher_path: "~/.autolauncher/autolauncher.py"
  remote_base_dir: "${HPC_BASE}"
  singularity_version: "3.6.4"
  singularity_binary: "${SING_BIN}"
  module_init: "${MOD_INIT}"
  image_map: {}
  extra_bindings: ["/gpfs/projects/bsc70/hpai/storage/data/:/gpfs/projects/bsc70/hpai/storage/data/"]
YAML
chown -R "${PLUGIN_USER}:${PLUGIN_USER}" "${CONF_DIR}"
chmod 640 "${CONF_DIR}/config.yaml"

# --- systemd for plugin (UDS) ---
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
Environment=AUTOLAUNCHER_PLUGIN_CONFIG=${CONF_DIR}/config.yaml
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/.venv/bin/python -m plugin.run
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now autolauncher-plugin

# --- InterLink installer (edge REST, no OAuth for dev) ---
mkdir -p "${BIN_DIR}"
if [[ ! -x "${BIN_DIR}/interlink-installer" ]]; then
  V="$(curl -fsSL https://api.github.com/repos/interlink-hq/interLink/releases/latest | jq -r .name)"
  wget -qO "${BIN_DIR}/interlink-installer" "https://github.com/interlink-hq/interLink/releases/download/${V}/interlink-installer_Linux_x86_64"
  chmod +x "${BIN_DIR}/interlink-installer"
fi

cat > "${PLUGIN_HOME}/.interlink/installer.yaml" <<YML
interlink_ip: 0.0.0.0
interlink_port: 30433
insecure_http: true
interlink_version: "0.5.1"
kubelet_node_name: autolauncher-edge
kubernetes_namespace: interlink
node_limits:
  cpu: "1000"
  memory: 25600
  pods: "100"
oauth: {}
YML

chown -R "${PLUGIN_USER}:${PLUGIN_USER}" "${PLUGIN_HOME}/.interlink"

# create manifests & start remote
sudo -u "${PLUGIN_USER}" "${BIN_DIR}/interlink-installer" --config "${PLUGIN_HOME}/.interlink/installer.yaml" --output-dir "${MAN_DIR}"

# FIX: make the generated script executable before calling it (avoids “Permission denied”)
sudo -u "${PLUGIN_USER}" chmod +x "${MAN_DIR}/interlink-remote.sh"

sudo -u "${PLUGIN_USER}" bash -lc "${MAN_DIR}/interlink-remote.sh stop || true"
sudo -u "${PLUGIN_USER}" bash -lc "${MAN_DIR}/interlink-remote.sh start"

# UDS→TCP forwarder for 30433 (waits for UDS first)
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
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 60); do [ -S ${INTERLINK_SOCK} ] && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/bin/socat TCP-LISTEN:30433,reuseaddr,fork UNIX-CONNECT:${INTERLINK_SOCK}

[Install]
WantedBy=multi-user.target
SOCK

systemctl daemon-reload
systemctl enable --now interlink-uds2tcp

# FIX: optional wait so subsequent health checks don't race the socket
for i in $(seq 1 30); do [[ -S "${INTERLINK_SOCK}" ]] && break; sleep 1; done

# quick health checks (as the plugin user)
sudo -u "${PLUGIN_USER}" bash -lc "curl -sf --unix-socket ${PLUGIN_SOCK} http://unix/health >/dev/null" && echo "Plugin OK"
sudo -u "${PLUGIN_USER}" bash -lc "curl -sf --unix-socket ${INTERLINK_SOCK} http://unix/pinglink >/dev/null" && echo "InterLink OK"

echo "Autolauncher bootstrap complete."
