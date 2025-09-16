#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="/home/ubuntu/interlink-autolauncher-plugin"
PYENV="$PLUGIN_DIR/.venv"

# ---- EDIT these to your AMD login + paths ----
export AMD_USER="your_user"
export AMD_HOST="amd-login.example.org"     # AMD login node FQDN/IP
export AMD_PASS="your_password"
export AMD_AUTOLAUNCHER="/gpfs/projects/bsc70/hpai/vendor/autolauncher/autolauncher.py"

# Defaults for jobs (override per-pod via annotations)
export IL_DEFAULT_CLUSTER="amd"
export IL_DEFAULT_WORKDIR="/gpfs/projects/bsc70/hpai/work"
export IL_DEFAULT_CONTAINERDIR="/gpfs/projects/bsc70/hpai/containers/rocm-sandbox"
export IL_DEFAULT_SINGULARITY_VERSION="3.6.4"
export IL_DEFAULT_QOS="debug"
export IL_DEFAULT_WALLTIME="00:20:00"
export IL_DEFAULT_NTASKS="1"
export IL_DEFAULT_CPUS_PER_TASK="8"
# ----------------------------------------------

# Python env + deps
python3 -m venv "$PYENV"
source "$PYENV/bin/activate"
pip install --upgrade pip
pip install -r "$PLUGIN_DIR/requirements.txt"

# Create env file
sudo tee /etc/default/autolauncher-plugin >/dev/null <<EOF
IL_AUTOLAUNCHER_PATH=${AMD_AUTOLAUNCHER}
IL_PYTHON_BIN=python3
IL_LOCAL_STAGING_DIR=/tmp/interlink-autolauncher
IL_STATE_FILE=/var/lib/interlink-autolauncher/state.json
IL_SSH_DEST=${AMD_USER}@${AMD_HOST}

# enable password auth via sshpass
IL_SSH_USE_SSHPASS=1
IL_SSH_PASS=${AMD_PASS}

# defaults (overridable via pod annotations)
IL_DEFAULT_CLUSTER=${IL_DEFAULT_CLUSTER}
IL_DEFAULT_WORKDIR=${IL_DEFAULT_WORKDIR}
IL_DEFAULT_CONTAINERDIR=${IL_DEFAULT_CONTAINERDIR}
IL_DEFAULT_SINGULARITY_VERSION=${IL_DEFAULT_SINGULARITY_VERSION}
IL_DEFAULT_QOS=${IL_DEFAULT_QOS}
IL_DEFAULT_WALLTIME=${IL_DEFAULT_WALLTIME}
IL_DEFAULT_NTASKS=${IL_DEFAULT_NTASKS}
IL_DEFAULT_CPUS_PER_TASK=${IL_DEFAULT_CPUS_PER_TASK}
EOF

# Protect the password file
sudo chmod 600 /etc/default/autolauncher-plugin

# Systemd service
sudo tee /etc/systemd/system/autolauncher-plugin.service >/dev/null <<EOF
[Unit]
Description=InterLink Autolauncher Plugin
After=network-online.target

[Service]
EnvironmentFile=/etc/default/autolauncher-plugin
WorkingDirectory=${PLUGIN_DIR}
ExecStart=${PYENV}/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now autolauncher-plugin
sleep 1
systemctl --no-pager -l status autolauncher-plugin || true

echo "Plugin running on http://192.168.0.98:8000"
