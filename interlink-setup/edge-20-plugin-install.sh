#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="$HOME/interlink-autolauncher-plugin"
PYENV="$PLUGIN_DIR/.venv"
SOCK="$HOME/.interlink/.plugin.sock"

# prompt (password hidden)
read -rp "AMD SSH username: " AMD_USER
read -rp "AMD login host (FQDN/IP): " AMD_HOST
read -rsp "AMD SSH password: " AMD_PASS; echo
read -rp "Path to autolauncher.py on AMD [/gpfs/projects/bsc70/hpai/vendor/autolauncher/autolauncher.py]: " AMD_AUTOLAUNCHER
AMD_AUTOLAUNCHER="${AMD_AUTOLAUNCHER:-/gpfs/projects/bsc70/hpai/vendor/autolauncher/autolauncher.py}"

# defaults (override via pod annotations later)
IL_DEFAULT_CLUSTER="amd"
IL_DEFAULT_WORKDIR="/gpfs/projects/bsc70/hpai/work"
IL_DEFAULT_CONTAINERDIR="/gpfs/projects/bsc70/hpai/containers/rocm-sandbox"
IL_DEFAULT_SINGULARITY_VERSION="3.6.4"
IL_DEFAULT_QOS="debug"
IL_DEFAULT_WALLTIME="00:20:00"
IL_DEFAULT_NTASKS="1"; IL_DEFAULT_CPUS_PER_TASK="8"

mkdir -p "$HOME/.interlink"; sudo mkdir -p /var/lib/interlink-autolauncher
sudo chown "$USER:$USER" /var/lib/interlink-autolauncher

sudo tee /etc/default/autolauncher-plugin >/dev/null <<EOF
IL_AUTOLAUNCHER_PATH=${AMD_AUTOLAUNCHER}
IL_PYTHON_BIN=${PYENV}/bin/python
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
systemctl --no-pager -l status autolauncher-plugin || true
