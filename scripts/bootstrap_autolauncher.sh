#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

# --- Base deps ---
APT_PKGS=(git jq curl wget python3-venv python3-pip rsync sshpass socat)
apt-get update -y && apt-get install -y "${APT_PKGS[@]}"

# --- Paths & users ---
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

# --- Copy plugin sources into /opt ---
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rsync -a --delete "${REPO_DIR}/plugin" "${INSTALL_DIR}/"

# --- Ask for AMD-CTE credentials (copies SSH key, uploads autolauncher.py) ---
read -rp "BSC MN5 username: " BSC_USER
read -rs -p "Password for ${BSC_USER}@alogin1.bsc.es: " BSC_PASS; echo
read -rp "Remote GPFS jobs base dir [/gpfs/projects/bsc70/INTERLINK/jobs]: " HPC_BASE
HPC_BASE="${HPC_BASE:-/gpfs/projects/bsc70/INTERLINK/jobs}"
read -rp "Use apptainer instead of singularity? [y/N]: " USE_APPT
if [[ "${USE_APPT,,}" == "y" ]]; then
  SING_BIN="apptainer"; MOD_INIT="module load rocm apptainer"
else
  SING_BIN="singularity"; MOD_INIT="module load rocm singularity"
fi

# Generate SSH key if missing and push to BSC
sudo -u "${PLUGIN_USER}" bash -lc '[[ -f ~/.ssh/id_rsa ]] || ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa'
sudo -u "${PLUGIN_USER}" sshpass -p "${BSC_PASS}" \
  ssh-copy-id -i "/home/${PLUGIN_USER}/.ssh/id_rsa.pub" \
  -o StrictHostKeyChecking=accept-new \
  "${BSC_USER}@alogin1.bsc.es"

# Upload patched autolauncher (optional but recommended)
sudo -u "${PLUGIN_USER}" ssh -o StrictHostKeyChecking=accept-new \
  "${BSC_USER}@alogin1.bsc.es" 'mkdir -p ~/.autolauncher'
sudo -u "${PLUGIN_USER}" scp -o StrictHostKeyChecking=accept-new \
  "${INSTALL_DIR}/plugin/hpc/autolauncher.py" \
  "${BSC_USER}@alogin1.bsc.es:~/.autolauncher/autolauncher.py" || true

# --- Python venv + deps ---
python3 -m venv "${INSTALL_DIR}/.venv"
# shellcheck disable=SC1091
source "${INSTALL_DIR}/.venv/bin/activate"
pip install -U pip
pip install -r "${INSTALL_DIR}/plugin/requirements.txt"
deactivate

# --- Plugin config ---
cat > "${CONF_DIR}/config.yaml" <<YAML
plugin:
  uds: "~/.interlink/.plugin.sock"
  state_path: "~/.interlink/autolauncher-plugin-state.json"

hpc:
  login_host: "alogin1.bsc.es"
  user: "${BSC_USER}"
  cluster: "mn5"
  autolauncher_path: "~/.autolauncher/autolauncher.py"
  remote_base_dir: "${HPC_BASE}"
  singularity_version: "3.6.4"
  singularity_binary: "${SING_BIN}"
  module_init: "${MOD_INIT}"
  image_map: {}
  extra_bindings:
    - "/gpfs/projects/bsc70/hpai/storage/data/:/gpfs/projects/bsc70/hpai/storage/data/"
YAML
chown -R "${PLUGIN_USER}:${PLUGIN_USER}" "${CONF_DIR}"
chmod 640 "${CONF_DIR}/config.yaml"

# --- systemd: autolauncher plugin (UDS) ---
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

# Create manifests & ensure remote helper is executable
sudo -u "${PLUGIN_USER}" "${BIN_DIR}/interlink-installer" --config "${PLUGIN_HOME}/.interlink/installer.yaml" --output-dir "${MAN_DIR}"
sudo -u "${PLUGIN_USER}" chmod +x "${MAN_DIR}/interlink-remote.sh"

# Start remote once (will be auto-managed later)
sudo -u "${PLUGIN_USER}" bash -lc "${MAN_DIR}/interlink-remote.sh stop || true"
sudo -u "${PLUGIN_USER}" bash -lc "${MAN_DIR}/interlink-remote.sh start || true"

# --- systemd: UDS→TCP forwarder (waits for UDS before starting) ---
cat > /etc/systemd/system/interlink-uds2tcp.service <<SOCK
[Unit]
Description=Expose interLink UNIX socket over TCP (30433)
After=network-online.target interlink-remote.service
Wants=network-online.target interlink-remote.service

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

# --- systemd: InterLink remote as a managed service (oneshot) ---
cat > /etc/systemd/system/interlink-remote.service <<'UNIT'
[Unit]
Description=InterLink Remote (UDS sidecar)
After=network-online.target autolauncher-plugin.service
Wants=network-online.target

[Service]
Type=oneshot
User=ubuntu
Environment=HOME=/home/ubuntu
ExecStart=/home/ubuntu/.interlink/manifests/interlink-remote.sh start
ExecStop=/home/ubuntu/.interlink/manifests/interlink-remote.sh stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now interlink-remote
systemctl enable --now interlink-uds2tcp

# --- Auto-recovery script (safe on every boot & manual runs) ---
cat > /usr/local/bin/autolauncher-recover.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PLUGIN_USER="ubuntu"
HOME_DIR="/home/${PLUGIN_USER}"
export HOME="${HOME_DIR}"
PLUGIN_SOCK="${HOME_DIR}/.interlink/.plugin.sock"
INTERLINK_SOCK="${HOME_DIR}/.interlink/.interlink.sock"
MAN_DIR="${HOME_DIR}/.interlink/manifests"
LOG_DIR="${HOME_DIR}/.interlink/logs"

log(){ echo -e "\033[1;32m[recover]\033[0m $*"; }

log "Stopping TCP forwarder…"
systemctl stop interlink-uds2tcp || true

log "Restarting plugin…"
systemctl restart autolauncher-plugin

log "Cleaning stale sockets/PIDs…"
rm -f "${INTERLINK_SOCK}" "${HOME_DIR}/.interlink/"*.pid 2>/dev/null || true

log "Starting InterLink remote…"
if [[ -x "${MAN_DIR}/interlink-remote.sh" ]]; then
  sudo -u "${PLUGIN_USER}" env HOME="${HOME_DIR}" "${MAN_DIR}/interlink-remote.sh" stop || true
  sudo -u "${PLUGIN_USER}" env HOME="${HOME_DIR}" "${MAN_DIR}/interlink-remote.sh" start
else
  log "Missing ${MAN_DIR}/interlink-remote.sh"; exit 1
fi

log "Waiting for sockets…"
for i in $(seq 1 60); do [[ -S "${PLUGIN_SOCK}" ]] && break; sleep 1; done
for i in $(seq 1 60); do [[ -S "${INTERLINK_SOCK}" ]] && break; sleep 1; done

log "Starting TCP forwarder…"
systemctl enable --now interlink-uds2tcp >/dev/null 2>&1 || true
systemctl restart interlink-uds2tcp

log "--- Health ---"
sudo -u "${PLUGIN_USER}" curl -sf --unix-socket "${PLUGIN_SOCK}" http://unix/health && echo "Plugin OK"
sudo -u "${PLUGIN_USER}" curl -sf --unix-socket "${INTERLINK_SOCK}" http://unix/pinglink && echo "InterLink UDS OK"
curl -sf http://127.0.0.1:30433/pinglink && echo "InterLink TCP OK" || true

log "Done. Logs (if needed): ${LOG_DIR}"
SH
chmod +x /usr/local/bin/autolauncher-recover.sh

# --- systemd: run recovery automatically at boot ---
cat > /etc/systemd/system/autolauncher-recover.service <<'UNIT'
[Unit]
Description=Recover InterLink Autolauncher after reboot
After=network-online.target autolauncher-plugin.service interlink-remote.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/autolauncher-recover.sh

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable autolauncher-recover.service

# --- Optional: open port 30433 (local firewall only) ---
if command -v ufw >/dev/null 2>&1; then
  ufw allow 30433/tcp || true
fi

# --- Small wait so health checks don't race the socket ---
for i in $(seq 1 30); do [[ -S "${INTERLINK_SOCK}" ]] && break; sleep 1; done

# --- Quick health checks (as plugin user) ---
sudo -u "${PLUGIN_USER}" bash -lc "curl -sf --unix-socket ${PLUGIN_SOCK} http://unix/health >/dev/null" && echo "Plugin OK"
sudo -u "${PLUGIN_USER}" bash -lc "curl -sf --unix-socket ${INTERLINK_SOCK} http://unix/pinglink >/dev/null" && echo "InterLink UDS OK" || true
curl -sf http://127.0.0.1:30433/pinglink >/dev/null 2>&1 && echo "InterLink TCP OK" || true

echo "Autolauncher bootstrap complete."
