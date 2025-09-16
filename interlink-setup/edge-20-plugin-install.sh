# edge-20-plugin-install.sh
set -euo pipefail

PLUGIN_DIR="$HOME/interlink-autolauncher-plugin"
PYENV="$PLUGIN_DIR/.venv"
SOCK="$HOME/.interlink/.plugin.sock"

# 1) Python env + deps
python3 -m venv "$PYENV"
source "$PYENV/bin/activate"
pip install --upgrade pip
pip install -r "$PLUGIN_DIR/requirements.txt"

# 2) Ask for AMD creds (username/host prompt; password read silently)
read -rp "AMD SSH username: " AMD_USER
read -rp "AMD login host (FQDN/IP): " AMD_HOST
read -rsp "AMD SSH password (input hidden): " AMD_PASS; echo

# 3) Ask for AMD autolauncher path (default shown)
read -rp "Path to autolauncher.py on AMD [/gpfs/projects/bsc70/hpai/vendor/autolauncher/autolauncher.py]: " AMD_AUTOLAUNCHER
AMD_AUTOLAUNCHER="${AMD_AUTOLAUNCHER:-/gpfs/projects/bsc70/hpai/vendor/autolauncher/autolauncher.py}"

# 4) Defaults (you can override per-pod via annotations)
IL_DEFAULT_CLUSTER="amd"
IL_DEFAULT_WORKDIR="/gpfs/projects/bsc70/hpai/work"
IL_DEFAULT_CONTAINERDIR="/gpfs/projects/bsc70/hpai/containers/rocm-sandbox"
IL_DEFAULT_SINGULARITY_VERSION="3.6.4"
IL_DEFAULT_QOS="debug"
IL_DEFAULT_WALLTIME="00:20:00"
IL_DEFAULT_NTASKS="1"
IL_DEFAULT_CPUS_PER_TASK="8"

mkdir -p "$HOME/.interlink"
sudo mkdir -p /var/lib/interlink-autolauncher
sudo chown "$USER":"$USER" /var/lib/interlink-autolauncher

# 5) Environment file (protected)
sudo tee /etc/default/autolauncher-plugin >/dev/null <<EOF
IL_AUTOLAUNCHER_PATH=${AMD_AUTOLAUNCHER}
IL_PYTHON_BIN=python3
IL_LOCAL_STAGING_DIR=/tmp/interlink-autolauncher
IL_STATE_FILE=/var/lib/interlink-autolauncher/state.json
IL_SSH_DEST=${AMD_USER}@${AMD_HOST}
IL_SSH_USE_SSHPASS=1
IL_SSH_PASS=${AMD_PASS}
IL_DEFAULT_CLUSTER=${IL_DEFAULT_CLUSTER}
IL_DEFAULT_WORKDIR=${IL_DEFAULT_WORKDIR}
IL_DEFAULT_CONTAINERDIR=${IL_DEFAULT_CONTAINERDIR}
IL_DEFAULT_SINGULARITY_VERSION=${IL_DEFAULT_SINGULARITY_VERSION}
IL_DEFAULT_QOS=${IL_DEFAULT_QOS}
IL_DEFAULT_WALLTIME=${IL_DEFAULT_WALLTIME}
IL_DEFAULT_NTASKS=${IL_DEFAULT_NTASKS}
IL_DEFAULT_CPUS_PER_TASK=${IL_DEFAULT_CPUS_PER_TASK}
EOF
sudo chmod 600 /etc/default/autolauncher-plugin

# 6) Systemd service (bind to UNIX socket like the SLURM plugin)
sudo tee /etc/systemd/system/autolauncher-plugin.service >/dev/null <<EOF
[Unit]
Description=InterLink Autolauncher Plugin (UNIX socket)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/default/autolauncher-plugin
User=${USER}
WorkingDirectory=${PLUGIN_DIR}
ExecStartPre=/bin/rm -f ${SOCK}
ExecStart=${PYENV}/bin/uvicorn main:app --uds ${SOCK} --workers 1
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now autolauncher-plugin
sleep 1
systemctl --no-pager -l status autolauncher-plugin || true

# 7) Quick probe that the socket is up
if [ -S "${SOCK}" ]; then
  echo "Plugin socket ready at ${SOCK}"
else
  echo "Plugin socket not found — check: journalctl -u autolauncher-plugin -f"
  exit 1
fi
