#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-/home/ubuntu/interlink-autolauncher-plugin}"

if [ ! -d "$ROOT/.venv" ]; then
  python3 -m venv "$ROOT/.venv"
  . "$ROOT/.venv/bin/activate"
  pip install -r "$ROOT/requirements.txt"
fi

sudo install -d /etc/systemd/system
sudo cp "$ROOT/systemd/interlink-autolauncher-plugin.service" /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now interlink-autolauncher-plugin

echo "Service status:"
systemctl --no-pager status interlink-autolauncher-plugin || true
